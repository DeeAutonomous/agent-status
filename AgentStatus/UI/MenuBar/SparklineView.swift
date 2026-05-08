import SwiftUI

/// Thin horizontal strip of colored bars showing the last `span` seconds of status changes.
/// Each column = one bucket; color = status held during that bucket; height ∝ activity weight.
struct SparklineView: View {
    let buckets: [SessionStatus?]
    var span: TimeInterval = 60
    var height: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            guard !buckets.isEmpty else { return }
            let n = CGFloat(buckets.count)
            let colW = size.width / n
            let pad: CGFloat = max(0.5, colW * 0.1)

            for (i, bucket) in buckets.enumerated() {
                let x = CGFloat(i) * colW
                guard let st = bucket else { continue }
                let rel = activityHeight(for: st)
                let h = max(2, size.height * rel)
                let rect = CGRect(x: x + pad / 2,
                                  y: size.height - h,
                                  width: max(1, colW - pad),
                                  height: h)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                ctx.fill(path, with: .color(uiColor(for: st)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Visual weight per status — busy/error stand tall, idle is a low baseline.
    private func activityHeight(for status: SessionStatus) -> CGFloat {
        switch status {
        case .error:   1.0
        case .waiting: 0.85
        case .busy:    0.85
        case .running: 0.7
        case .idle:    0.25
        case .paused:  0.15
        case .stopped: 0.1
        case .unknown: 0.15
        }
    }

    private func uiColor(for status: SessionStatus) -> Color {
        // Slightly higher saturation than the row's tint so the strip reads at a glance.
        switch status {
        case .idle:    return .green.opacity(0.55)
        case .busy:    return .blue
        case .running: return .blue.opacity(0.7)
        case .waiting: return .orange
        case .error:   return .red
        case .paused:  return .gray
        case .stopped: return .secondary
        case .unknown: return .gray.opacity(0.5)
        }
    }
}

#Preview {
    let demo: [SessionStatus?] = (0..<60).map { i in
        switch i / 10 {
        case 0: .idle
        case 1: .busy
        case 2: .busy
        case 3: .waiting
        case 4: .busy
        default: .idle
        }
    }
    return SparklineView(buckets: demo, height: 22)
        .frame(width: 320)
        .padding()
}
