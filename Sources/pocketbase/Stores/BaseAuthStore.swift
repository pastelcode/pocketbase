import Foundation

/// An in-memory store for the current auth token and record.
///
/// ``BaseAuthStore`` is the base class for the auth stores used by
/// ``PocketBase``. It keeps the authentication state in memory and notifies
/// observers registered through ``onChange(fireImmediately:callback:)`` after
/// every change. Use ``LocalAuthStore`` or ``AsyncAuthStore`` when the state
/// must survive app restarts.
open class BaseAuthStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private var _token: String = ""
    private var _record: RecordModel? = nil
    private var _onChangeCallbacks: [UUID: (String, RecordModel?) -> Void] = [:]

    /// Creates a store with the given initial token and record.
    ///
    /// - Parameters:
    ///   - token: The initial authentication token. Defaults to an empty string.
    ///   - record: The initial authentication record. Defaults to `nil`.
    public init(token: String = "", record: RecordModel? = nil) {
        self._token = token
        self._record = record
    }

    /// Retrieves the stored token (if any).
    open var token: String {
        lock.lock()
        defer { lock.unlock() }
        return _token
    }

    /// Retrieves the stored record model data (if any).
    open var record: RecordModel? {
        lock.lock()
        defer { lock.unlock() }
        return _record
    }

    /// Alias for record.
    @available(*, deprecated, message: "Use record instead.")
    open var model: RecordModel? {
        return record
    }

    /// Loosely checks if the store has valid token (existing and unexpired exp claim).
    open var isValid: Bool {
        return !JWTUtils.isTokenExpired(token)
    }

    /// Loosely checks whether the currently loaded store state is for superuser.
    open var isSuperuser: Bool {
        let payload = JWTUtils.getTokenPayload(token)
        let typeStr = payload["type"]?.value.string
        guard typeStr == "auth" else { return false }

        let recColName = record?.collectionName
        if recColName == "_superusers" {
            return true
        }

        if (recColName == nil || recColName?.isEmpty == true) {
            let colId = payload["collectionId"]?.value.string
            if colId == "pbc_3142635823" {
                return true
            }
        }

        return false
    }

    /// A deprecated alias for ``isSuperuser``.
    @available(*, deprecated, message: "Use isSuperuser instead.")
    open var isAdmin: Bool {
        return isSuperuser
    }

    /// A deprecated check for non-superuser auth records.
    ///
    /// - Important: Use `!isSuperuser` instead.
    @available(*, deprecated, message: "Use !isSuperuser instead.")
    open var isAuthRecord: Bool {
        let payload = JWTUtils.getTokenPayload(token)
        return payload["type"]?.value.string == "auth" && !isSuperuser
    }

    /// Saves the provided new token and record data in the auth store.
    open func save(token: String, record: RecordModel? = nil) {
        lock.lock()
        self._token = token
        self._record = record
        let callbacks = Array(_onChangeCallbacks.values)
        lock.unlock()

        for callback in callbacks {
            callback(token, record)
        }
    }

    /// Removes the stored token and record data from the auth store.
    open func clear() {
        save(token: "", record: nil)
    }

    /// Parses the provided cookie string and updates the store state.
    open func loadFromCookie(_ cookie: String, key: String = "pb_auth") {
        let parsedCookies = CookieUtils.cookieParse(cookie)
        guard let rawData = parsedCookies[key], !rawData.isEmpty,
              let data = rawData.data(using: .utf8) else {
            save(token: "", record: nil)
            return
        }

        let decoder = JSONDecoder()
        if let jsonDict = try? decoder.decode([String: AnyCodable].self, from: data) {
            let tokenStr = jsonDict["token"]?.value.string ?? ""
            var recordModel: RecordModel? = nil
            if let recVal = jsonDict["record"] ?? jsonDict["model"] {
                if let recData = try? JSONEncoder().encode(recVal) {
                    recordModel = try? decoder.decode(RecordModel.self, from: recData)
                }
            }
            save(token: tokenStr, record: recordModel)
        } else {
            save(token: "", record: nil)
        }
    }

    /// Exports the current store state as cookie string.
    open func exportToCookie(options: CookieSerializeOptions? = nil, key: String = "pb_auth") -> String {
        var defaultOptions = CookieSerializeOptions(
            path: "/",
            httpOnly: true,
            secure: true,
            sameSite: "Strict"
        )

        let payload = JWTUtils.getTokenPayload(token)
        if let expVal = payload["exp"] {
            let expDouble: Double?
            switch expVal.value {
            case .int(let i): expDouble = Double(i)
            case .double(let d): expDouble = d
            default: expDouble = nil
            }
            if let exp = expDouble {
                defaultOptions.expires = Date(timeIntervalSince1970: exp)
            } else {
                defaultOptions.expires = Date(timeIntervalSince1970: 0)
            }
        } else {
            defaultOptions.expires = Date(timeIntervalSince1970: 0)
        }

        // Merge options
        if let userOpt = options {
            if let maxAge = userOpt.maxAge { defaultOptions.maxAge = maxAge }
            if let domain = userOpt.domain { defaultOptions.domain = domain }
            if let path = userOpt.path { defaultOptions.path = path }
            if let expires = userOpt.expires { defaultOptions.expires = expires }
            if let httpOnly = userOpt.httpOnly { defaultOptions.httpOnly = httpOnly }
            if let secure = userOpt.secure { defaultOptions.secure = secure }
            if let priority = userOpt.priority { defaultOptions.priority = priority }
            if let sameSite = userOpt.sameSite { defaultOptions.sameSite = sameSite }
        }

        let encoder = JSONEncoder()
        var exportRecord: RecordModel? = record

        var rawDict: [String: AnyCodable] = [
            "token": AnyCodable(token),
            "record": AnyCodable(exportRecord)
        ]

        guard let payloadData = try? encoder.encode(rawDict),
              let jsonStr = String(data: payloadData, encoding: .utf8) else {
            return CookieUtils.cookieSerialize(name: key, val: "", options: defaultOptions)
        }

        var result = CookieUtils.cookieSerialize(name: key, val: jsonStr, options: defaultOptions)

        if exportRecord != nil && result.utf8.count > 4096 {
            // Strip down record model data to bare minimum
            if var rec = exportRecord {
                var strippedFields: [String: AnyCodable] = [:]
                let extraProps = ["collectionId", "collectionName", "verified"]
                for prop in extraProps {
                    if let val = rec[prop] {
                        strippedFields[prop] = val
                    }
                }
                rec.rawFields = strippedFields
                exportRecord = rec
            }

            rawDict["record"] = AnyCodable(exportRecord)
            if let payloadData2 = try? encoder.encode(rawDict),
               let jsonStr2 = String(data: payloadData2, encoding: .utf8) {
                result = CookieUtils.cookieSerialize(name: key, val: jsonStr2, options: defaultOptions)
            }
        }

        return result
    }

    /// Register a callback function that will be called on store change.
    open func onChange(fireImmediately: Bool = false, callback: @escaping (String, RecordModel?) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.lock()
        _onChangeCallbacks[id] = callback
        let currentToken = _token
        let currentRecord = _record
        lock.unlock()

        if fireImmediately {
            callback(currentToken, currentRecord)
        }

        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self._onChangeCallbacks.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}
