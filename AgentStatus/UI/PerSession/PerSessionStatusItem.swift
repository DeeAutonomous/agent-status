import AppKit
import SwiftUI

/// One menu-bar icon dedicated to a single session, with a small text label so
/// it's identifiable at a glance. Hosts a SwiftUI HStack { static-icon + cwd }
/// in the button — no animations on the menu bar to keep the main thread quiet.
///
/// Popover content is created **lazily**: the SessionDetailView (which has
/// animated rings + a per-second timer) only exists while the popover is on
/// screen. Without this, every per-session item would keep a SwiftUI view tree
/// running CADisplayLinks 24/7 — even with the popover hidden — and the menu
/// bar would slowly wedge.
@MainActor
final class PerSessionStatusItem: NSObject, NSPopoverDelegate {
    let snapshotId: String
    private let store: SessionStore
    private let settings: Settings
    private let item: NSStatusItem
    private let popover: NSPopover
    private var hostingView: NSHostingView<PerSessionLabel>?

    private var lastStatus: SessionStatus
    private var lastTitle: String
    private var lastDim: Bool

    /// Width budget: ~14pt icon + 5pt spacing + ~70pt text + 12pt padding ≈ 102pt.
    /// Fixed length avoids Auto Layout cycles between the button and hosting view.
    private static let itemWidth: CGFloat = 102
    private static let itemHeight: CGFloat = NSStatusBar.system.thickness

    init(snapshotId: String, initialSnapshot: SessionSnapshot, store: SessionStore, settings: Settings) {
        self.snapshotId = snapshotId
        self.store = store
        self.settings = settings
        self.item = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 320, height: 260)
        // contentViewController stays nil until popover opens — see togglePopover().

        self.lastStatus = initialSnapshot.status
        self.lastTitle = Self.shortTitle(for: initialSnapshot)
        self.lastDim = !initialSnapshot.isAlive

        super.init()

        self.popover.delegate = self

        let host = NSHostingView(rootView: PerSessionLabel(
            status: lastStatus, title: lastTitle, dim: lastDim
        ))
        host.frame = NSRect(x: 0, y: 0, width: Self.itemWidth, height: Self.itemHeight)

        if let button = item.button {
            button.image = nil
            button.title = ""
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(host)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = initialSnapshot.cwd.path
        }
        hostingView = host
    }

    /// Skip if nothing UI-relevant changed (status / title / dim). Critical:
    /// the file's `updatedAt` ticks every Claude write, so naive update-on-every
    /// poll thrashes the menu bar layout.
    func update(with snapshot: SessionSnapshot) {
        let newTitle = Self.shortTitle(for: snapshot)
        let newDim = !snapshot.isAlive
        guard let host = hostingView else { return }

        // Always refresh tooltip — cheap, no view-tree mutation.
        item.button?.toolTip = Self.tooltip(for: snapshot)

        if snapshot.status == lastStatus && newTitle == lastTitle && newDim == lastDim {
            return
        }

        lastStatus = snapshot.status
        lastTitle = newTitle
        lastDim = newDim
        host.rootView = PerSessionLabel(status: snapshot.status, title: newTitle, dim: newDim)
    }

    private static func shortTitle(for snapshot: SessionSnapshot) -> String {
        let base = snapshot.cwdBasename
        let max = 12
        if base.count <= max { return base }
        return String(base.prefix(max - 1)) + "…"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Lazy content: build the SessionDetailView tree only when about to show.
            if popover.contentViewController == nil {
                popover.contentViewController = NSHostingController(
                    rootView: SessionDetailView(snapshotId: snapshotId)
                        .environmentObject(store)
                        .environmentObject(settings)
                )
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    // NSPopoverDelegate — release the SwiftUI view tree when the popover hides,
    // so its timers and animations stop running.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func remove() {
        if popover.isShown { popover.performClose(nil) }
        popover.contentViewController = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Build a multi-line tooltip from a snapshot. Pure — no side effects.
    /// Free to call on every poll: the tooltip is hover-only and never causes
    /// a layout pass.
    static func tooltip(for snap: SessionSnapshot) -> String {
        var lines: [String] = []
        var headline = "\(snap.cwd.path) \u{2014} \(snap.status.displayName)"
        if let w = snap.waitingFor { headline += " \u{2014} \(w)" }

        let active = snap.enriched?.activeTools ?? []
        if active.count > 1 {
            headline += " \u{2014} \(active.count) tools running"
        } else if active.count == 1, let one = active.first {
            let trimmedPreview = one.preview.trimmingCharacters(in: .whitespaces)
            let suffix = trimmedPreview.isEmpty ? one.name : "\(one.name) \(trimmedPreview)"
            headline += " \u{2014} \(suffix)"
        }
        lines.append(headline)

        // Second line: pending tool preview when waiting, or active list when running ≥ 2.
        if snap.status == .waiting, let pending = active.last, !pending.preview.isEmpty {
            lines.append("  \(pending.preview)")
        } else if active.count > 1 {
            let names = active.map(\.name).joined(separator: ", ")
            lines.append("  \(names)")
        }

        return lines.joined(separator: "\n")
    }
}

/// SwiftUI content of a per-session NSStatusItem button. Static-only (no animations).
struct PerSessionLabel: View {
    let status: SessionStatus
    let title: String
    let dim: Bool

    var body: some View {
        HStack(spacing: 5) {
            StaticStatusIcon(status: status, size: 14, dim: dim)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(dim ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 102, height: NSStatusBar.system.thickness, alignment: .leading)
    }
}
