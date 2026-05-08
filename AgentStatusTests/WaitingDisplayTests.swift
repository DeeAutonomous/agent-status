import XCTest
@testable import AgentStatus

final class WaitingDisplayTests: XCTestCase {
    func testToolCaseEquality() {
        let a = WaitingDisplay.tool(name: "Bash", preview: "npm test")
        let b = WaitingDisplay.tool(name: "Bash", preview: "npm test")
        XCTAssertEqual(a, b)
    }

    func testAskUserQuestionCarriesOptions() {
        let d = WaitingDisplay.askUserQuestion(
            text: "Which DB?", options: ["Postgres", "SQLite"]
        )
        if case let .askUserQuestion(text, options) = d {
            XCTAssertEqual(text, "Which DB?")
            XCTAssertEqual(options, ["Postgres", "SQLite"])
        } else {
            XCTFail("expected .askUserQuestion case")
        }
    }

    func testSubagentStoresPromptVerbatim() {
        // The enum stores the prompt verbatim; truncation happens at render time.
        let d = WaitingDisplay.subagent(description: "do thing", prompt: String(repeating: "x", count: 500))
        if case let .subagent(_, prompt) = d {
            XCTAssertEqual(prompt.count, 500)
        } else {
            XCTFail("expected .subagent case")
        }
    }

    func testUnknownPreservesRawString() {
        let d = WaitingDisplay.unknown(rawWaitingFor: "approve Foo")
        XCTAssertEqual(d, .unknown(rawWaitingFor: "approve Foo"))
    }
}
