import Foundation

/// An auth store that persists its state in `UserDefaults`.
///
/// The token and record are JSON-encoded under ``storageKey``. Unlike
/// ``BaseAuthStore``, the ``token`` and ``record`` getters read the storage on
/// every access, so every instance backed by the same suite always serves the
/// latest persisted state:
///
/// ```swift
/// let storeA = LocalAuthStore(storageKey: "pocketbase_auth")
/// let storeB = LocalAuthStore(storageKey: "pocketbase_auth")
///
/// storeA.save(token: token, record: record)
/// storeB.token // the token saved by storeA
/// ```
///
/// - Important: `UserDefaults` is not encrypted. For production, prefer
///   ``AsyncAuthStore`` backed by the Keychain so the token is not readable
///   from a plain-text app container or backup.
/// - Note: `UserDefaults` has no reliable cross-process change notification on
///   iOS and Android, so writes made by another process are reflected on the
///   next read but do not fire ``BaseAuthStore/onChange(fireImmediately:callback:)``.
open class LocalAuthStore: BaseAuthStore, @unchecked Sendable {
    /// The `UserDefaults` key used to persist the auth state.
    public let storageKey: String
    /// The `UserDefaults` suite used for persistence.
    public let storage: UserDefaults

    private var memoryFallback: [String: Any] = [:]
    private let storeLock = NSRecursiveLock()

    /// Creates a store backed by the given `UserDefaults` suite.
    ///
    /// - Parameters:
    ///   - storageKey: The key used for persistence. Defaults to
    ///     `"pocketbase_auth"`.
    ///   - storage: The suite used for persistence. Defaults to
    ///     `UserDefaults.standard`; pass a custom suite to isolate the state
    ///     (for example in tests).
    public init(storageKey: String = "pocketbase_auth", storage: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.storage = storage
        super.init()
    }

    /// The token persisted under ``storageKey``.
    ///
    /// Returns an empty string when the storage is empty or corrupted.
    open override var token: String {
        guard let stored = storageGet(storageKey) else { return "" }
        return stored["token"] as? String ?? ""
    }

    /// The record persisted under ``storageKey``.
    ///
    /// Returns `nil` when the storage is empty or corrupted. The legacy
    /// `model` key is accepted for parity with the reference SDK.
    open override var record: RecordModel? {
        guard let stored = storageGet(storageKey),
              let recordValue = stored["record"] ?? stored["model"],
              JSONSerialization.isValidJSONObject(recordValue),
              let data = try? JSONSerialization.data(withJSONObject: recordValue) else {
            return nil
        }
        return try? JSONDecoder().decode(RecordModel.self, from: data)
    }

    /// Persists the token and record, then notifies registered observers.
    ///
    /// - Parameters:
    ///   - token: The new authentication token.
    ///   - record: The new authentication record. Defaults to `nil`.
    open override func save(token: String, record: RecordModel? = nil) {
        var dict: [String: Any] = ["token": token]
        if let record = record,
           let data = try? JSONEncoder().encode(record),
           let json = try? JSONSerialization.jsonObject(with: data) {
            dict["record"] = json
        }

        storageSet(storageKey, value: dict)
        super.save(token: token, record: record)
    }

    /// Removes the persisted state and clears the in-memory values.
    open override func clear() {
        storageRemove(storageKey)
        super.clear()
    }

    /// Loads the persisted dictionary for `key`, falling back to the in-memory
    /// copy when the suite has no usable value.
    private func storageGet(_ key: String) -> [String: Any]? {
        storeLock.lock()
        defer { storeLock.unlock() }

        if let data = storage.data(forKey: key),
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
            storage.set(data, forKey: key)
            memoryFallback.removeValue(forKey: key)
        } else {
            memoryFallback[key] = value
        }
    }

    /// Removes the value for `key` from both the suite and memory.
    private func storageRemove(_ key: String) {
        storeLock.lock()
        defer { storeLock.unlock() }

        storage.removeObject(forKey: key)
        memoryFallback.removeValue(forKey: key)
    }
}
