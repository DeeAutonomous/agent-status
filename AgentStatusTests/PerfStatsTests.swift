import XCTest
@testable import AgentStatus

final class PerfStatsTests: XCTestCase {
    func testCountersStartAtZero() async {
        let stats = PerfStats()
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 0)
        XCTAssertEqual(s.bytes, 0)
        XCTAssertEqual(s.lines, 0)
        XCTAssertEqual(s.yields, 0)
    }

    func testCountersAreMonotonic() async {
        let stats = PerfStats()
        await stats.observe(tick: 1)
        await stats.observe(bytes: 100)
        await stats.observe(lines: 10)
        await stats.observe(yield: 1)
        await stats.observe(tick: 1)
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 2)
        XCTAssertEqual(s.bytes, 100)
        XCTAssertEqual(s.lines, 10)
        XCTAssertEqual(s.yields, 1)
    }

    func testResetClearsCounters() async {
        let stats = PerfStats()
        await stats.observe(tick: 5)
        await stats.observe(bytes: 999)
        await stats.reset()
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 0)
        XCTAssertEqual(s.bytes, 0)
    }
}
