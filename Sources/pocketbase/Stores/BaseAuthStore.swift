import Foundation

/// An in-memory store for the current auth token and record.
///
/// ``BaseAuthStore`` is the base class for the auth stores used by
/// ``PocketBase``. It keeps the authentication state in memory and notifies
/// observers registered through ``onChange(fireImmediately:callback:)`` after
/// every change. Subclasses that persist the state can additionally route their
/// updates through ``triggerChange()``. Use ``LocalAuthStore`` or
/// ``AsyncAuthStore`` when the state must survive app restarts.
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

    /// Checks whether the store has a usable, unexpired token.
    ///
    /// Equivalent to negating ``JWTUtils/isTokenExpired(_:expirationThreshold:)``:
    /// the token must be a well-formed three-segment JWT with a numeric `exp`
    /// claim in the future. Malformed tokens and tokens without an `exp` claim
    /// are considered invalid.
    ///
    /// - Note: This is stricter than the JavaScript SDK, which treats a missing
    ///   or falsy `exp` as "never expires". Failing closed is safer because the
    ///   token signature is not verified.
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

    /// Saves the provided new token and record data in the auth store and
    /// notifies the registered observers.
    ///
    /// - Parameters:
    ///   - token: The new authentication token.
    ///   - record: The new authentication record. Defaults to `nil`.
    open func save(token: String, record: RecordModel? = nil) {
        lock.lock()
        self._token = token
        self._record = record
        lock.unlock()

        triggerChange()
    }

    /// Removes the stored token and record data from the auth store and
    /// notifies the registered observers.
    ///
    /// Unlike ``save(token:record:)`` this does not go through the overridable
    /// save method, so subclasses can implement it with a single storage
    /// operation.
    open func clear() {
        lock.lock()
        self._token = ""
        self._record = nil
        lock.unlock()

        triggerChange()
    }

    /// Notifies all registered observers with the current token and record.
    ///
    /// The values are read through the ``token`` and ``record`` getters, so
    /// live stores (such as ``LocalAuthStore``) report the freshly persisted
    /// state. Override this method in a subclass to emit change events to
    /// observers without performing a full ``save(token:record:)``; the
    /// override should call `super` to keep invoking the registered callbacks.
    open func triggerChange() {
        lock.lock()
        let callbacks = Array(_onChangeCallbacks.values)
        lock.unlock()

        let token = self.token
        let record = self.record
        for callback in callbacks {
            callback(token, record)
        }
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

    /// Exports the current store state as a `Set-Cookie` header value.
    ///
    /// - Parameters:
    ///   - options: Optional cookie attributes merged over the defaults
    ///     (`path: "/"`, `httpOnly`, `secure` and `sameSite: .strict`).
    ///   - key: The cookie name. Defaults to `"pb_auth"`.
    /// - Returns: The serialized cookie string.
    /// - Throws: A ``CookieSerializeError`` when the cookie cannot be
    ///   serialized.
    open func exportToCookie(options: CookieSerializeOptions? = nil, key: String = "pb_auth") throws -> String {
        var defaultOptions = CookieSerializeOptions(
            path: "/",
            httpOnly: true,
            secure: true,
            sameSite: .strict
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
            if let encode = userOpt.encode { defaultOptions.encode = encode }
            if let maxAge = userOpt.maxAge { defaultOptions.maxAge = maxAge }
            if let domain = userOpt.domain { defaultOptions.domain = domain }
            if let path = userOpt.path { defaultOptions.path = path }
            if let expires = userOpt.expires { defaultOptions.expires = expires }
            if let httpOnly = userOpt.httpOnly { defaultOptions.httpOnly = httpOnly }
            if let secure = userOpt.secure { defaultOptions.secure = secure }
            if let priority = userOpt.priority { defaultOptions.priority = priority }
            if userOpt.sameSite != .unspecified { defaultOptions.sameSite = userOpt.sameSite }
        }

        let encoder = JSONEncoder()
        var rawDict: [String: AnyCodable] = [
            "token": AnyCodable(token),
            "record": AnyCodable(record)
        ]

        guard let payloadData = try? encoder.encode(rawDict),
              let jsonStr = String(data: payloadData, encoding: .utf8) else {
            return try CookieUtils.cookieSerialize(name: key, val: "", options: defaultOptions)
        }

        var result = try CookieUtils.cookieSerialize(name: key, val: jsonStr, options: defaultOptions)

        if let record = record, result.utf8.count > 4096 {
            // Strip down the record data to the bare minimum required to
            // identify the auth record (same fields as the reference SDK).
            var stripped: [String: AnyCodable] = ["id": AnyCodable(record.id)]
            if let email = record["email"] {
                stripped["email"] = email
            }
            if !record.collectionId.isEmpty {
                stripped["collectionId"] = AnyCodable(record.collectionId)
            }
            if !record.collectionName.isEmpty {
                stripped["collectionName"] = AnyCodable(record.collectionName)
            }
            if let verified = record["verified"] {
                stripped["verified"] = verified
            }

            rawDict["record"] = AnyCodable(stripped)
            if let payloadData2 = try? encoder.encode(rawDict),
               let jsonStr2 = String(data: payloadData2, encoding: .utf8) {
                result = try CookieUtils.cookieSerialize(name: key, val: jsonStr2, options: defaultOptions)
            }
        }

        return result
    }

    /// Register a callback function that will be called on store change.
    ///
    /// - Parameters:
    ///   - fireImmediately: When `true`, invokes `callback` right after
    ///     registration with the current state. Defaults to `false`.
    ///   - callback: Invoked with the token and record on every change.
    /// - Returns: A closure that unsubscribes the callback when called.
    open func onChange(fireImmediately: Bool = false, callback: @escaping (String, RecordModel?) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.lock()
        _onChangeCallbacks[id] = callback
        lock.unlock()

        if fireImmediately {
            callback(token, record)
        }

        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self._onChangeCallbacks.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}
