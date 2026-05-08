import XCTest
@testable import AgentStatus

@MainActor
final class PerSessionStatusItemTests: XCTestCase {
    func testTooltipBaseLine() {
        let snap = makeSnap(status: .busy)
        XCTAssertEqual(PerSessionStatusItem.tooltip(for: snap),
                       "/tmp/x \u{2014} Busy")
    }

    func testTooltipIncludesWaitingFor() {
        let snap = makeSnap(status: .waiting, waitingFor: "approve Bash")
        XCTAssertTrue(PerSessionStatusItem.tooltip(for: snap)
            .contains("approve Bash"))
    }

    func testTooltipShowsConcurrencyCount() {
        let snap = makeSnap(status: .busy, activeNames: ["Bash", "Bash", "Agent"])
        let tip = PerSessionStatusItem.tooltip(for: snap)
        XCTAssertTrue(tip.contains("3 tools running"))
        XCTAssertTrue(tip.contains("Bash, Bash, Agent"))
    }

    func testTooltipShowsSinglePendingPreviewWhenWaiting() {
        let snap = makeSnap(status: .waiting,
                            waitingFor: "approve Bash",
                            activeNames: ["Bash"],
                            previews: ["xcodebuild test"])
        let tip = PerSessionStatusItem.tooltip(for: snap)
        // Pin the full headline format so the em-dash separator can't be eaten.
        XCTAssertTrue(
            tip.hasPrefix("/tmp/x \u{2014} Waiting \u{2014} approve Bash \u{2014} Bash xcodebuild test"),
            "headline malformed; got: \(tip)"
        )
    }

    func testTooltipSingleActiveToolBusy() {
        let snap = makeSnap(status: .busy,
                            activeNames: ["Bash"],
                            previews: ["npm test"])
        let tip = PerSessionStatusItem.tooltip(for: snap)
        XCTAssertEqual(tip, "/tmp/x \u{2014} Busy \u{2014} Bash npm test")
    }

    private func makeSnap(
        status: SessionStatus,
        waitingFor: String? = nil,
        activeNames: [String] = [],
        previews: [String] = []
    ) -> SessionSnapshot {
        var e = EnrichedSession.empty
        e.activeTools = zip(activeNames, previews + Array(repeating: "", count: max(0, activeNames.count - previews.count)))
            .enumerated()
            .map { i, pair in
                ActiveTool(id: "id\(i)", name: pair.0, preview: pair.1,
                           startedAt: .now, rawInputJSON: nil)
            }
        return SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: URL(fileURLWithPath: "/tmp/x"),
            startedAt: .now,
            updatedAt: .now,
            status: status,
            waitingFor: waitingFor,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: true,
            enriched: e
        )
    }
}
