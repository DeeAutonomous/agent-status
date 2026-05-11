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
        XCTAssertEqual(snap.activeTools.count, 1)
        XCTAssertEqual(snap.activeTools.first?.name, "Bash")
        XCTAssertNil(snap.currentTool, "currentTool is deprecated and should always be nil")
    }

    func testThreeConcurrentToolUsesProduceThreeActiveTools() async {
        let tailer = TranscriptTailer(sessionId: "para", cwd: URL(fileURLWithPath: "/tmp"))
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "content": [
                    ["type": "tool_use", "id": "a", "name": "Bash", "input": ["command": "one"]],
                    ["type": "tool_use", "id": "b", "name": "Bash", "input": ["command": "two"]],
                    ["type": "tool_use", "id": "c", "name": "Read", "input": ["file_path": "/tmp/x"]],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.activeTools.count, 3)
        // Active tools are sorted by startedAt ascending — all three started
        // from the same assistant message timestamp, so ordering by id is
        // implementation-defined; just check the set.
        XCTAssertEqual(Set(snap.activeTools.map(\.id)), ["a", "b", "c"])
    }

    // MARK: - recentTools ring + error carry-through

    func testToolStartThenResultMovesToRecentTools() async {
        let tailer = TranscriptTailer(sessionId: "rt", cwd: URL(fileURLWithPath: "/tmp"))

        let start: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "content": [
                    ["type": "tool_use", "id": "u1", "name": "Bash",
                     "input": ["command": "ls"]],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(start))

        let result: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "u1",
                     "is_error": false],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(result))

        let snap = await tailer._test_state
        XCTAssertTrue(snap.activeTools.isEmpty, "completed tool should leave activeTools")
        XCTAssertEqual(snap.recentTools.count, 1)
        XCTAssertEqual(snap.recentTools.first?.id, "u1")
        XCTAssertEqual(snap.recentTools.first?.name, "Bash")
        XCTAssertFalse(snap.recentTools.first?.isError ?? true)
    }

    func testRecentToolsRingCapsAt10() async {
        let tailer = TranscriptTailer(sessionId: "ring", cwd: URL(fileURLWithPath: "/tmp"))
        // 12 start+result pairs → only the last 10 should remain.
        for i in 0..<12 {
            let id = "u\(i)"
            await tailer._test_processLine(jsonString([
                "type": "assistant",
                "message": [
                    "content": [
                        ["type": "tool_use", "id": id, "name": "Bash",
                         "input": ["command": "echo \(i)"]],
                    ],
                ],
            ]))
            await tailer._test_processLine(jsonString([
                "type": "user",
                "message": [
                    "content": [
                        ["type": "tool_result", "tool_use_id": id, "is_error": false],
                    ],
                ],
            ]))
        }
        let snap = await tailer._test_state
        XCTAssertEqual(snap.recentTools.count, 10)
        // Newest first: the last completion (u11) should be at index 0.
        XCTAssertEqual(snap.recentTools.first?.id, "u11")
        // u0 and u1 should be gone.
        XCTAssertFalse(snap.recentTools.contains { $0.id == "u0" })
        XCTAssertFalse(snap.recentTools.contains { $0.id == "u1" })
    }

    func testToolErrorIsCarriedIntoRecent() async {
        let tailer = TranscriptTailer(sessionId: "err", cwd: URL(fileURLWithPath: "/tmp"))
        await tailer._test_processLine(jsonString([
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "tool_use", "id": "x", "name": "Bash",
                     "input": ["command": "false"]],
                ],
            ],
        ]))
        await tailer._test_processLine(jsonString([
            "type": "user",
            "message": [
                "content": [
                    ["type": "tool_result", "tool_use_id": "x", "is_error": true],
                ],
            ],
        ]))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.recentTools.first?.isError, true)
    }

    func testRecentToolDurationUsesTranscriptTimestampsNotWallClock() async {
        // Regression: durations were computed as `Date() - startedAt`, which is
        // wrong when the tailer is reading a transcript from a session that ran
        // days ago. The completion timestamp must come from the user message's
        // `timestamp` field, not the wall clock at line-read time.
        let tailer = TranscriptTailer(sessionId: "dur", cwd: URL(fileURLWithPath: "/tmp"))

        // Assistant message at T0, tool_result at T0 + 1.5s — both timestamps
        // sit ~ years before "now" so a wall-clock duration would be huge.
        await tailer._test_processLine(jsonString([
            "type": "assistant",
            "timestamp": "2024-01-01T00:00:00.000Z",
            "message": [
                "content": [
                    ["type": "tool_use", "id": "u1", "name": "Bash",
                     "input": ["command": "echo hi"]],
                ],
            ],
        ]))
        await tailer._test_processLine(jsonString([
            "type": "user",
            "timestamp": "2024-01-01T00:00:01.500Z",
            "message": [
                "content": [
                    ["type": "tool_result", "tool_use_id": "u1", "is_error": false],
                ],
            ],
        ]))

        let snap = await tailer._test_state
        let dur = snap.recentTools.first?.duration ?? -1
        XCTAssertEqual(dur, 1.5, accuracy: 0.01,
                       "duration must come from transcript timestamps, not wall clock; got \(dur)s")
    }

    func testChunkedReadParsesLargeTranscriptInOneTick() async throws {
        // Build a 2 MB synthetic transcript and feed it via the real file-based
        // tick path. The tailer must parse it without OOM and produce expected
        // state, regardless of total file size.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-status-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Encode the cwd as Claude does: replace "/" with "-".
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let encoded = dir.path.replacingOccurrences(of: "/", with: "-")
        let projDir = projects.appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projDir) }

        let sessionId = "chunk-\(UUID().uuidString)"
        let file = projDir.appendingPathComponent("\(sessionId).jsonl")

        // ~2 MB of assistant tool_use lines (each ~200 bytes → ~10 000 lines).
        let oneLine = """
        {"type":"assistant","message":{"model":"claude-opus-4-7","content":[{"type":"tool_use","id":"id-XXXX","name":"Bash","input":{"command":"echo XXXX"}}]}}
        """
        var blob = ""
        for i in 0..<10_000 {
            blob += oneLine.replacingOccurrences(of: "XXXX", with: String(i)) + "\n"
        }
        try blob.write(to: file, atomically: true, encoding: .utf8)

        let tailer = TranscriptTailer(sessionId: sessionId, cwd: dir, pollInterval: 0.05)
        await tailer.start()
        defer { Task { await tailer.stop() } }

        // Drain a few ticks until the file is fully read. Cap so the test
        // can't hang.
        var snap = EnrichedSession.empty
        for await s in tailer.snapshots.prefix(40) {
            snap = s
            if snap.toolCalls >= 10_000 { break }
        }
        XCTAssertEqual(snap.toolCalls, 10_000, "all lines should be parsed across multiple chunks")
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
