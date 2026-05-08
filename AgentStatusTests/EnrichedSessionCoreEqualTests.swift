import XCTest
@testable import AgentStatus

/// Pins the perf invariant: mutating activeTools / recentTools must not
/// flip coreEqual (which gates SessionStore @Published updates).
final class EnrichedSessionCoreEqualTests: XCTestCase {
    func testCoreEqualIgnoresActiveTools() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.activeTools = [ActiveTool(id: "x", name: "Bash", preview: "npm",
                                    startedAt: .now, rawInputJSON: nil)]
        XCTAssertTrue(a.coreEqual(b))
    }

    func testCoreEqualIgnoresRecentTools() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        let active = ActiveTool(id: "x", name: "Bash", preview: "npm",
                                startedAt: .now, rawInputJSON: nil)
        b.recentTools = [CompletedTool(completing: active, isError: false, at: .now)]
        XCTAssertTrue(a.coreEqual(b))
    }

    func testCoreEqualNoticesCurrentModelChange() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.currentModel = "claude-opus-4-7"
        XCTAssertFalse(a.coreEqual(b))
    }

    func testCoreEqualNoticesAITitleChange() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.aiTitle = "Investigate flake"
        XCTAssertFalse(a.coreEqual(b))
    }

    func testCoreEqualNoticesPermissionMode() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.permissionMode = "plan"
        XCTAssertFalse(a.coreEqual(b))
    }
}
