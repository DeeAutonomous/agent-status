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

    private var lastRowData: RowData

    /// Width budget: 14pt icon + 6pt spacing + ~154pt two-line text area + 6pt padding ≈ 180pt.
    /// Fixed length avoids Auto Layout cycles between the button and hosting view.
    private static let itemWidth: CGFloat = 180
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

        self.lastRowData = Self.rowData(from: initialSnapshot, now: Date())

        super.init()

        self.popover.delegate = self

        let host = NSHostingView(rootView: PerSessionLabel(row: lastRowData))
        host.frame = NSRect(x: 0, y: 0, width: Self.itemWidth, height: Self.itemHeight)

        if let button = item.button {
            button.image = nil
            button.title = ""
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(host)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = Self.tooltip(for: initialSnapshot)
        }
        hostingView = host
    }

    /// Snapshot ingest hook. Tooltip refreshes every time (cheap — no
    /// view-tree mutation). The SwiftUI tree is rebuilt only when the
    /// derived `RowData` differs from the cached one, so the 1.3 Hz
    /// file-driven ingest doesn't thrash the menu bar layout.
    func update(with snapshot: SessionSnapshot) {
        guard let host = hostingView else { return }

        // Always refresh tooltip — cheap, no view-tree mutation.
        item.button?.toolTip = Self.tooltip(for: snapshot)

        let next = Self.rowData(from: snapshot, now: Date())
        if next == lastRowData { return }

        lastRowData = next
        host.rootView = PerSessionLabel(row: next)
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

    /// Equatable snapshot of every menu-bar-row-relevant field. Used as the
    /// sole redraw gate in `update(with:)` so 1.3 Hz file-driven snapshot
    /// ingest can't thrash the menu bar layout — only meaningful state
    /// transitions produce a new `RowData` and therefore a new SwiftUI tree.
    struct RowData: Equatable {
        let status: SessionStatus
        let title: String
        let bottom: String
        let dim: Bool
        let hasRecentError: Bool
        /// Number of in-flight tool calls — drives the multi-dot icon for
        /// busy/running states. Zero in all other states.
        let activeToolCount: Int
    }

    /// Pure: snapshot + now → RowData. The `now: Date` parameter is the
    /// elapsed-time anchor (production passes `Date()`; tests pass a pinned
    /// date). All formatting decisions live here so the redraw gate can
    /// short-circuit on equality alone.
    static func rowData(from snap: SessionSnapshot, now: Date) -> RowData {
        let title: String
        if let t = snap.enriched?.aiTitle, !t.isEmpty {
            title = t
        } else {
            title = snap.cwdBasename
        }

        let bottom = bottomText(for: snap, now: now)

        let recent = snap.enriched?.recentTools ?? []
        let hasRecentError = recent.prefix(5).contains { $0.isError }

        let isActive = (snap.status == .busy || snap.status == .running)
        let activeToolCount = isActive ? (snap.enriched?.activeTools.count ?? 0) : 0

        return RowData(
            status: snap.status,
            title: title,
            bottom: bottom,
            dim: !snap.isAlive,
            hasRecentError: hasRecentError,
            activeToolCount: activeToolCount
        )
    }

    /// Compute the bottom-row suffix from session state. Returns the empty
    /// string when there's nothing informative to add beyond what the status
    /// icon already conveys — the bottom row is reserved for genuine extra
    /// information (active tool + preview + elapsed, count of parallel tools,
    /// approval target). Status-word-only states (idle, stopped, paused,
    /// error, running, plus the transient busy/waiting variants with no
    /// active tool yet) render with an empty bottom row, letting the icon do
    /// its job alone.
    ///
    /// Truncation of long strings happens at render time.
    private static func bottomText(for snap: SessionSnapshot, now: Date) -> String {
        // Waiting overrides everything else — most action-required.
        if snap.status == .waiting {
            // .last is the pending tool when waiting: activeTools is sorted
            // oldest-first, so the newest entry is the approval target.
            if let pending = snap.enriched?.activeTools.last {
                let trimmed = pending.preview.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    return "approve \(pending.name)"
                }
                return "approve \(pending.name) · \(trimmed)"
            }
            // Transient: status .waiting with no pending tool yet → no extra
            // info to show; icon's `bell.badge.fill` already conveys waiting.
            return ""
        }

        let active = snap.enriched?.activeTools ?? []

        if snap.status == .busy && !active.isEmpty {
            // Elapsed anchor: earliest active tool's startedAt. activeTools
            // is already sorted ascending by startedAt (see TranscriptTailer.
            // recomputeActiveAndRecent), so `.first` is the earliest.
            let elapsedSeconds = max(0, now.timeIntervalSince(active[0].startedAt))
            let minutesSuffix = elapsedSeconds >= 60 ? " · \(Int(elapsedSeconds) / 60)m" : ""

            if active.count == 1 {
                let tool = active[0]
                let trimmed = tool.preview.trimmingCharacters(in: .whitespaces)
                let head = trimmed.isEmpty ? tool.name : "\(tool.name) \(trimmed)"
                return head + minutesSuffix
            }
            // Multi-tool: the multi-dot icon conveys count; the bottom row
            // lists tool names. First 3 visible, "+N more" if larger.
            let names = active.map(\.name)
            let visible = Array(names.prefix(3)).joined(separator: ", ")
            let overflow = names.count - 3
            let head = overflow > 0 ? "\(visible) +\(overflow) more" : visible
            return head + minutesSuffix
        }

        // Status-word-only states (idle, busy-without-active, stopped, paused,
        // error, running, unknown) → empty. The icon carries the status; the
        // bottom row only fills with content when there's something extra
        // worth saying beyond "the session has this status."
        return ""
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

/// SwiftUI content of a per-session NSStatusItem button. Up to two rows inside
/// the fixed 22pt menu bar height: aiTitle (or cwd fallback) at 12pt medium on
/// top, a state-driven suffix at 9pt regular below. When the suffix is empty
/// (idle, stopped, paused, etc. — anything the icon alone already conveys),
/// the bottom row is dropped and the title vertically centers in the slot.
/// Static — no animations.
///
/// The red pip overlay on the status icon is bool-gated (`hasRecentError`) so
/// only the bool-transition crosses a redraw boundary.
struct PerSessionLabel: View {
    let row: PerSessionStatusItem.RowData

    var body: some View {
        HStack(spacing: 6) {
            iconWithPip
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.dim ? .secondary : .primary)
                if !row.bottom.isEmpty {
                    Text(row.bottom)
                        .font(.system(size: 10, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.dim ? .secondary : .primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 180, height: NSStatusBar.system.thickness, alignment: .leading)
    }

    /// Icon column: multi-dot for busy/running (N small blue dots = N in-flight
    /// tools), single StaticStatusIcon for every other state. Red pip overlays
    /// the bottom-right corner when `hasRecentError` is set — bool-gated, so it
    /// only crosses a redraw boundary when the flag flips.
    @ViewBuilder
    private var iconWithPip: some View {
        Group {
            if (row.status == .busy || row.status == .running) && row.activeToolCount >= 1 {
                ConcurrencyDots(count: row.activeToolCount, status: row.status, dim: row.dim)
            } else {
                StaticStatusIcon(status: row.status, size: 14, dim: row.dim)
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if row.hasRecentError {
                Circle()
                    .fill(.red)
                    .frame(width: 4, height: 4)
                    .overlay(Circle().stroke(Color(NSColor.controlBackgroundColor), lineWidth: 0.5))
                    .offset(x: 1, y: 1)
            }
        }
    }
}

/// Renders N small filled circles in a horizontal row. Replaces the single
/// busy/running status icon when there's ≥1 active tool, so the count of
/// in-flight tools is conveyed visually.
///
/// Each dot IS a `StaticStatusIcon` (same code path StaticStatusIcon already
/// uses for idle). The previous version reimplemented the SF Symbol render
/// inline, which produced subtly bigger glyphs than the idle dot — using
/// StaticStatusIcon directly is pixel-identical with idle by construction.
/// Per-dot width is narrowed from StaticStatusIcon's 14pt frame to 10pt to
/// keep the icon column compact even with 5 dots.
///
/// Capped at 5 visible; overflow shown as a small "+" tail.
private struct ConcurrencyDots: View {
    let count: Int
    let status: SessionStatus
    let dim: Bool

    private static let perDotWidth: CGFloat = 10
    private static let spacing: CGFloat = 0
    private static let maxVisible = 5

    var body: some View {
        let visible = min(count, Self.maxVisible)
        HStack(spacing: Self.spacing) {
            ForEach(0..<visible, id: \.self) { _ in
                StaticStatusIcon(status: status, size: 14, dim: dim)
                    .frame(width: Self.perDotWidth)
            }
            if count > Self.maxVisible {
                Text("+")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(status.color.opacity(dim ? 0.45 : 1.0))
            }
        }
        .frame(height: 14, alignment: .center)
        .accessibilityLabel(count == 1 ? "1 tool running" : "\(count) tools running")
    }
}
