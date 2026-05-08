import Foundation

/// One point in a session's status timeline. The sparkline view draws these.
struct SessionHistorySample: Hashable, Sendable {
    let timestamp: Date
    let status: SessionStatus
}
