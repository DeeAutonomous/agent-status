import AppKit
import Combine
import UserNotifications

/// Watches SessionStore + Settings; fires native notifications for three triggers:
///   • A session is in `waiting` for >30s without changing state.
///   • A new tool error arrives (errorCount increases for any session).
///   • A long task (>2 min busy/running) finishes with `stop_reason == "end_turn"`.
///
/// Each trigger has its own Settings toggle. Authorization is requested once on
/// first launch; if denied, this manager silently no-ops.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let store: SessionStore
    private let settings: Settings

    private var cancellables = Set<AnyCancellable>()
    private var authorized = false

    /// Per-session bookkeeping for trigger detection.
    private struct PerSession {
        var lastStatus: SessionStatus
        var waitingSince: Date?
        var waitingNotified: Bool
        var lastErrorCount: Int
        var lastStopReason: String?
        var busySince: Date?     // when status entered busy/running
    }
    private var bookkeeping: [String: PerSession] = [:]

    /// Coalesce: don't re-fire for the same session more often than once per minute.
    private var lastFired: [String: Date] = [:]
    private let cooldown: TimeInterval = 60

    init(store: SessionStore, settings: Settings) {
        self.store = store
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() {
        requestAuthorization()
        // Every snapshot tick: check transitions.
        store.$snapshots
            .sink { [weak self] snaps in self?.evaluate(snapshots: snaps) }
            .store(in: &cancellables)
        // Backup ticker: catches the "waiting > 30s" condition even if the
        // snapshot itself stopped publishing (status hasn't changed).
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.evaluate(snapshots: self.store.snapshots)
            }
            .store(in: &cancellables)
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    private func evaluate(snapshots: [SessionSnapshot]) {
        let now = Date()
        let aliveIds = Set(snapshots.filter(\.isAlive).map(\.id))

        for snap in snapshots where snap.isAlive {
            let prev = bookkeeping[snap.id] ?? PerSession(
                lastStatus: snap.status,
                waitingSince: nil,
                waitingNotified: false,
                lastErrorCount: snap.enriched?.errorCount ?? 0,
                lastStopReason: snap.enriched?.lastStopReason,
                busySince: nil
            )

            // ── waiting > 30s ─────────────────────────────────────────────
            var waitingSince = prev.waitingSince
            var waitingNotified = prev.waitingNotified
            if snap.status == .waiting {
                if waitingSince == nil { waitingSince = now }
                if !waitingNotified,
                   let since = waitingSince,
                   now.timeIntervalSince(since) >= 30,
                   settings.notifyWaiting,
                   canFire(for: snap.id, now: now)
                {
                    fire(
                        title: "Waiting for input",
                        body: "\(snap.cwdBasename) — \(snap.waitingFor ?? "needs your attention")",
                        identifier: "waiting:\(snap.id)"
                    )
                    waitingNotified = true
                    lastFired[snap.id] = now
                }
            } else {
                waitingSince = nil
                waitingNotified = false
            }

            // ── tool error increment ──────────────────────────────────────
            let curErrors = snap.enriched?.errorCount ?? 0
            if curErrors > prev.lastErrorCount,
               settings.notifyToolError,
               canFire(for: "err:" + snap.id, now: now)
            {
                fire(
                    title: "Tool error",
                    body: "\(snap.cwdBasename) — error count: \(curErrors)",
                    identifier: "error:\(snap.id):\(curErrors)"
                )
                lastFired["err:" + snap.id] = now
            }

            // ── long task completion ──────────────────────────────────────
            var busySince = prev.busySince
            switch snap.status {
            case .busy, .running:
                if busySince == nil { busySince = now }
            default:
                busySince = nil
            }
            let curStop = snap.enriched?.lastStopReason
            if curStop == "end_turn", curStop != prev.lastStopReason,
               let started = prev.busySince,
               now.timeIntervalSince(started) >= 120,
               settings.notifyCompletion,
               canFire(for: "done:" + snap.id, now: now)
            {
                let dur = ElapsedFormatter.short(from: started, to: now)
                fire(
                    title: "Task completed",
                    body: "\(snap.cwdBasename) — finished after \(dur)",
                    identifier: "done:\(snap.id):\(now.timeIntervalSinceReferenceDate)"
                )
                lastFired["done:" + snap.id] = now
            }

            bookkeeping[snap.id] = PerSession(
                lastStatus: snap.status,
                waitingSince: waitingSince,
                waitingNotified: waitingNotified,
                lastErrorCount: curErrors,
                lastStopReason: curStop,
                busySince: busySince
            )
        }

        // GC bookkeeping for sessions that disappeared.
        for id in Array(bookkeeping.keys) where !aliveIds.contains(id) {
            bookkeeping.removeValue(forKey: id)
            lastFired.removeValue(forKey: id)
        }
    }

    private func canFire(for key: String, now: Date) -> Bool {
        guard authorized else { return false }
        if let last = lastFired[key], now.timeIntervalSince(last) < cooldown { return false }
        return true
    }

    private func fire(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                Log.ui.error("notification add failed: \(err.localizedDescription, privacy: .public)")
            }
        }
    }

    // Keep notifications visible even when the app is "active" (it's a menu bar agent).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
