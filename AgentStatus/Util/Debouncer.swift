import Foundation

/// Coalesces a burst of triggers into a single call after `delay` seconds of quiet.
/// Cheap, lock-protected, Sendable.
final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval = 0.1, queue: DispatchQueue = .global(qos: .utility)) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ block: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: block)
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
