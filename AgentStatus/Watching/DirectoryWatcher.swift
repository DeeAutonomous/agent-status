import Foundation
import Darwin

/// Watches a directory for any change (file write/create/delete/rename) using
/// DispatchSourceFileSystemObject. Coalesces bursts via a debouncer and surfaces
/// events as an AsyncStream. Auto-reopens the FD on directory rename/delete.
final class DirectoryWatcher: @unchecked Sendable {
    let url: URL
    private let debouncer: Debouncer
    private let queue = DispatchQueue(label: "ai.autonomous.AgentStatus.watcher", qos: .utility)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<Void>.Continuation?
    private(set) var events: AsyncStream<Void>!

    init(url: URL, debounce: TimeInterval = 0.1) {
        self.url = url
        self.debouncer = Debouncer(delay: debounce, queue: queue)
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            self.continuation = cont
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try openSource()
        // Emit one event up-front so the first scan happens immediately, not on first change.
        self.continuation?.yield()
    }

    func stop() {
        lock.lock()
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        lock.unlock()
        debouncer.cancel()
        continuation?.finish()
    }

    private func openSource() throws {
        lock.lock()
        defer { lock.unlock() }

        if fd >= 0 { close(fd) }
        let opened = open(url.path, O_EVTONLY)
        guard opened >= 0 else {
            Log.watcher.error("open(O_EVTONLY) failed for \(self.url.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
        }
        fd = opened

        let mask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .extend, .attrib]
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        src.setEventHandler { [weak self] in self?.handle() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        source = src
        src.resume()
    }

    private func handle() {
        // If the directory was deleted/renamed, re-open against the (potentially new) inode.
        let event = source?.data ?? []
        if event.contains(.delete) || event.contains(.rename) {
            Log.watcher.notice("directory \(self.url.path, privacy: .public) deleted/renamed; reopening")
            do { try openSource() } catch {
                Log.watcher.error("reopen failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        debouncer.schedule { [weak self] in
            self?.continuation?.yield()
        }
    }
}
