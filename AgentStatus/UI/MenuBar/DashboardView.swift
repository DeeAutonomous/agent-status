import SwiftUI

/// Content of the MenuBarExtra `.window` popover. Lists every live (and recently-dead)
/// session with rich state, plus a header summary and footer actions.
struct DashboardView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: Settings
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.snapshots.isEmpty {
                emptyState.padding(.vertical, 24)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.snapshots) { snap in
                            SessionRow(snapshot: snap, buckets: buckets(for: snap.id))
                                .background(Color.clear)
                            if snap.id != store.snapshots.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            footer
        }
        .frame(width: 380)
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(settings)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusRingIcon(status: store.aggregate.dominant, size: 28)
                .opacity(store.aggregate.total == 0 ? 0.45 : 1.0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Status")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusCounts
        }
        .padding(12)
    }

    private var headerSubtitle: String {
        let live = store.snapshots.filter { $0.isAlive }.count
        if live == 0 { return "No live sessions" }
        if live == 1 { return "1 live session" }
        return "\(live) live sessions"
    }

    @ViewBuilder
    private var statusCounts: some View {
        let interesting: [SessionStatus] = [.busy, .waiting, .error]
        HStack(spacing: 6) {
            ForEach(interesting, id: \.self) { st in
                if let n = store.aggregate.counts[st], n > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(st.color).frame(width: 6, height: 6)
                        Text("\(n)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(st.color.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Claude Code sessions running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Open a Claude Code instance and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $settings.perSessionMenuBarItemsEnabled) {
                Text("Per-session icons")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
        .padding(10)
    }

    private func buckets(for snapshotId: String) -> [SessionStatus?] {
        store.history(for: snapshotId).bucket(into: 60, span: 60)
    }
}
