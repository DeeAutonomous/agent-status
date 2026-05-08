import XCTest
@testable import AgentStatus

final class PIDLivenessTests: XCTestCase {
    func testCurrentProcessIsAlive() {
        XCTAssertTrue(PIDLiveness.isAlive(getpid()))
    }

    func testZeroAndNegativeAreNotAlive() {
        XCTAssertFalse(PIDLiveness.isAlive(0))
        XCTAssertFalse(PIDLiveness.isAlive(-1))
    }

    func testHighProbablyDeadPidIsNotAlive() {
        // pid_t max is 2^31-1 on macOS but the kernel caps at much lower; pick something
        // overwhelmingly unlikely to exist.
        XCTAssertFalse(PIDLiveness.isAlive(2_147_483_640))
    }

    func testInitProcessIsAlive() {
        // launchd is always pid 1.
        XCTAssertTrue(PIDLiveness.isAlive(1))
    }
}
