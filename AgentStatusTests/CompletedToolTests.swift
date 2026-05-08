import XCTest
@testable import AgentStatus

final class CompletedToolTests: XCTestCase {
    func testInitFromActiveToolCopiesIdentityFields() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let active = ActiveTool(id: "toolu_1", name: "Bash", preview: "npm test",
                                startedAt: start, rawInputJSON: nil)
        let end = start.addingTimeInterval(2.5)

        let done = CompletedTool(completing: active, isError: false, at: end)

        XCTAssertEqual(done.id, "toolu_1")
        XCTAssertEqual(done.name, "Bash")
        XCTAssertEqual(done.preview, "npm test")
        XCTAssertEqual(done.startedAt, start)
        XCTAssertEqual(done.endedAt, end)
        XCTAssertFalse(done.isError)
        XCTAssertEqual(done.duration, 2.5, accuracy: 0.0001)
    }

    func testIsErrorIsCarriedThrough() {
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        let end = start.addingTimeInterval(0.5)
        let active = ActiveTool(id: "x", name: "Bash", preview: "",
                                startedAt: start, rawInputJSON: nil)
        let done = CompletedTool(completing: active, isError: true, at: end)
        XCTAssertTrue(done.isError)
        XCTAssertEqual(done.duration, 0.5, accuracy: 0.0001)
    }

    func testDurationIsClampedToZeroWhenEndPrecedesStart() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let end = start.addingTimeInterval(-5)   // clock went backward
        let active = ActiveTool(id: "x", name: "Bash", preview: "",
                                startedAt: start, rawInputJSON: nil)
        let done = CompletedTool(completing: active, isError: false, at: end)
        XCTAssertEqual(done.duration, 0, accuracy: 0.0001)
    }

    func testActiveToolHashabilityRespectsRawInputJSON() {
        let when = Date(timeIntervalSinceReferenceDate: 1000)
        let a = ActiveTool(id: "x", name: "Bash", preview: "p",
                           startedAt: when, rawInputJSON: Data([0x01]))
        let b = ActiveTool(id: "x", name: "Bash", preview: "p",
                           startedAt: when, rawInputJSON: Data([0x02]))
        let c = ActiveTool(id: "x", name: "Bash", preview: "p",
                           startedAt: when, rawInputJSON: Data([0x01]))
        XCTAssertNotEqual(a, b, "different rawInputJSON ⇒ unequal")
        XCTAssertEqual(a, c,    "matching rawInputJSON ⇒ equal")
        XCTAssertEqual(a.hashValue, c.hashValue)
    }
}
