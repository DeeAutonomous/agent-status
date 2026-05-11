import XCTest
@testable import AgentStatus

/// Pure-builder tests for PerSessionStatusItem.rowData(from:now:).
/// All cases use a pinned date so elapsed math is deterministic.
@MainActor
final class PerSessionRowDataTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 100_000)

    // MARK: - Title source

    func testTitleUsesAITitleWhenPresent() {
        var e = EnrichedSession.empty
        e.aiTitle = "Investigate flake"
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "Investigate flake")
    }

    func testTitleFallsBackToCwdBasenameWhenAITitleNil() {
        let snap = makeSnap(cwd: URL(fileURLWithPath: "/Users/dee/repos/agent-status"))
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "agent-status")
    }

    func testTitleFallsBackToCwdBasenameWhenAITitleEmpty() {
        var e = EnrichedSession.empty
        e.aiTitle = ""
        let snap = makeSnap(cwd: URL(fileURLWithPath: "/tmp/foo"), enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "foo")
    }

    // MARK: - Bottom suffix grammar

    func testIdleBottomIsEmpty() {
        // Idle state: icon alone conveys status; bottom row stays empty so
        // the title vertically centers in the menu bar slot.
        let snap = makeSnap(status: .idle)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testSingleToolUnderOneMinuteShowsNameAndPreview() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "npm test", startedAt: t0.addingTimeInterval(-30))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash npm test")
    }

    func testSingleToolOverOneMinuteAppendsMinutes() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "npm test", startedAt: t0.addingTimeInterval(-90))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash npm test · 1m")
    }

    func testSingleToolEmptyPreviewShowsNameOnly() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "", startedAt: t0.addingTimeInterval(-30))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash")
    }

    func testThreeToolsUnderOneMinuteShowsNamesJoined() {
        // Multi-tool: count is conveyed visually by the multi-dot icon.
        // The bottom row lists tool names so the user sees WHAT is running.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "one", startedAt: t0.addingTimeInterval(-35)),
            active(id: "b", name: "Bash", preview: "two", startedAt: t0.addingTimeInterval(-20)),
            active(id: "c", name: "Read", preview: "x",   startedAt: t0.addingTimeInterval(-10)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash, Bash, Read")
    }

    func testThreeToolsOverOneMinuteAppendsMinutesUsingEarliestStart() {
        // Earliest tool started 130s ago → bottom appends · 2m.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "one", startedAt: t0.addingTimeInterval(-130)),
            active(id: "b", name: "Bash", preview: "two", startedAt: t0.addingTimeInterval(-60)),
            active(id: "c", name: "Read", preview: "x",   startedAt: t0.addingTimeInterval(-10)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash, Bash, Read · 2m")
    }

    func testManyToolsShowsOverflowIndicator() {
        // First 3 visible, "+N more" tail for the remainder.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "1", startedAt: t0.addingTimeInterval(-30)),
            active(id: "b", name: "Read", preview: "2", startedAt: t0.addingTimeInterval(-25)),
            active(id: "c", name: "Edit", preview: "3", startedAt: t0.addingTimeInterval(-20)),
            active(id: "d", name: "Grep", preview: "4", startedAt: t0.addingTimeInterval(-15)),
            active(id: "e", name: "Bash", preview: "5", startedAt: t0.addingTimeInterval(-10)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash, Read, Edit +2 more")
    }

    // MARK: - activeToolCount field

    func testActiveToolCountPopulatedForBusy() {
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "1", startedAt: t0.addingTimeInterval(-5)),
            active(id: "b", name: "Bash", preview: "2", startedAt: t0.addingTimeInterval(-3)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.activeToolCount, 2)
    }

    func testActiveToolCountZeroForIdle() {
        // Idle: even if recentTools / activeTools exist in transient states,
        // the icon doesn't draw multi-dots for non-active states.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "x", startedAt: t0.addingTimeInterval(-5)),
        ]
        let snap = makeSnap(status: .idle, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.activeToolCount, 0)
    }

    func testActiveToolCountZeroForWaiting() {
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "x", startedAt: t0.addingTimeInterval(-5)),
        ]
        let snap = makeSnap(status: .waiting, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.activeToolCount, 0)
    }

    func testRunningStatusWithActiveToolsPopulatesBottomAndCount() {
        // `.running` (sdk-cli headless) should behave the same as `.busy`:
        // bottom row gets tool info, activeToolCount drives multi-dot icon.
        // Earlier regression: bottomText only handled `.busy`, leaving
        // `.running` sessions with an icon but no bottom text.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "1", name: "Bash", preview: "npm test", startedAt: t0.addingTimeInterval(-30)),
        ]
        let snap = makeSnap(status: .running, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash npm test")
        XCTAssertEqual(r.activeToolCount, 1)
    }

    func testRunningStatusMultiToolListsNames() {
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "one", startedAt: t0.addingTimeInterval(-130)),
            active(id: "b", name: "Read", preview: "two", startedAt: t0.addingTimeInterval(-60)),
        ]
        let snap = makeSnap(status: .running, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash, Read · 2m")
        XCTAssertEqual(r.activeToolCount, 2)
    }

    func testWaitingWithPendingPreviewIncludesPreview() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "xcodebuild test", startedAt: t0.addingTimeInterval(-5))]
        let snap = makeSnap(status: .waiting, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "approve Bash · xcodebuild test")
    }

    func testWaitingWithEmptyPreviewShowsApproveNameOnly() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "AskUserQuestion", preview: "", startedAt: t0.addingTimeInterval(-2))]
        let snap = makeSnap(status: .waiting, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "approve AskUserQuestion")
    }

    func testBusyWithEmptyActiveToolsHasEmptyBottom() {
        // Transient: status .busy but enriched.activeTools empty (e.g. between
        // the pid.json status flipping to busy and the first tool_use line
        // arriving in the transcript). Icon alone is enough; bottom stays empty.
        let snap = makeSnap(status: .busy)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testWaitingWithNoPendingToolHasEmptyBottom() {
        // Transient: status .waiting but activeTools empty. The bell-badge
        // icon already conveys "waiting"; nothing useful to add as text.
        let snap = makeSnap(status: .waiting)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testStoppedHasEmptyBottom() {
        // stop.fill icon conveys it; no text needed.
        let snap = makeSnap(status: .stopped)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testPausedHasEmptyBottom() {
        // pause.fill icon conveys it; no text needed.
        let snap = makeSnap(status: .paused)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testErrorHasEmptyBottom() {
        // exclamationmark.octagon.fill icon (red) conveys it; no text needed.
        let snap = makeSnap(status: .error)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    func testUnknownHasEmptyBottom() {
        // questionmark.circle.dashed icon conveys the indeterminate state;
        // bottom stays empty rather than echoing the raw status string.
        let snap = makeSnap(status: .unknown("future-status"))
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "")
    }

    // MARK: - Error pip window

    func testHasRecentErrorFalseWhenAllCleanInLastFive() {
        var e = EnrichedSession.empty
        e.recentTools = (0..<3).map { _ in completion(isError: false) }
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    func testHasRecentErrorTrueWhenMostRecentErrored() {
        var e = EnrichedSession.empty
        e.recentTools = [completion(isError: true), completion(isError: false)]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.hasRecentError)
    }

    func testHasRecentErrorTrueWhenErrorInLastFiveButNotMostRecent() {
        var e = EnrichedSession.empty
        e.recentTools = [
            completion(isError: false),   // newest
            completion(isError: false),
            completion(isError: true),    // mid window
            completion(isError: false),
            completion(isError: false),
        ]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.hasRecentError)
    }

    func testHasRecentErrorFalseWhenErrorOutsideLastFive() {
        var e = EnrichedSession.empty
        e.recentTools = [
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: true),    // 6th — outside the prefix-5 window
        ]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    func testHasRecentErrorFalseWhenRecentToolsEmpty() {
        let snap = makeSnap()
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    // MARK: - dim from isAlive

    func testDimTrueWhenSessionNotAlive() {
        let snap = makeSnap(isAlive: false)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.dim)
    }

    func testDimFalseWhenSessionAlive() {
        let snap = makeSnap(isAlive: true)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.dim)
    }

    // MARK: - Redraw gate invariant

    func testIdenticalContentDifferentUpdatedAtProducesEqualRowData() {
        // The whole point of the gate: a snapshot pair that differs only in
        // updatedAt must produce identical RowData so update(with:) short-circuits.
        let a = makeSnap(updatedAt: t0)
        let b = makeSnap(updatedAt: t0.addingTimeInterval(0.7))
        let ra = PerSessionStatusItem.rowData(from: a, now: t0)
        let rb = PerSessionStatusItem.rowData(from: b, now: t0)
        XCTAssertEqual(ra, rb)
    }

    func testIdenticalActiveToolsDifferentUpdatedAtProducesEqualRowData() {
        // Production case: busy session with active tools — the same activeTools
        // and same elapsed-bucketed text must produce identical RowData even
        // when updatedAt ticks every few seconds (the dominant ingest pattern).
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "npm test",
                                startedAt: t0.addingTimeInterval(-30))]
        let a = makeSnap(status: .busy, updatedAt: t0,                      enriched: e)
        let b = makeSnap(status: .busy, updatedAt: t0.addingTimeInterval(0.7), enriched: e)
        let ra = PerSessionStatusItem.rowData(from: a, now: t0)
        let rb = PerSessionStatusItem.rowData(from: b, now: t0)
        XCTAssertEqual(ra, rb)
    }

    // MARK: - Helpers

    private func active(id: String, name: String, preview: String, startedAt: Date) -> ActiveTool {
        ActiveTool(id: id, name: name, preview: preview, startedAt: startedAt, rawInputJSON: nil)
    }

    private func completion(isError: Bool) -> CompletedTool {
        let a = ActiveTool(id: UUID().uuidString, name: "Bash", preview: "x",
                           startedAt: t0.addingTimeInterval(-1), rawInputJSON: nil)
        return CompletedTool(completing: a, isError: isError, at: t0)
    }

    private func makeSnap(
        status: SessionStatus = .idle,
        cwd: URL = URL(fileURLWithPath: "/tmp/sample"),
        updatedAt: Date? = nil,
        isAlive: Bool = true,
        enriched: EnrichedSession? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: cwd,
            startedAt: t0.addingTimeInterval(-200),
            updatedAt: updatedAt ?? t0,
            status: status,
            waitingFor: nil,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: isAlive,
            enriched: enriched ?? EnrichedSession.empty
        )
    }
}
