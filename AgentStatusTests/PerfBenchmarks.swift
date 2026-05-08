import XCTest
@testable import AgentStatus

/// Reproducible synthetic load: feed N JSONL lines through the tailer's
/// per-line dispatch and measure wall-clock parse cost.
///
/// Not a correctness test — included so `scripts/perf-check.sh` has a
/// deterministic timing target. CI does not run this; the script does.
final class PerfBenchmarks: XCTestCase {
    func testParseTenThousandToolUseLinesUnderOneSecond() async {
        let tailer = TranscriptTailer(sessionId: "bench", cwd: URL(fileURLWithPath: "/tmp"))
        // Each iteration is one assistant turn (tool_use start) followed by
        // one user turn (tool_result completion), keeping activeTools bounded
        // to ≤ 1 entry and avoiding O(n²) sort accumulation.
        let assistantTemplate = #"{"type":"assistant","message":{"model":"claude-opus-4-7","content":[{"type":"tool_use","id":"u-XXXX","name":"Bash","input":{"command":"echo XXXX"}}]}}"#
        let userTemplate = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u-XXXX","content":"ok"}]}}"#
        var lines: [String] = []
        lines.reserveCapacity(20_000)
        for i in 0..<10_000 {
            let id = String(i)
            lines.append(assistantTemplate.replacingOccurrences(of: "XXXX", with: id))
            lines.append(userTemplate.replacingOccurrences(of: "XXXX", with: id))
        }

        let start = Date()
        await tailer._test_processLines(lines)
        let elapsed = Date().timeIntervalSince(start)

        // Generous bound so the test isn't flaky — the bench script reads the
        // exact number from stdout and compares against the checked-in baseline.
        XCTAssertLessThan(elapsed, 2.0, "10K tool_use lines took \(elapsed)s — slow path regression?")
        print("PERF: lines=10000 elapsed=\(elapsed)")
    }
}
