import Foundation

/// Watches ~/.claude/sessions and emits snapshots of all live Claude Code sessions.
///
/// Two layers of ingest:
///   1. Directory scan (FSEvents + 750ms poll) — detects which sessions exist
///      and their coarse status from `<pid>.json`.
///   2. Per-session TranscriptTailer — incrementally tails each live session's
///      JSONL transcript to derive rich state (current tool, tokens, model, etc.).
///
/// Both feed into the same emit pipeline: any change in either layer triggers
/// `emitMerged()` which combines the latest scan with the latest enriched state.
actor ClaudeCodeProvider: SessionProvider {
    nonisolated let id = "claude-code"
    nonisolated let displayName = "Claude Code"

    private let directory: URL
    private let watcher: DirectoryWatcher
    private let pollInterval: TimeInterval
    private var streamContinuation: AsyncStream<[SessionSnapshot]>.Continuation?
    nonisolated let snapshots: AsyncStream<[SessionSnapshot]>
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // Per-session tailers + their cached enriched output.
    private var tailers: [String: TranscriptTailer] = [:]
    private var tailerTasks: [String: Task<Void, Never>] = [:]
    private var enrichedCache: [String: EnrichedSession] = [:]
    private var lastScan: [SessionSnapshot] = []

    init(directory: URL = ClaudeSessionsURL.directory, pollInterval: TimeInterval = 0.75) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.watcher = DirectoryWatcher(url: directory, debounce: 0.1)

        var cont: AsyncStream<[SessionSnapshot]>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.streamContinuation = cont
    }

    func start() async {
        guard watchTask == nil else { return }
        do {
            try watcher.start()
        } catch {
            Log.provider.error("ClaudeCodeProvider watcher failed to start: \(error.localizedDescription, privacy: .public)")
        }

        watchTask = Task.detached(priority: .utility) { [weak self, watcher] in
            for await _ in watcher.events {
                await self?.performScan()
            }
        }

        let poll = pollInterval
        pollTask = Task.detached(priority: .utility) { [weak self] in
            let nanos = UInt64(poll * 1_000_000_000)
            while !Task.isCancelled {
                await self?.performScan()
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() async {
        watchTask?.cancel()
        watchTask = nil
        pollTask?.cancel()
        pollTask = nil
        watcher.stop()
        for (_, task) in tailerTasks { task.cancel() }
        for (_, tailer) in tailers { await tailer.stop() }
        tailers.removeAll()
        tailerTasks.removeAll()
        enrichedCache.removeAll()
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func performScan() {
        let scanned = Self.scan(directory: directory)
        lastScan = scanned
        syncTailers(to: scanned)
        emitMerged()
    }

    /// Receives an enriched-state update from one tailer and re-emits.
    private func updateEnriched(sessionId: String, enriched: EnrichedSession) {
        enrichedCache[sessionId] = enriched
        emitMerged()
    }

    private func syncTailers(to snapshots: [SessionSnapshot]) {
        let liveIds = Set(snapshots.filter(\.isAlive).map(\.sessionId))

        // Spawn tailers for newly-seen live sessions.
        for snap in snapshots where snap.isAlive && tailers[snap.sessionId] == nil {
            let id = snap.sessionId
            let tailer = TranscriptTailer(sessionId: id, cwd: snap.cwd)
            tailers[id] = tailer
            tailerTasks[id] = Task { [weak self] in
                await tailer.start()
                for await enriched in tailer.snapshots {
                    await self?.updateEnriched(sessionId: id, enriched: enriched)
                }
            }
        }

        // Tear down tailers for sessions that died/disappeared.
        for id in Array(tailers.keys) where !liveIds.contains(id) {
            tailerTasks[id]?.cancel()
            tailerTasks.removeValue(forKey: id)
            if let t = tailers.removeValue(forKey: id) {
                Task { await t.stop() }
            }
            enrichedCache.removeValue(forKey: id)
        }
    }

    private func emitMerged() {
        let merged = lastScan.map { snap -> SessionSnapshot in
            var copy = snap
            copy.enriched = enrichedCache[snap.sessionId]
            return copy
        }
        streamContinuation?.yield(merged)
    }

    /// Pure scan: enumerates the directory, decodes each JSON, applies liveness, sorts.
    nonisolated static func scan(directory: URL) -> [SessionSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        var out: [SessionSnapshot] = []
        out.reserveCapacity(names.count)
        for name in names where name.hasSuffix(".json") {
            let path = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path) else { continue }
            guard let raw = try? decoder.decode(ClaudeRawRecord.self, from: data) else {
                Log.provider.debug("skipping unparseable session file \(name, privacy: .public)")
                continue
            }
            let alive = PIDLiveness.isAlive(raw.pid)
            out.append(raw.toSnapshot(providerId: "claude-code", isAlive: alive))
        }
        out.sort { (a, b) in
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.pid < b.pid
        }
        return out
    }
}
