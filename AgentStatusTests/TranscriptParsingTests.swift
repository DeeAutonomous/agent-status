import XCTest
@testable import AgentStatus

/// Smoke-tests the EnrichedSession derivation logic by feeding TranscriptTailer
/// a synthesized JSONL stream against a real temp file.
final class TranscriptParsingTests: XCTestCase {
    func testActiveToolPreviewBash() {
        let p = ActiveTool.preview(toolName: "Bash", input: ["command": "npm test", "description": "run tests"])
        XCTAssertEqual(p, "npm test")
    }

    func testActiveToolPreviewEditUsesFilenameOnly() {
        let p = ActiveTool.preview(toolName: "Edit", input: ["file_path": "/tmp/example/foo.swift"])
        XCTAssertEqual(p, "foo.swift")
    }

    func testActiveToolPreviewUnknownTool() {
        let p = ActiveTool.preview(toolName: "NoSuchTool", input: ["foo": "bar"])
        XCTAssertEqual(p, "")
    }

    func testEnrichedSessionEmpty() {
        let e = EnrichedSession.empty
        XCTAssertNil(e.currentTool)
        XCTAssertEqual(e.tokens, .zero)
        XCTAssertEqual(e.estimatedCost, 0)
        XCTAssertEqual(e.errorCount, 0)
    }

    func testEnrichedSessionEmptyHasNoActiveOrRecentTools() {
        let e = EnrichedSession.empty
        XCTAssertEqual(e.activeTools, [])
        XCTAssertEqual(e.recentTools, [])
    }

    // MARK: - Sidechain filter
    //
    // Top-level assistant messages bump toolCalls; sidechain ones must not.

    func testSidechainAssistantMessageDoesNotIncrementToolCalls() async {
        let tailer = TranscriptTailer(sessionId: "sc-test", cwd: URL(fileURLWithPath: "/tmp"))
        let json = makeAssistantToolUseJSON(toolUseId: "x", name: "Bash", isSidechain: true)
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.toolCalls, 0, "sidechain tool_use must not bump counter")
        XCTAssertTrue(snap.activeTools.isEmpty)
    }

    func testTopLevelAssistantMessageIncrementsToolCalls() async {
        let tailer = TranscriptTailer(sessionId: "tl-test", cwd: URL(fileURLWithPath: "/tmp"))
        let json = makeAssistantToolUseJSON(toolUseId: "x", name: "Bash", isSidechain: false)
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.toolCalls, 1)
        XCTAssertNotNil(snap.currentTool)
        XCTAssertEqual(snap.currentTool?.name, "Bash")
    }

    // MARK: - Test helpers

    private func makeAssistantToolUseJSON(toolUseId: String, name: String, isSidechain: Bool) -> [String: Any] {
        var top: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "stop_reason": "tool_use",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": name,
                        "input": ["command": "echo hi"],
                    ],
                ],
            ],
        ]
        if isSidechain { top["isSidechain"] = true }
        return top
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
}
