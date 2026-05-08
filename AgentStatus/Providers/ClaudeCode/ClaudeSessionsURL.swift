import Foundation

enum ClaudeSessionsURL {
    /// ~/.claude/sessions — resolved against the user's real home (NOT the app sandbox).
    /// Sandbox is OFF for this app, so FileManager.homeDirectoryForCurrentUser is correct.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}
