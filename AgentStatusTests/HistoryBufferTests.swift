import XCTest
@testable import AgentStatus

@MainActor
final class HistoryBufferTests: XCTestCase {
    func testAppendDistinctStatusesAccumulate() {
        let buf = HistoryBuffer(cap: 10)
        let t0 = Date()
        buf.append(.init(timestamp: t0, status: .idle))
        buf.append(.init(timestamp: t0.addingTimeInterval(1), status: .busy))
        buf.append(.init(timestamp: t0.addingTimeInterval(2), status: .waiting))
        XCTAssertEqual(buf.samples.count, 3)
        XCTAssertEqual(buf.samples.map(\.status), [.idle, .busy, .waiting])
    }

    func testAppendCoalescesIdenticalTail() {
        let buf = HistoryBuffer(cap: 10)
        let t0 = Date()
        buf.append(.init(timestamp: t0, status: .busy))
        buf.append(.init(timestamp: t0.addingTimeInterval(1), status: .busy))
        buf.append(.init(timestamp: t0.addingTimeInterval(2), status: .busy))
        XCTAssertEqual(buf.samples.count, 1)
        XCTAssertEqual(buf.samples.last?.timestamp, t0.addingTimeInterval(2))
    }

    func testCapTrimsOldest() {
        let buf = HistoryBuffer(cap: 3)
        let t0 = Date()
        // 4 distinct statuses (none coalesced); cap=3 → expect only the last 3.
        buf.append(.init(timestamp: t0, status: .idle))
        buf.append(.init(timestamp: t0.addingTimeInterval(1), status: .busy))
        buf.append(.init(timestamp: t0.addingTimeInterval(2), status: .waiting))
        buf.append(.init(timestamp: t0.addingTimeInterval(3), status: .error))
        XCTAssertEqual(buf.samples.count, 3)
        XCTAssertEqual(buf.samples.map(\.status), [.busy, .waiting, .error])
    }

    func testBucketingForwardFills() {
        let buf = HistoryBuffer()
        let now = Date()
        buf.append(.init(timestamp: now.addingTimeInterval(-50), status: .idle))
        buf.append(.init(timestamp: now.addingTimeInterval(-20), status: .busy))
        let strip = buf.bucket(into: 6, span: 60, now: now)
        XCTAssertEqual(strip.count, 6)
        // After forward-fill, no nils once we've crossed the first sample.
        XCTAssertNotNil(strip.last as Any?)
        XCTAssertEqual(strip.last??.precedence, SessionStatus.busy.precedence)
    }
}
