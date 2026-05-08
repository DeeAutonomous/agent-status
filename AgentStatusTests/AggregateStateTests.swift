import XCTest
@testable import AgentStatus

final class AggregateStateTests: XCTestCase {
    private func snap(_ status: SessionStatus, alive: Bool = true, pid: Int32 = 1) -> SessionSnapshot {
        SessionSnapshot(
            id: "claude-code:\(pid)",
            providerId: "claude-code",
            pid: pid,
            sessionId: String(pid),
            cwd: URL(fileURLWithPath: "/tmp"),
            startedAt: Date(),
            updatedAt: Date(),
            status: status,
            waitingFor: nil,
            version: nil,
            kind: "interactive",
            entrypoint: "cli",
            isAlive: alive
        )
    }

    func testEmpty() {
        let agg = AggregateState.from([])
        XCTAssertEqual(agg, AggregateState.empty)
        XCTAssertEqual(agg.dominant, .idle)
    }

    func testDeadSessionsAreIgnored() {
        let agg = AggregateState.from([snap(.busy, alive: false)])
        XCTAssertEqual(agg.total, 0)
    }

    func testPrecedenceErrorWinsOverWaiting() {
        let agg = AggregateState.from([snap(.waiting, pid: 1), snap(.error, pid: 2), snap(.busy, pid: 3)])
        XCTAssertEqual(agg.dominant, .error)
        XCTAssertEqual(agg.total, 3)
    }

    func testPrecedenceWaitingOverBusy() {
        let agg = AggregateState.from([snap(.busy, pid: 1), snap(.waiting, pid: 2)])
        XCTAssertEqual(agg.dominant, .waiting)
    }

    func testBusyFraction() {
        let agg = AggregateState.from([
            snap(.idle, pid: 1),
            snap(.busy, pid: 2),
            snap(.busy, pid: 3),
            snap(.waiting, pid: 4)   // counts as active too
        ])
        XCTAssertEqual(agg.busyFraction, 0.75, accuracy: 0.001)
    }
}
