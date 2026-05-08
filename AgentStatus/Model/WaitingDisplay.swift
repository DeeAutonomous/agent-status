import Foundation

/// What the agent is waiting on, in a shape `SessionDetailView` can render.
/// Built by `TranscriptTailer.waitingDisplay(for:pending:pendingInput:)` from
/// the session's `waitingFor` string plus the most recent in-flight tool_use.
///
/// All cases are pure data — no SwiftUI imports here. Truncation, formatting,
/// and option-count limits live at the render site.
enum WaitingDisplay: Hashable, Sendable {
    /// Permission gate for a regular tool. preview is `ActiveTool.preview` output.
    case tool(name: String, preview: String)

    /// Permission gate for `AskUserQuestion`. options are option labels only —
    /// option-level descriptions are intentionally dropped for compactness.
    case askUserQuestion(text: String, options: [String])

    /// Permission gate for a `Task` (sub-agent) invocation.
    case subagent(description: String, prompt: String)

    /// Anything else — fall back to the raw waitingFor string.
    case unknown(rawWaitingFor: String)
}
