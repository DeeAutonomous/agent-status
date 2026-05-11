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

    /// All in-flight top-level tool calls, ordered by `startedAt` ascending.
    /// Sidechain (sub-agent internal) tool calls are filtered out at ingestion.
    var activeTools: [ActiveTool] = []

    /// Recently-completed top-level tool calls, newest-first, capped at 10.
    /// Sidechain tool calls are filtered out at ingestion.
    var recentTools: [CompletedTool] = []

    /// Equality view used by `SessionStore.uiEqual` to gate UI republish events.
    /// Keep this in sync with the row's actual visual dependencies — anything
    /// the menu-bar row reads must compare here.
    func coreEqual(_ other: EnrichedSession) -> Bool {
        currentModel == other.currentModel
            && lastStopReason == other.lastStopReason
            && permissionMode == other.permissionMode
            && aiTitle == other.aiTitle
            && lastUserPrompt == other.lastUserPrompt
            && lastAssistantText == other.lastAssistantText
            && subagentName == other.subagentName
            && tokens == other.tokens
            && estimatedCost == other.estimatedCost
            && errorCount == other.errorCount
            && assistantTurns == other.assistantTurns
            && toolCalls == other.toolCalls
            && currentTool == other.currentTool
            && activeTools == other.activeTools
            && recentTools == other.recentTools
    }

    static let empty = EnrichedSession()
}

/// One in-flight tool call.
struct ActiveTool: Hashable, Sendable {
    let id: String              // Anthropic tool_use_id
    let name: String            // "Bash", "Edit", "Write", "Read", etc.
    let preview: String         // one-line summary of the tool's input
    let startedAt: Date
    /// JSON-encoded copy of the tool's `input` dict, if any. Stored as `Data`
    /// so the struct stays `Hashable, Sendable` under Swift 6 strict concurrency.
    /// Decoded at render time by callers that need question text / options /
    /// subagent prompt fields. Nil when input was empty or un-encodable.
    /// Defaulted so call sites that don't yet thread input through compile cleanly
    /// during the multi-task migration.
    let rawInputJSON: Data?

    init(id: String, name: String, preview: String, startedAt: Date, rawInputJSON: Data? = nil) {
        self.id = id
        self.name = name
        self.preview = preview
        self.startedAt = startedAt
        self.rawInputJSON = rawInputJSON
    }
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
        case "Task", "Agent":
            // Both names appear in transcripts depending on Claude Code version.
            return (input["description"] as? String) ?? (input["subagent_type"] as? String) ?? ""
        case "TodoWrite":
            return "todos"
        default:
            return ""
        }
    }
}

/// One completed top-level tool call — pushed into `EnrichedSession.recentTools`
/// when its `tool_result` arrives. Sidechain (subagent-internal) tool calls do
/// not enter this list.
struct CompletedTool: Hashable, Sendable {
    let id: String              // Anthropic tool_use_id
    let name: String            // "Bash", "Edit", "Agent", ...
    let preview: String         // Reuses ActiveTool.preview at start time
    let startedAt: Date
    let endedAt: Date
    let isError: Bool           // From the tool_result.is_error block

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    init(completing active: ActiveTool, isError: Bool, at end: Date) {
        self.id = active.id
        self.name = active.name
        self.preview = active.preview
        self.startedAt = active.startedAt
        self.endedAt = end
        self.isError = isError
    }
}
