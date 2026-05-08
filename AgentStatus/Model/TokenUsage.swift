import Foundation

/// Cumulative token counts for a session, split by category.
/// Sums the `usage` blocks emitted on every assistant message.
struct TokenUsage: Hashable, Sendable {
    var input: Int = 0
    var output: Int = 0
    /// Tokens read from the prompt cache — much cheaper than fresh input.
    var cacheRead: Int = 0
    /// Tokens written to the cache — slight premium over fresh input.
    var cacheCreation: Int = 0

    static let zero = TokenUsage()

    var totalInputEquivalent: Int { input + cacheRead + cacheCreation }
    var grandTotal: Int { input + output + cacheRead + cacheCreation }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheCreation: a.cacheCreation + b.cacheCreation
        )
    }
    static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

extension TokenUsage {
    /// Compact human form: "248k" / "1.2M" / "734".
    var compactTotal: String { Self.compact(grandTotal) }
    var compactInput: String { Self.compact(input + cacheRead + cacheCreation) }
    var compactOutput: String { Self.compact(output) }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000:        return "\(n)"
        case ..<1_000_000:    return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0", with: "")
        default:              return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
}
