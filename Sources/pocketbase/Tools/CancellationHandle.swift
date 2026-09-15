import Foundation

/// Internal cancellation token used to abort superseded in-flight requests.
///
/// A handle is created for every request that participates in auto-cancellation
/// and stored in the client's registry under its cancellation key. When a newer
/// request uses the same key, `cancel()` runs the registered block, cancelling
/// the underlying `Task` (which in turn cancels the `URLSession` request or a
/// cooperative custom fetch).
final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelBlock: (() -> Void)?
    private var isCancelledFlag = false

    /// Whether ``cancel()`` has already been invoked.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }

    /// Registers the block to run on cancellation. If the handle was already
    /// cancelled the block runs immediately.
    func onCancel(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCancelledFlag {
            lock.unlock()
            block()
            return
        }
        cancelBlock = block
        lock.unlock()
    }

    /// Cancels the handle and runs the registered block once.
    ///
    /// Subsequent calls are ignored.
    func cancel() {
        lock.lock()
        guard !isCancelledFlag else {
            lock.unlock()
            return
        }
        isCancelledFlag = true
        let block = cancelBlock
        cancelBlock = nil
        lock.unlock()

        block?()
    }

    /// Releases the registered block once the request completed so it does not
    /// retain the request task longer than necessary.
    func clear() {
        lock.lock()
        cancelBlock = nil
        lock.unlock()
    }
}
