import Foundation

/// Holds all registered providers. Caller drives the merge by iterating
/// `mergedSnapshots()` — emissions are namespaced (providerId, snapshot list)
/// so SessionStore can replace just that provider's slice and recompute the union.
@MainActor
final class ProviderRegistry {
    private(set) var providers: [any SessionProvider] = []

    func register(_ provider: any SessionProvider) {
        providers.append(provider)
    }

    func startAll() async {
        for p in providers { await p.start() }
    }

    func stopAll() async {
        for p in providers { await p.stop() }
    }

    /// Yields `(providerId, latestSnapshots)` whenever any provider emits.
    /// Lives for the registry's lifetime; cancel by terminating the consuming task.
    nonisolated func mergedSnapshots() -> AsyncStream<(String, [SessionSnapshot])> {
        let providers = MainActor.assumeIsolated { self.providers }
        // Bounded buffer: if the consumer ever falls behind, drop intermediate
        // snapshots (each emission is the full state, so losing intermediates is fine).
        // Without a cap, polling could pile up unbounded if layout ever stalls.
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for p in providers {
                        let id = p.id
                        let stream = p.snapshots
                        group.addTask {
                            for await snap in stream {
                                continuation.yield((id, snap))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
