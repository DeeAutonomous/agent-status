import SwiftUI

/// Roll-up across all live sessions used by the aggregate menu-bar icon.
struct AggregateState: Hashable, Sendable {
    let total: Int
    let counts: [SessionStatus: Int]
    let dominant: SessionStatus       // highest-precedence status present, .idle if empty
    let busyFraction: Double          // fraction of sessions in busy/running/waiting (0...1)

    static let empty = AggregateState(
        total: 0, counts: [:], dominant: .idle, busyFraction: 0
    )

    static func from(_ snapshots: [SessionSnapshot]) -> AggregateState {
        let live = snapshots.filter { $0.isAlive }
        guard !live.isEmpty else { return .empty }

        var counts: [SessionStatus: Int] = [:]
        for s in live { counts[s.status, default: 0] += 1 }

        // Highest-precedence status wins (error > waiting > busy > running > idle).
        let dominant = live.map(\.status).max(by: { $0.precedence < $1.precedence }) ?? .idle
        let active = live.filter {
            switch $0.status {
            case .busy, .running, .waiting: true
            default: false
            }
        }.count
        let frac = Double(active) / Double(live.count)

        return AggregateState(total: live.count, counts: counts, dominant: dominant, busyFraction: frac)
    }

    var dominantColor: Color { dominant.color }
}
