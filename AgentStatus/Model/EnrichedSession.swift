import Foundation

/// Rich, transcript-derived state for a single session. Computed by TranscriptTailer
/// from `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. Optional fields
/// reflect "we haven't seen this signal yet" (early in a session) — never null
/// once observed.
struct EnrichedSession: Hashable, Sendable {
    /// Active tool — last `tool_use` whose `tool_result` hasn't arrived yet.
    var currentTool: ActiveTool? = nil
    /// Last assistant message's `model` field (e.g. "claude-opus-4-7").
    var currentModel: String? = nil
    /// Last `assistant.message.stop_reason` ("end_turn" / "tool_use" / "max_tokens").
    var lastStopReason: String? = nil
    /// Latest `permission-mode` event ("plan" / "auto" / "bypassPermissions" / "default").
    var permissionMode: String? = nil
    /// Latest `ai-title` event — an auto-generated semantic name for the session.
    var aiTitle: String? = nil
    /// Most recent genuine user prompt (excludes tool_result envelopes).
    var lastUserPrompt: String? = nil
    /// Most recent assistant `text` block (the model's prose, sans tool_use blocks).
    var lastAssistantText: String? = nil
    /// Active sub-agent name if one is currently running (last `agent-name` event
    /// not followed by a "release" — best effort).
    var subagentName: String? = nil
    /// Cumulative tokens across all assistant messages this session.
    var tokens: TokenUsage = .zero
    /// Estimated USD cost — uses the model resolved from `currentModel`. Approximate.
    var estimatedCost: Double = 0
    /// Count of tool_results with `is_error == true`.
    var errorCount: Int = 0
    /// Total assistant messages (proxy for "turns").
    var assistantTurns: Int = 0
    /// Total tool invocations (count of tool_use across all assistant messages).
    var toolCalls: Int = 0

    static let empty = EnrichedSession()
}

/// One in-flight tool call.
struct ActiveTool: Hashable, Sendable {
    let id: String              // Anthropic tool_use_id
    let name: String            // "Bash", "Edit", "Write", "Read", etc.
    let preview: String         // one-line summary of the tool's input
    let startedAt: Date
}

extension ActiveTool {
    /// Build a one-line preview from the tool input dict. Tool-name-specific
    /// shortcuts give the most useful field; falls back to a generic JSON glance.
    static func preview(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return (input["command"] as? String) ?? ""
        case "Edit":
            return (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Write":
            return (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Read":
            return (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        case "Grep":
            return (input["pattern"] as? String) ?? ""
        case "Glob":
            return (input["pattern"] as? String) ?? ""
        case "WebFetch":
            return (input["url"] as? String) ?? ""
        case "WebSearch":
            return (input["query"] as? String) ?? ""
        case "Task":
            return (input["description"] as? String) ?? (input["subagent_type"] as? String) ?? ""
        case "TodoWrite":
            return "todos"
        default:
            return ""
        }
    }
}
