import Foundation
import Darwin

enum LaunchAgentInstallerError: LocalizedError {
    case bundleNotInApplications(URL)
    case launchctlFailed(stage: String, code: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .bundleNotInApplications(let url):
            return "AgentStatus must live under /Applications before installing the LaunchAgent. Currently at: \(url.path)"
        case .launchctlFailed(let stage, let code, let output):
            return "launchctl \(stage) failed (\(code)): \(output)"
        }
    }
}

enum LaunchAgentInstaller {
    static let label = LaunchAgentPlist.label

    /// True iff the plist file exists on disk. Cheap; doesn't query launchd.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: LaunchAgentPlist.plistURL().path)
    }

    /// Write the plist and bootstrap the agent. `appURL` is the .app bundle.
    /// The plist's ProgramArguments points at the bundle's actual executable so
    /// dev builds (in DerivedData, not /Applications) still work.
    static func install(appURL: URL) throws {
        let exec = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(appURL.deletingPathExtension().lastPathComponent)
            .path

        let plistURL = LaunchAgentPlist.plistURL()
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try LaunchAgentPlist.data(executablePath: exec)
        try data.write(to: plistURL, options: .atomic)
        Log.launch.notice("wrote LaunchAgent plist at \(plistURL.path, privacy: .public)")

        let uid = getuid()
        // bootout first to forget any stale registration; ignore failure (165 = not loaded).
        _ = try? runLaunchctl(["bootout", "gui/\(uid)/\(label)"])

        let bootstrap = try runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        if bootstrap.code != 0 {
            throw LaunchAgentInstallerError.launchctlFailed(
                stage: "bootstrap", code: bootstrap.code, output: bootstrap.output
            )
        }
        Log.launch.notice("LaunchAgent bootstrapped")
    }

    /// Stop and forget the agent, delete the plist.
    static func uninstall() throws {
        let uid = getuid()
        let result = try runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        // Not-loaded is fine.
        if result.code != 0 && !result.output.contains("Could not find") {
            throw LaunchAgentInstallerError.launchctlFailed(
                stage: "bootout", code: result.code, output: result.output
            )
        }
        let plistURL = LaunchAgentPlist.plistURL()
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        Log.launch.notice("LaunchAgent uninstalled")
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> (code: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, out)
    }
}
