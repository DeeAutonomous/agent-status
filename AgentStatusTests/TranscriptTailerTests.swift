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

    // MARK: - waitingDisplay

    private func makeActive(name: String, preview: String) -> ActiveTool {
        ActiveTool(id: "id", name: name, preview: preview, startedAt: .now, rawInputJSON: nil)
    }

    func testWaitingDisplayNilWhenNotWaiting() {
        XCTAssertNil(TranscriptTailer.waitingDisplay(for: nil, pending: nil, pendingInput: nil))
    }

    func testWaitingDisplayToolCase() {
        let pending = makeActive(name: "Bash", preview: "npm test")
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Bash", pending: pending, pendingInput: nil
        )
        XCTAssertEqual(d, .tool(name: "Bash", preview: "npm test"))
    }

    func testWaitingDisplayAskUserQuestion() {
        let pending = makeActive(name: "AskUserQuestion", preview: "")
        let input: [String: Any] = [
            "questions": [[
                "question": "Which DB?",
                "options": [
                    ["label": "Postgres"],
                    ["label": "SQLite"],
                ],
            ]],
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve AskUserQuestion", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .askUserQuestion(text: "Which DB?", options: ["Postgres", "SQLite"]))
    }

    func testWaitingDisplayAskUserQuestionEmptyOptions() {
        let pending = makeActive(name: "AskUserQuestion", preview: "")
        let input: [String: Any] = [
            "questions": [["question": "Proceed?", "options": [[String: Any]]()]],
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve AskUserQuestion", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .askUserQuestion(text: "Proceed?", options: []))
    }

    func testWaitingDisplaySubagent() {
        let pending = makeActive(name: "Task", preview: "research-foo")
        let input: [String: Any] = [
            "description": "research-foo",
            "prompt": "Find all references to toolStarts and report them.",
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Task", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .subagent(
            description: "research-foo",
            prompt: "Find all references to toolStarts and report them."
        ))
    }

    func testWaitingDisplaySubagentMissingPromptDefaultsToEmpty() {
        let pending = makeActive(name: "Task", preview: "do thing")
        let input: [String: Any] = ["description": "do thing"]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Task", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .subagent(description: "do thing", prompt: ""))
    }

    func testWaitingDisplayUnknownFallback() {
        // No pending tool we recognize → fall back to raw string verbatim.
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Foo", pending: nil, pendingInput: nil
        )
        XCTAssertEqual(d, .unknown(rawWaitingFor: "approve Foo"))
    }
}
