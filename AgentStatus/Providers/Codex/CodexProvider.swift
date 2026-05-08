import Foundation

/// Stub provider. Exists from day 1 so ProviderRegistry → SessionStore plumbing
/// is exercised end-to-end. When the real Codex data source lands (log tail? IPC?)
/// only this file changes; every other layer already handles a second provider.
actor CodexProvider: SessionProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"

    private var continuation: AsyncStream<[SessionSnapshot]>.Continuation?
    nonisolated let snapshots: AsyncStream<[SessionSnapshot]>

    init() {
        var cont: AsyncStream<[SessionSnapshot]>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.continuation = cont
    }

    func start() async {
        // Emit one empty snapshot so the registry knows we're "online" with no sessions.
        continuation?.yield([])
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}
