import Foundation

/// A source of live session snapshots. ClaudeCodeProvider tails ~/.claude/sessions;
/// CodexProvider will do the analogous thing for Codex when its data source lands.
///
/// Each emission is the FULL current state for that provider — consumers replace,
/// not merge. This keeps back-pressure handling trivial (`bufferingNewest(1)`).
protocol SessionProvider: AnyObject, Sendable {
    var id: String { get }            // stable, e.g. "claude-code", "codex"
    var displayName: String { get }
    func start() async
    func stop() async
    var snapshots: AsyncStream<[SessionSnapshot]> { get }
}
