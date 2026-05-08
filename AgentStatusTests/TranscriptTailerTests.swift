import XCTest
@testable import AgentStatus

/// Regression coverage for the polling-interval → nanoseconds conversion.
///
/// This previously contained an operator-precedence bug where
///   `UInt64(self?.pollInterval ?? 1.0 * 1_000_000_000)`
/// parses as
///   `UInt64(self?.pollInterval ?? (1.0 * 1_000_000_000))`
/// → `UInt64(1.0)` → 1 ns, turning the tailer's `Task.sleep` into a tight loop
/// that pinned multiple cores. The conversion now lives in a named helper so a
/// single test pins the intended behavior.
final class TranscriptTailerTests: XCTestCase {
    func testSleepNanosFromOneSecondPollInterval() {
        XCTAssertEqual(TranscriptTailer.sleepNanos(forPollInterval: 1.0), 1_000_000_000)
    }

    func testSleepNanosFromSubSecondPollInterval() {
        XCTAssertEqual(TranscriptTailer.sleepNanos(forPollInterval: 0.5), 500_000_000)
    }

    func testSleepNanosClampsNegativeToZero() {
        XCTAssertEqual(TranscriptTailer.sleepNanos(forPollInterval: -1.0), 0)
    }
}
