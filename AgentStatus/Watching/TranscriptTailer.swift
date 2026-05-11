import Foundation
import Darwin

/// Incrementally tails one session's JSONL transcript and exposes a derived
/// `EnrichedSession` snapshot. Re-reads only new bytes appended since the last
/// emission, so it's cheap regardless of total transcript size.
///
/// Watch path: `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
/// The "encoded-cwd" is the cwd path with `/` replaced by `-` (Claude's
/// convention); we resolve robustly by also scanning project subdirs if needed.
///
/// Concurrency: this is a value-typed actor — owns its file handle and parser
/// state, hops to MainActor only when emitting via the AsyncStream continuation.
actor TranscriptTailer {
    let sessionId: String
    let cwd: URL
    private let pollInterval: TimeInterval
    private let perf: PerfStats?

    nonisolated let snapshots: AsyncStream<EnrichedSession>
    private let continuation: AsyncStream<EnrichedSession>.Continuation

    private var fileURL: URL?
    private var offset: UInt64 = 0
    private var pendingPartialLine = ""
    private var pollTask: Task<Void, Never>?

    // Derived state — accumulated across messages.
    private var state = EnrichedSession()
    private var toolStarts: [String: (name: String, preview: String, at: Date, inputJSON: Data?)] = [:]
    private var recentToolsRing: [CompletedTool] = []
    private static let recentToolsCap = 10
    private var activeAndRecentDirty = false

    init(sessionId: String, cwd: URL, pollInterval: TimeInterval = 1.0, perf: PerfStats? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.pollInterval = pollInterval
        self.perf = perf

        var cont: AsyncStream<EnrichedSession>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.continuation = cont
    }

    func start() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            // Polling rather than FSEvents on the file: simpler, robust to
            // file rotation, and 1 Hz × small read is essentially free.
            let nanos = Self.sleepNanos(forPollInterval: interval)
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Convert a poll interval in seconds to nanoseconds for `Task.sleep`.
    /// Lives in its own function so the operator precedence is unambiguous —
    /// see `TranscriptTailerTests` for the regression this guards.
    static func sleepNanos(forPollInterval seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// Extract the title from an `ai-title` event. The on-disk schema is
    /// `{ "type":"ai-title", "aiTitle":"…", "sessionId":"…" }` — note the
    /// camel-cased `aiTitle` key (not `title`). Empty strings are treated as
    /// absent. Static + pure so `TranscriptTailerTests` can pin the key.
    static func aiTitle(fromEvent json: [String: Any]) -> String? {
        guard let t = json["aiTitle"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// True when an `assistant` JSON record is part of a sub-agent's sidechain.
    /// Top-level assistant messages omit this key or set it to `false`.
    static func isSidechain(_ json: [String: Any]) -> Bool {
        (json["isSidechain"] as? Bool) == true
    }

    /// Build a `WaitingDisplay` from the raw `waitingFor` string and the most
    /// recent in-flight tool_use (if any). Pure — no I/O, no state.
    /// Returns nil when not waiting (`waitingFor == nil`).
    ///
    /// Routing rules:
    ///   - `pending.name == "AskUserQuestion"` → `.askUserQuestion(text, options)`
    ///     using `pendingInput["questions"][0]`.
    ///   - `pending.name == "Task"` → `.subagent(description, prompt)` from `pendingInput`.
    ///   - any other `pending` → `.tool(name, preview)`.
    ///   - no `pending` → `.unknown(rawWaitingFor)`.
    static func waitingDisplay(
        for waitingFor: String?,
        pending: ActiveTool?,
        pendingInput: [String: Any]?
    ) -> WaitingDisplay? {
        guard let raw = waitingFor else { return nil }

        guard let p = pending else {
            return .unknown(rawWaitingFor: raw)
        }

        switch p.name {
        case "AskUserQuestion":
            let questions = (pendingInput?["questions"] as? [[String: Any]]) ?? []
            let first = questions.first ?? [:]
            let text = (first["question"] as? String) ?? ""
            let options = ((first["options"] as? [[String: Any]]) ?? []).compactMap {
                $0["label"] as? String
            }
            return .askUserQuestion(text: text, options: options)

        case "Task":
            let description = (pendingInput?["description"] as? String) ?? ""
            let prompt = (pendingInput?["prompt"] as? String) ?? ""
            return .subagent(description: description, prompt: prompt)

        default:
            return .tool(name: p.name, preview: p.preview)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation.finish()
    }

    private func tick() {
        guard let url = resolveFile() else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? UInt64) ?? 0

            // File rotated or truncated → reset.
            if size < offset {
                offset = 0
                pendingPartialLine = ""
                state = EnrichedSession()
                toolStarts.removeAll()
                recentToolsRing.removeAll()
                activeAndRecentDirty = false
            }
            guard size > offset else { return }

            // Chunked read: bound peak memory regardless of file size. A resumed
            // multi-MB transcript drains across multiple ticks instead of a
            // single jumbo allocation.
            let chunkCap: UInt64 = 1_048_576    // 1 MB
            let toRead = min(size - offset, chunkCap)
            if let perf = perf { Task { await perf.observe(bytes: toRead); await perf.observe(tick: 1) } }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(toRead))
            try handle.close()
            offset += toRead

            guard let chunk = String(data: data, encoding: .utf8) else { return }
            let combined = pendingPartialLine + chunk
            // Split keeping any trailing partial line for next read.
            let endsClean = combined.hasSuffix("\n")
            var lines = combined.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
            if !endsClean, let last = lines.popLast() {
                pendingPartialLine = String(last)
            } else {
                pendingPartialLine = ""
            }
            for line in lines where !line.isEmpty {
                process(line: String(line))
            }
            if let perf = perf {
                let lineCount = UInt64(lines.filter { !$0.isEmpty }.count)
                Task { await perf.observe(lines: lineCount); await perf.observe(yield: 1) }
            }
            continuation.yield(state)
        } catch {
            Log.watcher.debug("TranscriptTailer tick failed for \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Locate the .jsonl file. Fast path: cwd → encoded path. Fallback: scan
    /// `~/.claude/projects/*` for any `<sessionId>.jsonl`.
    private func resolveFile() -> URL? {
        if let cached = fileURL, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        // Fast path: replace / with - on the cwd.
        let encoded = cwd.path.replacingOccurrences(of: "/", with: "-")
        let candidate = projects.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: candidate.path) {
            fileURL = candidate
            return candidate
        }

        // Fallback scan.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else {
            return nil
        }
        for entry in entries {
            let p = projects.appendingPathComponent(entry).appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: p.path) {
                fileURL = p
                return p
            }
        }
        return nil
    }

    private func process(line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""
        switch type {
        case "permission-mode":
            if let m = json["permissionMode"] as? String { state.permissionMode = m }

        case "ai-title":
            if let t = Self.aiTitle(fromEvent: json) { state.aiTitle = t }

        case "agent-name":
            if let n = json["name"] as? String { state.subagentName = n }

        case "user":
            handleUserMessage(json)

        case "assistant":
            if Self.isSidechain(json) { return }
            handleAssistantMessage(json)

        default:
            return
        }
    }

    private func handleUserMessage(_ json: [String: Any]) {
        // `user` events come in two flavors:
        //   - real prompt: message.content is a String OR an array with text blocks
        //   - tool_result envelope: message.content is an array of {type:"tool_result", ...}
        guard let message = json["message"] as? [String: Any] else { return }
        let content = message["content"]

        // Tool completion timestamp: use the user message's `timestamp` field so
        // durations reflect when the result *actually* arrived, not when we
        // happened to read the line. Falling back to `Date()` would make resumed
        // / replayed transcripts show nonsense durations (`startedAt` parsed
        // from a real timestamp days ago, `endedAt` = now → 3000+ minutes).
        let messageTimestamp = parseTimestamp(json["timestamp"] as? String) ?? Date()

        if let text = content as? String, !text.isEmpty {
            state.lastUserPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if let blocks = content as? [[String: Any]] {
            // tool_result blocks?
            for block in blocks {
                if (block["type"] as? String) == "tool_result" {
                    if let id = block["tool_use_id"] as? String, let starting = toolStarts[id] {
                        let active = ActiveTool(
                            id: id,
                            name: starting.name,
                            preview: starting.preview,
                            startedAt: starting.at,
                            rawInputJSON: starting.inputJSON
                        )
                        let isError = (block["is_error"] as? Bool) == true
                        let completion = CompletedTool(completing: active, isError: isError, at: messageTimestamp)
                        recentToolsRing.append(completion)
                        if recentToolsRing.count > Self.recentToolsCap {
                            recentToolsRing.removeFirst(recentToolsRing.count - Self.recentToolsCap)
                        }
                        toolStarts.removeValue(forKey: id)
                        activeAndRecentDirty = true
                        recomputeActiveAndRecent()
                    }
                    if (block["is_error"] as? Bool) == true {
                        state.errorCount += 1
                    }
                }
            }
            // Else, real user prompt formatted as text blocks.
            let textBits: [String] = blocks.compactMap {
                if ($0["type"] as? String) == "text", let t = $0["text"] as? String { return t }
                return nil
            }
            if !textBits.isEmpty {
                state.lastUserPrompt = textBits.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func handleAssistantMessage(_ json: [String: Any]) {
        guard let message = json["message"] as? [String: Any] else { return }
        state.assistantTurns += 1
        if let model = message["model"] as? String { state.currentModel = model }
        if let stop  = message["stop_reason"] as? String { state.lastStopReason = stop }

        if let usage = message["usage"] as? [String: Any] {
            state.tokens += TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
            if let model = state.currentModel {
                state.estimatedCost = ModelPricing.resolve(model).cost(for: state.tokens)
            }
        }

        // Walk content blocks for text + tool_use.
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        let now = parseTimestamp(json["timestamp"] as? String) ?? Date()
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty {
                    state.lastAssistantText = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "tool_use":
                state.toolCalls += 1
                if let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let preview = ActiveTool.preview(toolName: name, input: input)
                    let inputJSON = input.isEmpty ? nil
                        : (try? JSONSerialization.data(withJSONObject: input))
                    toolStarts[id] = (name: name, preview: preview, at: now, inputJSON: inputJSON)
                    activeAndRecentDirty = true
                }
            default:
                continue
            }
        }
        recomputeActiveAndRecent()
    }

    /// Snapshot `toolStarts` into `state.activeTools` (sorted by startedAt asc)
    /// and `recentToolsRing` into `state.recentTools` (newest-first).
    /// Called only when `toolStarts` or `recentToolsRing` mutates; the
    /// `activeAndRecentDirty` flag prevents redundant recomputes per tick.
    private func recomputeActiveAndRecent() {
        guard activeAndRecentDirty else { return }
        activeAndRecentDirty = false

        state.activeTools = toolStarts
            .map {
                ActiveTool(
                    id: $0.key,
                    name: $0.value.name,
                    preview: $0.value.preview,
                    startedAt: $0.value.at,
                    rawInputJSON: $0.value.inputJSON
                )
            }
            .sorted { $0.startedAt < $1.startedAt }

        state.recentTools = Array(recentToolsRing.reversed())   // newest-first
        // currentTool kept nil — deprecated; UI consumers migrate next.
        state.currentTool = nil
    }

    private func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        // Build per-call: ISO8601DateFormatter isn't Sendable so we can't share
        // a static instance under Swift 6 strict concurrency. Cost is trivial.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: - Test-only hooks
    //
    // Bypass file I/O so unit tests can drive the actor directly. Underscored
    // names mark them as not part of the production surface.
    func _test_processLine(_ line: String) {
        process(line: line)
    }

    /// Batch variant: process many lines inside a single actor hop to avoid
    /// per-line scheduling overhead. Used by PerfBenchmarks.
    func _test_processLines(_ lines: [String]) {
        for line in lines { process(line: line) }
    }

    var _test_state: EnrichedSession { state }
}
