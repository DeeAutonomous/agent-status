import SwiftUI

/// Animation-free counterpart to StatusRingIcon. Used in the menu bar (aggregate
/// + per-session icons) so we don't run multiple CADisplayLinks against the
/// system menu bar's layout pass — which we discovered the hard way will wedge
/// the main thread once 3+ animated NSStatusItems are present.
///
/// The dashboard popover uses StatusRingIcon (with animations) because it only
/// renders while the popover is open.
struct StaticStatusIcon: View {
    let status: SessionStatus
    var size: CGFloat = 14
    var dim: Bool = false

    var body: some View {
        Image(systemName: glyph)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(status.color.opacity(dim ? 0.45 : 1.0))
            .frame(width: size, height: size, alignment: .center)
            .accessibilityLabel("Status: \(status.displayName)")
    }

    private var glyph: String {
        switch status {
        case .busy, .running: "circle.dotted"
        case .waiting:        "bell.badge.fill"
        case .error:          "exclamationmark.octagon.fill"
        case .idle:           "circle.fill"
        case .stopped:        "stop.circle.fill"
        case .paused:         "pause.circle.fill"
        case .unknown:        "questionmark.circle.dashed"
        }
    }

    /// Idle is intentionally smaller than the active states — calm states
    /// should look calm. Same logic as StatusRingIcon's animated version.
    private var glyphSize: CGFloat {
        switch status {
        case .idle:               size * 0.55
        case .stopped, .paused, .unknown: size * 0.9
        default:                  size
        }
    }
}
