import Foundation
import SwiftUI
import Combine

/// Single source of truth for the UI. Subscribes to ProviderRegistry's merged stream,
/// keeps a per-provider slice, and exposes the union as `@Published var snapshots`.
/// Also runs a 5s backup ticker that re-runs PID liveness in case a process dies
/// without touching its file (so its session file mtime never changes).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshots: [SessionSnapshot] = []
    @Published private(set) var aggregate: AggregateState = .empty

    private let registry: ProviderRegistry
    private let livenessInterval: TimeInterval
    private var perProvider: [String: [SessionSnapshot]] = [:]
    private var histories: [String: HistoryBuffer] = [:]
    private var streamTask: Task<Void, Never>?
    private var livenessTimer: Timer?

    init(registry: ProviderRegistry, livenessInterval: TimeInterval = 5) {
        self.registry = registry
        self.livenessInterval = livenessInterval
    }

    func start() async {
        guard streamTask == nil else { return }
        await registry.startAll()
        let merged = registry.mergedSnapshots()
        streamTask = Task { [weak self] in
            for await (providerId, snaps) in merged {
                self?.ingest(providerId: providerId, snapshots: snaps)
            }
        }
        scheduleLivenessTicker()
    }

    func stop() async {
        streamTask?.cancel()
        streamTask = nil
        livenessTimer?.invalidate()
        livenessTimer = nil
        await registry.stopAll()
    }

    /// Returns (creating if needed) the rolling history buffer for a given snapshot id.
    func history(for snapshotId: String) -> HistoryBuffer {
        if let buf = histories[snapshotId] { return buf }
        let buf = HistoryBuffer()
        histories[snapshotId] = buf
        return buf
    }

    private func ingest(providerId: String, snapshots incoming: [SessionSnapshot]) {
        let prev = perProvider[providerId] ?? []
        perProvider[providerId] = incoming

        // History buffer always tracks every poll (it's not @Published, so this
        // doesn't trigger any UI re-render — it just keeps sparkline samples honest).
        let now = Date()
        for s in incoming where s.isAlive {
            history(for: s.id).append(SessionHistorySample(timestamp: now, status: s.status))
        }

        // Skip the @Published recompute if nothing UI-relevant changed. This is
        // critical: Claude updates `updatedAt` every few seconds even when status
        // doesn't change, so naive full-equality would always fail and we'd thrash
        // every consumer (menu bar layout, NSStatusItems, dashboard) ~1.3×/sec.
        if Self.uiEqual(prev, incoming) { return }
        recompute()
    }

    /// Compares only fields that affect what's drawn — id, status, waitingFor,
    /// isAlive, kind, cwd. Ignores updatedAt and other "live-but-cosmetic" fields.
    private static func uiEqual(_ a: [SessionSnapshot], _ b: [SessionSnapshot]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id
                || x.status != y.status
                || x.waitingFor != y.waitingFor
                || x.isAlive != y.isAlive
                || x.kind != y.kind
                || x.cwd != y.cwd
                || !enrichedCoreEqual(x.enriched, y.enriched)
            { return false }
        }
        return true
    }

    /// True when the menu-bar-row-relevant subset of the two enriched values
    /// match. Detail-only fields (`activeTools`, `recentTools`) are excluded
    /// so churn there doesn't trigger a row redraw.
    private static func enrichedCoreEqual(_ a: EnrichedSession?, _ b: EnrichedSession?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.coreEqual(y)
        default: return false
        }
    }

    /// Test-only hook so XCTest can pin the perf invariant.
    static func _test_uiEqual(_ a: [SessionSnapshot], _ b: [SessionSnapshot]) -> Bool {
        uiEqual(a, b)
    }

    private func recompute() {
        let union = perProvider.values.flatMap { $0 }
        // Sort: alive first, then by startedAt ascending.
        let sorted = union.sorted { (a, b) in
            if a.isAlive != b.isAlive { return a.isAlive && !b.isAlive }
            return a.startedAt < b.startedAt
        }
        // GC histories for sessions that no longer exist at all.
        let liveIds = Set(sorted.map(\.id))
        histories = histories.filter { liveIds.contains($0.key) }

        if !Self.uiEqual(snapshots, sorted) { snapshots = sorted }
        let newAggregate = AggregateState.from(sorted)
        if aggregate != newAggregate { aggregate = newAggregate }
    }

    private func scheduleLivenessTicker() {
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: livenessInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveness()
            }
        }
    }

    private func refreshLiveness() {
        // Cheap: just re-validate PIDs of currently-known snapshots; no disk I/O.
        var changed = false
        for (provider, snaps) in perProvider {
            var updated = snaps
            for i in updated.indices {
                let alive = PIDLiveness.isAlive(updated[i].pid)
                if alive != updated[i].isAlive {
                    updated[i] = SessionSnapshot(
                        id: updated[i].id,
                        providerId: updated[i].providerId,
                        pid: updated[i].pid,
                        sessionId: updated[i].sessionId,
                        cwd: updated[i].cwd,
                        startedAt: updated[i].startedAt,
                        updatedAt: updated[i].updatedAt,
                        status: updated[i].status,
                        waitingFor: updated[i].waitingFor,
                        version: updated[i].version,
                        kind: updated[i].kind,
                        entrypoint: updated[i].entrypoint,
                        isAlive: alive
                    )
                    changed = true
                }
            }
            perProvider[provider] = updated
        }
        if changed { recompute() }
    }
}
