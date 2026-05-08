import Darwin
import Foundation

enum PIDLiveness {
    /// Returns true if a process with `pid` exists.
    /// `kill(pid, 0)` returns 0 if we can signal it, sets errno to EPERM if it exists but
    /// we lack permission (still alive), or ESRCH if no such process.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
