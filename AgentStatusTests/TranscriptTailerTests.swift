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

    // MARK: - ai-title parsing
    //
    // Real schema observed in `~/.claude/projects/*.jsonl`:
    //   {"type":"ai-title","aiTitle":"…","sessionId":"…"}
    // An earlier version of `process(line:)` read the wrong key (`"title"`),
    // so the AI title never made it onto the snapshot — the UI toggle was
    // wired up but always rendered nothing.

    func testAITitleEventReadsAITitleField() {
        let event: [String: Any] = [
            "type": "ai-title",
            "aiTitle": "Check git logs",
            "sessionId": "abc",
        ]
        XCTAssertEqual(TranscriptTailer.aiTitle(fromEvent: event), "Check git logs")
    }

    func testAITitleEventIgnoresLegacyTitleKey() {
        // Guards the bug: previously we read `"title"`. That key must not win.
        let event: [String: Any] = [
            "type": "ai-title",
            "title": "wrong key",
        ]
        XCTAssertNil(TranscriptTailer.aiTitle(fromEvent: event))
    }

    func testAITitleEventTreatsEmptyStringAsAbsent() {
        let event: [String: Any] = ["type": "ai-title", "aiTitle": ""]
        XCTAssertNil(TranscriptTailer.aiTitle(fromEvent: event))
    }

    // MARK: - isSidechain

    func testIsSidechainTrueWhenFlagPresent() {
        XCTAssertTrue(TranscriptTailer.isSidechain(["isSidechain": true]))
    }

    func testIsSidechainFalseWhenFlagAbsent() {
        XCTAssertFalse(TranscriptTailer.isSidechain([:]))
    }

    func testIsSidechainFalseWhenFlagFalse() {
        XCTAssertFalse(TranscriptTailer.isSidechain(["isSidechain": false]))
    }

    func testIsSidechainFalseWhenFlagWrongType() {
        // Bool-only — string "true" must not count as truthy.
        XCTAssertFalse(TranscriptTailer.isSidechain(["isSidechain": "true"]))
    }
}
