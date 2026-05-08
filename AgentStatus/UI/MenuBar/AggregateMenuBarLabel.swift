import SwiftUI

/// Custom MenuBarExtra label. Reuses StatusRingIcon for visual consistency with
/// per-session items, and shows a session count chip when ≥1 agent is live.
struct AggregateMenuBarLabel: View {
    let aggregate: AggregateState

    var body: some View {
        HStack(spacing: 4) {
            if aggregate.total == 0 {
                Image(systemName: "circle.dotted")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16, height: 16)
            } else {
                // Static (no animation) on the menu bar to keep main-thread layout
                // calm. Rich animation lives in the dashboard popover.
                StaticStatusIcon(status: aggregate.dominant, size: 16)
            }

            if aggregate.total > 0 {
                Text("\(aggregate.total)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if aggregate.total == 0 { return "Agent Status — no live sessions" }
        return "Agent Status — \(aggregate.total) sessions, dominant: \(aggregate.dominant.displayName)"
    }
}
