import SwiftUI

/// Settings panel surfaced from the dashboard footer. Toggles for visual signals,
/// notifications, and the LaunchAgent installer.
struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @State private var lastError: String?
    @State private var installing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Agent Status — Settings").font(.headline)
                Divider()

                section("Visible signals", systemImage: "eye") {
                    Toggle("Permission mode badge", isOn: $settings.showPermissionMode)
                    Toggle("Tokens & estimated cost", isOn: $settings.showTokensAndCost)
                    Toggle("AI title & last prompt", isOn: $settings.showAITitleAndLastPrompt)
                }

                Divider()

                section("Notifications", systemImage: "bell") {
                    Toggle("Waiting > 30s for input", isOn: $settings.notifyWaiting)
                    Toggle("Tool error", isOn: $settings.notifyToolError)
                    Toggle("Long task completed (>2 min)", isOn: $settings.notifyCompletion)
                    Text("First-time use will prompt for system notification permission.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                section("Menu bar", systemImage: "menubar.dock.rectangle") {
                    Toggle("Show a menu bar icon for each session", isOn: $settings.perSessionMenuBarItemsEnabled)
                }

                Divider()

                section("Launch at login", systemImage: "arrow.up.right.square") {
                    HStack {
                        Text(LaunchAgentInstaller.isInstalled ? "Installed" : "Not installed")
                            .font(.caption)
                            .foregroundStyle(LaunchAgentInstaller.isInstalled ? .green : .secondary)
                        Spacer()
                        Button(LaunchAgentInstaller.isInstalled ? "Reinstall" : "Install") { runInstall() }
                            .disabled(installing)
                        if LaunchAgentInstaller.isInstalled {
                            Button("Uninstall") { runUninstall() }.disabled(installing)
                        }
                        if installing { ProgressView().controlSize(.small) }
                    }
                    Text("Registers ~/Library/LaunchAgents/\(LaunchAgentInstaller.label).plist with launchd. KeepAlive=true; LimitLoadToSessionType=Aqua.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if let err = lastError {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                }
            }
            .padding(16)
        }
        .frame(width: 420, height: 540)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold))
            }
            content().toggleStyle(.switch).controlSize(.small)
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func runInstall() {
        installing = true; lastError = nil
        Task { @MainActor in
            defer { installing = false }
            do {
                try LaunchAgentInstaller.install(appURL: Bundle.main.bundleURL)
                settings.launchAgentInstalled = true
            } catch { lastError = error.localizedDescription }
        }
    }

    private func runUninstall() {
        installing = true; lastError = nil
        Task { @MainActor in
            defer { installing = false }
            do {
                try LaunchAgentInstaller.uninstall()
                settings.launchAgentInstalled = false
            } catch { lastError = error.localizedDescription }
        }
    }
}
