import Foundation

/// Makes sure only one process (the app or the background publisher) runs
/// scheduled posts at a time. Uses an advisory `flock` on a file in the
/// library folder; the OS drops it automatically if the holder crashes.
public final class PublisherLock: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1

    public init(directory: URL) {
        path = directory.appendingPathComponent("publisher.lock").path
    }

    deinit { release() }

    public var isHeld: Bool { fd >= 0 }

    /// Non-blocking. Returns true if this process now holds (or already held) the lock.
    @discardableResult
    public func tryAcquire() -> Bool {
        if fd >= 0 { return true }
        let f = open(path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) == 0 {
            fd = f
            let pid = "\(getpid())\n"
            _ = ftruncate(f, 0)
            _ = pid.withCString { write(f, $0, strlen($0)) }
            return true
        }
        close(f)
        return false
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
