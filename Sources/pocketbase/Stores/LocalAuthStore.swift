import Foundation

open class LocalAuthStore: BaseAuthStore, @unchecked Sendable {
    public let storageKey: String
    private var memoryFallback: [String: Any] = [:]
    private let storeLock = NSRecursiveLock()

    public init(storageKey: String = "pocketbase_auth") {
        self.storageKey = storageKey
        super.init()

        // Load initial state from storage if exists
        if let stored = storageGet(storageKey) {
            let tokenStr = stored["token"] as? String ?? ""
            var recModel: RecordModel? = nil
            if let recDict = (stored["record"] ?? stored["model"]) {
                if let data = try? JSONSerialization.data(withJSONObject: recDict),
                   let rec = try? JSONDecoder().decode(RecordModel.self, from: data) {
                    recModel = rec
                }
            }
            super.save(token: tokenStr, record: recModel)
        }
    }

    open override func save(token: String, record: RecordModel? = nil) {
        var dict: [String: Any] = ["token": token]
        if let record = record {
            if let data = try? JSONEncoder().encode(record),
               let json = try? JSONSerialization.jsonObject(with: data) {
                dict["record"] = json
            }
        }
        storageSet(storageKey, value: dict)
        super.save(token: token, record: record)
    }

    open override func clear() {
        storageRemove(storageKey)
        super.clear()
    }

    private func storageGet(_ key: String) -> [String: Any]? {
        storeLock.lock()
        defer { storeLock.unlock() }

        if let data = UserDefaults.standard.data(forKey: key),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return memoryFallback[key] as? [String: Any]
    }

    private func storageSet(_ key: String, value: [String: Any]) {
        storeLock.lock()
        defer { storeLock.unlock() }

        if let data = try? JSONSerialization.data(withJSONObject: value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            memoryFallback[key] = value
        }
    }

    private func storageRemove(_ key: String) {
        storeLock.lock()
        defer { storeLock.unlock() }

        UserDefaults.standard.removeObject(forKey: key)
        memoryFallback.removeValue(forKey: key)
    }
}
