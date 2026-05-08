import Foundation

/// Debug-only telemetry collector for `TranscriptTailer` perf claims.
/// Counters are monotonic until `reset()`. The actor isolates writes so we
/// don't pay for synchronization in the production path — call sites are
/// fire-and-forget `Task { await stats.observe(...) }`.
///
/// Surfaced in a hidden gear-menu pane (debug builds only) — see
/// `Settings.showPerfStats` or the wiring in `MenuBarController`.
actor PerfStats {
    struct Snapshot: Equatable, Sendable {
        var ticks: UInt64 = 0
        var bytes: UInt64 = 0
        var lines: UInt64 = 0
        var yields: UInt64 = 0
    }

    private var counters = Snapshot()

    func observe(tick n: UInt64 = 1)  { counters.ticks  &+= n }
    func observe(bytes n: UInt64)     { counters.bytes  &+= n }
    func observe(lines n: UInt64)     { counters.lines  &+= n }
    func observe(yield n: UInt64 = 1) { counters.yields &+= n }

    func snapshot() -> Snapshot { counters }
    func reset() { counters = Snapshot() }
}
