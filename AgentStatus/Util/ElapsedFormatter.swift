import Foundation

enum ElapsedFormatter {
    /// "3s", "42s", "5m 12s", "1h 04m", "2d 03h"
    static func short(from start: Date, to end: Date = Date()) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        let days = hours / 24
        return String(format: "%dd %02dh", days, hours % 24)
    }
}
