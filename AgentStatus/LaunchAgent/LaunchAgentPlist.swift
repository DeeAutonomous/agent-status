import Foundation

enum LaunchAgentPlist {
    static let label = "ai.autonomous.agent-status"

    /// Build the plist payload pointing at a specific app bundle's executable.
    static func payload(executablePath: String,
                        stdoutPath: String = "/tmp/agent-status.out.log",
                        stderrPath: String = "/tmp/agent-status.err.log") -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath
        ]
    }

    static func data(executablePath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: payload(executablePath: executablePath),
            format: .xml,
            options: 0
        )
    }

    /// ~/Library/LaunchAgents/<label>.plist
    static func plistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}
