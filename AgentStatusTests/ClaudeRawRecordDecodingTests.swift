import XCTest
@testable import AgentStatus

final class ClaudeRawRecordDecodingTests: XCTestCase {
    func testDecodesRealFixtureBusy() throws {
        let json = """
        {"pid":12753,"sessionId":"07f9836b-8264-4a4c-8dd9-cbd02ab222e5","cwd":"/tmp/example/project","startedAt":1778214832959,"procStart":"Fri May  8 04:33:52 2026","version":"2.1.133","peerProtocol":1,"kind":"interactive","entrypoint":"cli","status":"busy","updatedAt":1778217178013}
        """.data(using: .utf8)!
        let raw = try JSONDecoder().decode(ClaudeRawRecord.self, from: json)
        XCTAssertEqual(raw.pid, 12753)
        XCTAssertEqual(raw.sessionId, "07f9836b-8264-4a4c-8dd9-cbd02ab222e5")
        XCTAssertEqual(raw.kind, "interactive")
        XCTAssertEqual(raw.status, "busy")
        XCTAssertNil(raw.waitingFor)

        let snap = raw.toSnapshot(providerId: "claude-code", isAlive: true)
        XCTAssertEqual(snap.id, "claude-code:07f9836b-8264-4a4c-8dd9-cbd02ab222e5")
        XCTAssertEqual(snap.status, .busy)
        XCTAssertEqual(snap.cwd.path, "/tmp/example/project")
        XCTAssertTrue(snap.isAlive)
    }

    func testDecodesWithWaitingFor() throws {
        let json = """
        {"pid":99999,"sessionId":"deadbeef","status":"waiting","waitingFor":"approve Bash","startedAt":1778217130493,"updatedAt":1778217170000}
        """.data(using: .utf8)!
        let raw = try JSONDecoder().decode(ClaudeRawRecord.self, from: json)
        let snap = raw.toSnapshot(providerId: "claude-code", isAlive: true)
        XCTAssertEqual(snap.status, .waiting)
        XCTAssertEqual(snap.waitingFor, "approve Bash")
    }

    func testUnknownStatusFallsBackToUnknown() throws {
        let json = """
        {"pid":1,"sessionId":"x","status":"reticulating-splines"}
        """.data(using: .utf8)!
        let raw = try JSONDecoder().decode(ClaudeRawRecord.self, from: json)
        let snap = raw.toSnapshot(providerId: "claude-code", isAlive: false)
        XCTAssertEqual(snap.status, .unknown("reticulating-splines"))
    }

    func testMissingOptionalFields() throws {
        let json = """
        {"pid":1,"sessionId":"x"}
        """.data(using: .utf8)!
        let raw = try JSONDecoder().decode(ClaudeRawRecord.self, from: json)
        XCTAssertNil(raw.kind)
        XCTAssertNil(raw.status)
        let snap = raw.toSnapshot(providerId: "claude-code", isAlive: false)
        XCTAssertEqual(snap.status, .unknown("unknown"))
    }
}
