import Foundation

/// Per-session ring buffer of status samples for the sparkline view.
/// Capped to `cap` (default 120 ≈ 2 minutes at 1 sample/sec).
@MainActor
final class HistoryBuffer {
    let cap: Int
    private(set) var samples: [SessionHistorySample] = []

    init(cap: Int = 120) { self.cap = cap }

    /// Append a sample; coalesces successive identical statuses by updating the timestamp
    /// of the existing tail (so the sparkline shows transitions, not duplicate plateaus).
    func append(_ sample: SessionHistorySample) {
        if let last = samples.last, last.status == sample.status {
            samples[samples.count - 1] = sample
            return
        }
        samples.append(sample)
        if samples.count > cap {
            samples.removeFirst(samples.count - cap)
        }
    }

    /// Down-sample to `bucketCount` columns by taking the most-recent status in each time slice.
    /// Used by SparklineView to render a fixed-width strip.
    func bucket(into bucketCount: Int, span: TimeInterval, now: Date = Date()) -> [SessionStatus?] {
        guard bucketCount > 0 else { return [] }
        let start = now.addingTimeInterval(-span)
        let slice = span / Double(bucketCount)
        var out = [SessionStatus?](repeating: nil, count: bucketCount)
        for s in samples where s.timestamp >= start {
            let i = min(bucketCount - 1, Int(s.timestamp.timeIntervalSince(start) / slice))
            out[i] = s.status
        }
        // Forward-fill so a long-held status fills the bucket strip rather than blinking.
        var carry: SessionStatus? = nil
        for i in 0..<bucketCount {
            if let s = out[i] { carry = s } else { out[i] = carry }
        }
        return out
    }
}
