import Foundation

/// Provider-agnostic view of one live agent session at one moment in time.
/// `id` is namespaced (`"<providerId>:<sessionId>"`) so two providers can't collide.
struct SessionSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let providerId: String
    let pid: pid_t
    let sessionId: String
    let cwd: URL
    let startedAt: Date
    let updatedAt: Date
    let status: SessionStatus
    let waitingFor: String?
    let version: String?
    let kind: String?            // "interactive" | "oneshot" | ...
    let entrypoint: String?
    let isAlive: Bool
    /// Transcript-derived rich state (current tool, tokens, model, etc.).
    /// Nil for providers/sessions that don't expose a transcript.
    var enriched: EnrichedSession? = nil

    var cwdBasename: String {
        cwd.lastPathComponent.isEmpty ? cwd.path : cwd.lastPathComponent
    }

    /// True if this session should get its own NSStatusItem when per-session items are enabled.
    var deservesPerSessionItem: Bool {
        isAlive && (kind == nil || kind == "interactive")
    }
}
