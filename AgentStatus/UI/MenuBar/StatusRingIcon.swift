import SwiftUI

/// Compact, menu-bar-native status indicator. Just a single hierarchical SF Symbol —
/// no rings, no extras. Apple's own menu bar items work this way (Wi-Fi, battery,
/// time machine), so this matches the platform vocabulary.
///
/// macOS 14 quirks:
///   - `.symbolEffect(.rotate, ...)` is 15+; we hand-roll rotation via SpinningSymbol.
///   - Repeating `.bounce`/`.pulse` is 15+; we drive `.symbolEffect(_:value:)` from a Timer.
struct StatusRingIcon: View {
    let status: SessionStatus
    var size: CGFloat = 18
    var dim: Bool = false

    var body: some View {
        iconView
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status.color.opacity(dim ? 0.45 : 1.0))
            .frame(width: size, height: size, alignment: .center)
            .accessibilityLabel("Status: \(status.displayName)")
    }

    @ViewBuilder
    private var iconView: some View {
        switch status {
        case .busy, .running:
            // Rotating dotted ring — reads as a clean loading spinner.
            SpinningSymbol(name: "circle.dotted", period: 1.6)
                .font(.system(size: size, weight: .semibold))
        case .waiting:
            // "Input needed" — the bell+badge clearly conveys an awaiting action.
            PulsingSymbol(name: "bell.badge.fill", effect: .bounce, period: 1.4)
                .font(.system(size: size, weight: .semibold))
        case .error:
            PulsingSymbol(name: "exclamationmark.octagon.fill", effect: .pulse, period: 0.9)
                .font(.system(size: size, weight: .semibold))
        case .idle:
            // Quiet little dot — alive but resting, deliberately under-sized so
            // it doesn't compete visually with the active states.
            Image(systemName: "circle.fill")
                .font(.system(size: size * 0.5, weight: .medium))
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: size * 0.9, weight: .medium))
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: size * 0.9, weight: .medium))
        case .unknown:
            Image(systemName: "questionmark.circle.dashed")
                .font(.system(size: size * 0.9, weight: .medium))
        }
    }
}

/// Continuous spin driven by SwiftUI animation — works on macOS 14.
struct SpinningSymbol: View {
    let name: String
    var period: Double = 1.6
    @State private var spinning = false

    var body: some View {
        Image(systemName: name)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: period).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Periodic SF Symbol animation (bounce/pulse) on macOS 14: drive `.symbolEffect(_:value:)`
/// from a TimelineView so each tick advances the value and re-fires the effect.
enum PulsingSymbolEffect { case bounce, pulse }

struct PulsingSymbol: View {
    let name: String
    let effect: PulsingSymbolEffect
    var period: Double = 1.2

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / period)
            applyEffect(to: Image(systemName: name), tick: tick)
        }
    }

    @ViewBuilder
    private func applyEffect(to image: Image, tick: Int) -> some View {
        switch effect {
        case .bounce:
            image.symbolEffect(.bounce, value: tick)
        case .pulse:
            image.symbolEffect(.pulse, value: tick)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach([SessionStatus.idle, .busy, .running, .waiting, .error, .paused, .stopped, .unknown("foo")], id: \.self) { st in
            HStack {
                StatusRingIcon(status: st, size: 18)
                    .frame(width: 24)
                Text(st.displayName).font(.caption)
            }
        }
    }
    .padding()
}
