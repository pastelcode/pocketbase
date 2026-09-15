import Foundation

/// An auth store that persists its state through caller-provided async closures.
///
/// State changes are applied to the in-memory store immediately and queued for
/// asynchronous persistence. Queued operations run sequentially in FIFO order:
/// they execute in the order they are enqueued, so a ``clear()`` is never
/// persisted before an earlier ``save(token:record:)``.
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

    private let saveFunc: AsyncSaveFunc
    private let clearFunc: AsyncClearFunc?
    private let queueActor = QueueActor()

    private actor QueueActor {
        private var taskQueue: [@Sendable () async -> Void] = []
    /// Serial FIFO queue for the async save/clear operations.
    ///
    /// `enqueue` is synchronous so the call order is preserved: `clear()`
    /// triggers a polymorphic `save("")` from the base class before queueing
    /// its own operation, and both must run in that order.
        private var isProcessing = false

        func enqueue(_ block: @escaping @Sendable () async -> Void) {
            taskQueue.append(block)
            if !isProcessing {
        /// Appends `operation` and starts processing when the queue is idle.
                isProcessing = true
                Task {
                    await processNext()
                }
            }
        }

        private func processNext() async {
            guard !taskQueue.isEmpty else {
        /// Removes and returns the next queued operation, or `nil` when drained.
                isProcessing = false
                return
        /// Runs queued operations one at a time in FIFO order.
            }
            let next = taskQueue.removeFirst()
            await next()
            await processNext()
        }
    }

    /// Creates a store backed by the given persistence closures.
    ///
    /// - Parameters:
    ///   - save: Called with the JSON-encoded token and record payload on
    ///     every save.
    ///   - clear: Called on ``clear()``. When `nil`, the store enqueues
    ///     `save("")` instead. Defaults to `nil`.
    ///   - initial: A JSON payload used to seed the in-memory state without
    ///     invoking `save`. Defaults to `nil`.
    public init(
        save: @escaping AsyncSaveFunc,
        clear: AsyncClearFunc? = nil,
        initial: String? = nil
    ) {
        self.saveFunc = save
        self.clearFunc = clear
        super.init()

        if let initial = initial, !initial.isEmpty {
            loadInitial(initial)
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
        let actor = self.queueActor
        Task {
            await actor.enqueue {
                try? await saveClosure(payloadValue)
            }
        }
    }

    /// Clears the in-memory state and enqueues an asynchronous clear.
    ///
    /// If no clear closure was provided, an empty save is enqueued instead.
    open override func clear() {
        super.clear()

        let clearClosure = self.clearFunc
        let saveClosure = self.saveFunc
        let actor = self.queueActor
        Task {
            await actor.enqueue {
                if let clear = clearClosure {
                    try? await clear()
                } else {
                    try? await saveClosure("")
                }
            }
        }
    }

    /// Seeds the in-memory state from an encoded JSON payload.
    private func loadInitial(_ payload: String) {
        guard let data = payload.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        if let jsonDict = try? decoder.decode([String: AnyCodable].self, from: data) {
            let tokenStr = jsonDict["token"]?.value.string ?? ""
            var recordModel: RecordModel? = nil
            if let recVal = jsonDict["record"] ?? jsonDict["model"] {
                if let recData = try? JSONEncoder().encode(recVal) {
                    recordModel = try? decoder.decode(RecordModel.self, from: recData)
                }
            }
            super.save(token: tokenStr, record: recordModel)
        }
    }
}
