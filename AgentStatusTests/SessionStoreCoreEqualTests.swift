import XCTest
@testable import AgentStatus

/// Pins the perf invariant at the store layer: a snapshot diff that differs
/// only in `enriched.activeTools` / `enriched.recentTools` does NOT count as
/// "ui-equal-changed" — i.e. menu-bar consumers don't get woken up.
@MainActor
final class SessionStoreCoreEqualTests: XCTestCase {
    func testActiveToolsChangeIsUIEqual() {
        let a = makeSnapshot(activeCount: 0)
        let b = makeSnapshot(activeCount: 3)
        XCTAssertTrue(SessionStore._test_uiEqual([a], [b]))
    }

    func testRecentToolsChangeIsUIEqual() {
        let a = makeSnapshot(recentCount: 0)
        let b = makeSnapshot(recentCount: 5)
        XCTAssertTrue(SessionStore._test_uiEqual([a], [b]))
    }

    func testStatusChangeIsNotUIEqual() {
        let a = makeSnapshot(status: .busy)
        let b = makeSnapshot(status: .waiting)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
    }

    func testCurrentModelChangeIsNotUIEqual() {
        var ea = EnrichedSession.empty; ea.currentModel = "x"
        var eb = EnrichedSession.empty; eb.currentModel = "y"
        let a = makeSnapshot(enriched: ea)
        let b = makeSnapshot(enriched: eb)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
    }

    private func makeSnapshot(
        status: SessionStatus = .busy,
        activeCount: Int = 0,
        recentCount: Int = 0,
        enriched: EnrichedSession? = nil
    ) -> SessionSnapshot {
        var e = enriched ?? EnrichedSession.empty
        e.activeTools = (0..<activeCount).map {
            ActiveTool(id: "a\($0)", name: "Bash", preview: "x",
                       startedAt: .now, rawInputJSON: nil)
        }
        let active0 = ActiveTool(id: "x", name: "Bash", preview: "x",
                                 startedAt: .now, rawInputJSON: nil)
        e.recentTools = (0..<recentCount).map { _ in
            CompletedTool(completing: active0, isError: false, at: .now)
        }
        return SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: URL(fileURLWithPath: "/tmp"),
            startedAt: .now,
            updatedAt: .now,
            status: status,
            waitingFor: nil,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: true,
            enriched: e
        )
    }
}
