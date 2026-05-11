import XCTest
@testable import AgentStatus

/// Pins the equality semantics at the store layer: a snapshot diff that differs
/// in `enriched.activeTools` / `enriched.recentTools` DOES count as a meaningful
/// change — menu-bar consumers must be woken up so the row redraws.
@MainActor
final class SessionStoreCoreEqualTests: XCTestCase {
    func testActiveToolsChangeIsNotUIEqual() {
        let a = makeSnapshot(activeCount: 0)
        let b = makeSnapshot(activeCount: 3)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
    }

    func testRecentToolsChangeIsNotUIEqual() {
        let a = makeSnapshot(recentCount: 0)
        let b = makeSnapshot(recentCount: 5)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
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
