import XCTest
@testable import AgentStatus

final class TokenUsageTests: XCTestCase {
    func testCompactFormatting() {
        XCTAssertEqual(TokenUsage.compact(0), "0")
        XCTAssertEqual(TokenUsage.compact(734), "734")
        XCTAssertEqual(TokenUsage.compact(1_000), "1k")
        XCTAssertEqual(TokenUsage.compact(1_234), "1.2k")
        XCTAssertEqual(TokenUsage.compact(247_176), "247.2k")
        XCTAssertEqual(TokenUsage.compact(1_500_000), "1.50M")
    }

    func testAdditionAndAccumulation() {
        var u = TokenUsage(input: 10, output: 20, cacheRead: 30, cacheCreation: 40)
        u += TokenUsage(input: 1, output: 2, cacheRead: 3, cacheCreation: 4)
        XCTAssertEqual(u, TokenUsage(input: 11, output: 22, cacheRead: 33, cacheCreation: 44))
        XCTAssertEqual(u.grandTotal, 110)
    }

    func testCostResolution() {
        let opus = ModelPricing.resolve("claude-opus-4-7")
        XCTAssertEqual(opus.inputPer1M, ModelPricing.opus.inputPer1M)

        let sonnet = ModelPricing.resolve("claude-sonnet-4-6")
        XCTAssertEqual(sonnet.inputPer1M, ModelPricing.sonnet.inputPer1M)

        let haiku = ModelPricing.resolve("claude-haiku-4-5-20251001")
        XCTAssertEqual(haiku.inputPer1M, ModelPricing.haiku.inputPer1M)

        let unknown = ModelPricing.resolve("claude-future-mega-pro-9000")
        XCTAssertEqual(unknown.inputPer1M, ModelPricing.unknown.inputPer1M)
    }

    func testCostOnFixedUsage() {
        // 1M input + 500k output on Sonnet → 1*$3 + 0.5*$15 = $10.50
        let u = TokenUsage(input: 1_000_000, output: 500_000, cacheRead: 0, cacheCreation: 0)
        XCTAssertEqual(ModelPricing.sonnet.cost(for: u), 10.50, accuracy: 0.001)
    }

    func testUSDFormatting() {
        XCTAssertEqual(0.005.asUSD, "<$0.01")
        XCTAssertEqual(0.42.asUSD, "$0.42")
        XCTAssertEqual(15.0.asUSD, "$15.00")
    }
}
