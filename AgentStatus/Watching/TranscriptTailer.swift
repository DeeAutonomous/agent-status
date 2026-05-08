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

    nonisolated let snapshots: AsyncStream<EnrichedSession>
    private let continuation: AsyncStream<EnrichedSession>.Continuation

    private var fileURL: URL?
    private var offset: UInt64 = 0
    private var pendingPartialLine = ""
    private var pollTask: Task<Void, Never>?

    // Derived state — accumulated across messages.
    private var state = EnrichedSession()
    private var toolStarts: [String: (name: String, preview: String, at: Date)] = [:]

    init(sessionId: String, cwd: URL, pollInterval: TimeInterval = 1.0) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.pollInterval = pollInterval

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
            }
            guard size > offset else { return }

            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(size - offset))
            try handle.close()
            offset = size

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
            // Schema observed: { "type":"ai-title", "title":"..." } (best-effort)
            if let t = json["title"] as? String, !t.isEmpty { state.aiTitle = t }

        case "agent-name":
            if let n = json["name"] as? String { state.subagentName = n }

        case "user":
            handleUserMessage(json)

        case "assistant":
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

        if let text = content as? String, !text.isEmpty {
            state.lastUserPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if let blocks = content as? [[String: Any]] {
            // tool_result blocks?
            for block in blocks {
                if (block["type"] as? String) == "tool_result" {
                    if let id = block["tool_use_id"] as? String, toolStarts[id] != nil {
                        toolStarts.removeValue(forKey: id)
                        // Recompute "current tool" from any remaining starts.
                        recomputeCurrentTool()
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
                    toolStarts[id] = (name: name, preview: preview, at: now)
                }
            default:
                continue
            }
        }
        recomputeCurrentTool()
    }

    private func recomputeCurrentTool() {
        // Pick the most recent in-flight tool.
        guard let entry = toolStarts.max(by: { $0.value.at < $1.value.at }) else {
            state.currentTool = nil
            return
        }
        state.currentTool = ActiveTool(
            id: entry.key,
            name: entry.value.name,
            preview: entry.value.preview,
            startedAt: entry.value.at
        )
    }

    private func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        // Build per-call: ISO8601DateFormatter isn't Sendable so we can't share
        // a static instance under Swift 6 strict concurrency. Cost is trivial.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
