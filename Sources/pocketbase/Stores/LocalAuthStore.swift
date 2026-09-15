import Foundation

/// An auth store that persists its state in `UserDefaults`.
///
/// The token and record are JSON-encoded under ``storageKey`` and reloaded on
/// initialization. If serialization fails, the value is kept in memory for the
/// lifetime of the process.
///
/// ```swift
/// let store = LocalAuthStore(storageKey: "pocketbase_auth")
/// let pb = PocketBase(baseURL: "https://example.com", authStore: store)
/// ```
open class LocalAuthStore: BaseAuthStore, @unchecked Sendable {
    /// The `UserDefaults` key used to persist the auth state.
    public let storageKey: String
    private var memoryFallback: [String: Any] = [:]
    private let storeLock = NSRecursiveLock()

    /// Creates a store and loads any state previously persisted under `storageKey`.
    ///
    /// - Parameter storageKey: The `UserDefaults` key used for persistence.
    ///   Defaults to `"pocketbase_auth"`.
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

    /// Persists the token and record, then notifies registered observers.
    ///
    /// - Parameters:
    ///   - token: The new authentication token.
    ///   - record: The new authentication record. Defaults to `nil`.
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

    /// Removes the persisted state and clears the in-memory values.
    open override func clear() {
        storageRemove(storageKey)
        super.clear()
    }

    /// Loads the persisted dictionary for `key`, falling back to memory.
    private func storageGet(_ key: String) -> [String: Any]? {
        storeLock.lock()
        defer { storeLock.unlock() }

        if let data = UserDefaults.standard.data(forKey: key),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return memoryFallback[key] as? [String: Any]
    }

    /// Persists `value` for `key`, falling back to memory if encoding fails.
    private func storageSet(_ key: String, value: [String: Any]) {
        storeLock.lock()
        defer { storeLock.unlock() }

        if let data = try? JSONSerialization.data(withJSONObject: value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            memoryFallback[key] = value
        }
    }

    /// Removes the value for `key` from both `UserDefaults` and memory.
    private func storageRemove(_ key: String) {
        storeLock.lock()
        defer { storeLock.unlock() }

        UserDefaults.standard.removeObject(forKey: key)
        memoryFallback.removeValue(forKey: key)
    }
}
