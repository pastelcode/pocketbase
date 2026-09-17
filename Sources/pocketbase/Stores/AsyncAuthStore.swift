import Foundation

/// An auth store that persists its state through caller-provided async closures.
///
/// State changes are applied to the in-memory store immediately and queued for
/// asynchronous persistence. Queued operations run sequentially in FIFO order:
/// they execute in the order they are enqueued, so a ``clear()`` is never
/// persisted before an earlier ``save(token:record:)``.
///
/// Errors thrown by the persistence closures are ignored — ``save(token:record:)``
/// and ``clear()`` are synchronous and cannot surface them (the reference SDK
/// reports them as unhandled promise rejections) — and the queue continues with
/// the next operation.
///
/// ```swift
/// let store = AsyncAuthStore(
///     save: { payload in
///         try await storage.write(payload)
///     },
///     clear: {
///         try await storage.delete()
///     }
/// )
/// let pb = PocketBase(baseURL: "https://example.com", authStore: store)
/// ```
open class AsyncAuthStore: BaseAuthStore, @unchecked Sendable {
    /// A closure that asynchronously persists the JSON-encoded auth payload.
    public typealias AsyncSaveFunc = @Sendable (String) async throws -> Void
    /// A closure that asynchronously clears the persisted auth payload.
    public typealias AsyncClearFunc = @Sendable () async throws -> Void
    /// A closure that asynchronously loads the initial JSON auth payload.
    ///
    /// The payload uses the same format as ``save(token:record:)`` receives: a
    /// JSON string such as `{"token":"...","record":{...}}`. Return `nil` or
    /// throw to start with an empty store.
    public typealias AsyncInitialLoader = @Sendable () async throws -> String?

    private let saveFunc: AsyncSaveFunc
    private let clearFunc: AsyncClearFunc?
    private let queue = AsyncOperationQueue()

    /// Serial FIFO queue for the async save/clear operations.
    ///
    /// `enqueue` is synchronous so the call order is preserved even when
    /// multiple saves and clears overlap.
    private final class AsyncOperationQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [@Sendable () async -> Void] = []
        private var isProcessing = false

        /// Appends `operation` and starts processing when the queue is idle.
        func enqueue(_ operation: @escaping @Sendable () async -> Void) {
            lock.lock()
            operations.append(operation)
            let shouldStart = !isProcessing
            if shouldStart {
                isProcessing = true
            }
            lock.unlock()

            if shouldStart {
                Task { await self.process() }
            }
        }

        /// Removes and returns the next queued operation, or `nil` when drained.
        private func nextOperation() -> (@Sendable () async -> Void)? {
            lock.lock()
            defer { lock.unlock() }

            if operations.isEmpty {
                isProcessing = false
                return nil
            }
            return operations.removeFirst()
        }

        /// Runs queued operations one at a time in FIFO order.
        private func process() async {
            while let operation = nextOperation() {
                await operation()
            }
        }
    }

    /// Creates a store backed by the given persistence closures.
    ///
    /// - Parameters:
    ///   - save: Called with the JSON-encoded token and record payload on
    ///     every save.
    ///   - clear: Called on ``clear()``. When `nil`, the store enqueues
    ///     `save("")` instead. Defaults to `nil`.
    ///   - initial: A JSON payload used to seed the store. It runs as the first
    ///     queued operation and is persisted again through the `save` closure.
    ///     Defaults to `nil`.
    public init(
        save: @escaping AsyncSaveFunc,
        clear: AsyncClearFunc? = nil,
        initial: String? = nil
    ) {
        self.saveFunc = save
        self.clearFunc = clear
        super.init()

        queue.enqueue { [weak self] in
            self?.loadInitial(initial)
        }
    }

    /// Creates a store whose initial state is loaded asynchronously.
    ///
    /// The loader runs as the first queued operation, so the loaded state is
    /// applied before the saves and clears enqueued after it, and it is
    /// persisted again through the `save` closure. A thrown error or a `nil`
    /// return starts the store empty.
    ///
    /// - Parameters:
    ///   - save: Called with the JSON-encoded token and record payload on
    ///     every save.
    ///   - clear: Called on ``clear()``. When `nil`, the store enqueues
    ///     `save("")` instead. Defaults to `nil`.
    ///   - initialLoader: An async closure returning the JSON payload used to
    ///     seed the store.
    public init(
        save: @escaping AsyncSaveFunc,
        clear: AsyncClearFunc? = nil,
        initialLoader: @escaping AsyncInitialLoader
    ) {
        self.saveFunc = save
        self.clearFunc = clear
        super.init()

        queue.enqueue { [weak self] in
            self?.loadInitial(try? await initialLoader())
        }
    }

    /// Updates the in-memory state and enqueues an asynchronous save.
    ///
    /// - Parameters:
    ///   - token: The new authentication token.
    ///   - record: The new authentication record. Defaults to `nil`.
    open override func save(token: String, record: RecordModel? = nil) {
        super.save(token: token, record: record)

        let encoder = JSONEncoder()
        let dict: [String: AnyCodable] = [
            "token": AnyCodable(token),
            "record": AnyCodable(record)
        ]

        var jsonString = ""
        if let data = try? encoder.encode(dict),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        }

        let saveClosure = self.saveFunc
        let payloadValue = jsonString
        queue.enqueue {
            try? await saveClosure(payloadValue)
        }
    }

    /// Clears the in-memory state and enqueues an asynchronous clear.
    ///
    /// If no clear closure was provided, an empty save is enqueued instead.
    open override func clear() {
        super.clear()

        let clearClosure = self.clearFunc
        let saveClosure = self.saveFunc
        queue.enqueue {
            if let clear = clearClosure {
                try? await clear()
            } else {
                try? await saveClosure("")
            }
        }
    }

    /// Seeds the store from an encoded JSON payload and persists it.
    private func loadInitial(_ payload: String?) {
        guard let payload = payload, !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let jsonDict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return
        }

        let tokenStr = jsonDict["token"]?.value.string ?? ""
        var recordModel: RecordModel? = nil
        if let recVal = jsonDict["record"] ?? jsonDict["model"] {
            if let recData = try? JSONEncoder().encode(recVal) {
                recordModel = try? JSONDecoder().decode(RecordModel.self, from: recData)
            }
        }

        save(token: tokenStr, record: recordModel)
    }
}
