import Foundation

open class AsyncAuthStore: BaseAuthStore, @unchecked Sendable {
    public typealias AsyncSaveFunc = @Sendable (String) async throws -> Void
    public typealias AsyncClearFunc = @Sendable () async throws -> Void

    private let saveFunc: AsyncSaveFunc
    private let clearFunc: AsyncClearFunc?
    private let queueActor = QueueActor()

    private actor QueueActor {
        private var taskQueue: [@Sendable () async -> Void] = []
        private var isProcessing = false

        func enqueue(_ block: @escaping @Sendable () async -> Void) {
            taskQueue.append(block)
            if !isProcessing {
                isProcessing = true
                Task {
                    await processNext()
                }
            }
        }

        private func processNext() async {
            guard !taskQueue.isEmpty else {
                isProcessing = false
                return
            }
            let next = taskQueue.removeFirst()
            await next()
            await processNext()
        }
    }

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
