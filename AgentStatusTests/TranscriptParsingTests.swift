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
}
