import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

open class PocketBase: @unchecked Sendable {
    open var baseURL: String
    open var lang: String
    open var authStore: BaseAuthStore

    public private(set) var collections: CollectionService!
    public private(set) var files: FileService!
    public private(set) var logs: LogService!
    public private(set) var settings: SettingsService!
    public private(set) var realtime: RealtimeService!
    public private(set) var health: HealthService!
    public private(set) var backups: BackupService!
    public private(set) var crons: CronService!
    public private(set) var sql: SQLService!

    open var beforeSend: (@Sendable (String, SendOptions) async throws -> (url: String, options: SendOptions))?
    open var afterSend: (@Sendable (HTTPURLResponse, Data, SendOptions) async throws -> Data)?

    private let lock = NSRecursiveLock()
    private var recordServices: [String: Any] = [:]
    private var enableAutoCancellation: Bool = true
    private var cancelHandles: [String: CancellationHandle] = [:]
    private var resetAutoRefreshHandler: (@Sendable () -> Void)?

    public init(baseURL: String = "/", authStore: BaseAuthStore? = nil, lang: String = "en-US") {
        self.baseURL = baseURL
        self.lang = lang
        self.authStore = authStore ?? LocalAuthStore()

        // Initialize Services
        self.collections = CollectionService(self)
        self.files = FileService(self)
        self.logs = LogService(self)
        self.settings = SettingsService(self)
        self.realtime = RealtimeService(self)
        self.health = HealthService(self)
        self.backups = BackupService(self)
        self.crons = CronService(self)
        self.sql = SQLService(self)
    }

    open var admins: RecordService<RecordModel> {
        return collection("_superusers")
    }

    open func collection(_ idOrName: String) -> RecordService<RecordModel> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = recordServices[idOrName] as? RecordService<RecordModel> {
            return existing
        }

        let service = RecordService<RecordModel>(self, collectionIdOrName: idOrName)
        recordServices[idOrName] = service
        return service
    }

    open func collection<M: Codable & Sendable>(_ idOrName: String) -> RecordService<M> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = recordServices[idOrName] as? RecordService<M> {
            return existing
        }

        let service = RecordService<M>(self, collectionIdOrName: idOrName)
        recordServices[idOrName] = service
        return service
    }

    open func createBatch() -> BatchService {
        return BatchService(self)
    }

    @discardableResult
    open func autoCancellation(_ enable: Bool) -> PocketBase {
        lock.lock()
        self.enableAutoCancellation = enable
        lock.unlock()
        return self
    }

    /// Cancels a pending request by its cancellation key.
    ///
    /// Requests are registered under `SendOptions.requestKey`, or, when it is
    /// not set, under `method + path`, matching the reference JS SDK.
    @discardableResult
    open func cancelRequest(_ requestKey: String) -> PocketBase {
        lock.lock()
        let handle = cancelHandles.removeValue(forKey: requestKey)
        lock.unlock()

        handle?.cancel()
        return self
    }

    /// Cancels all pending cancellable requests.
    @discardableResult
    open func cancelAllRequests() -> PocketBase {
        lock.lock()
        let handles = Array(cancelHandles.values)
        cancelHandles.removeAll()
        lock.unlock()

        for handle in handles {
            handle.cancel()
        }
        return self
    }

    /// Number of requests currently registered for auto-cancellation.
    /// Internal so tests can assert that the registry is cleaned up.
    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelHandles.count
    }

    func setAutoRefreshResetHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.resetAutoRefreshHandler = handler
        lock.unlock()
    }

    func resetAutoRefreshHook() {
        lock.lock()
        let handler = self.resetAutoRefreshHandler
        self.resetAutoRefreshHandler = nil
        lock.unlock()

        handler?()
    }

    open func filter(_ raw: String, params: [String: Any]? = nil) -> String {
        guard let params = params, !params.isEmpty else {
            return raw
        }

        var result = raw
        for (key, val) in params {
            let placeholder = "{:\(key)}"
            guard result.contains(placeholder) else { continue }

            let formattedVal: String
            if let boolVal = val as? Bool {
                formattedVal = String(boolVal)
            } else if let intVal = val as? Int {
                formattedVal = String(intVal)
            } else if let doubleVal = val as? Double {
                formattedVal = String(doubleVal)
            } else if let stringVal = val as? String {
                let escaped = stringVal.replacingOccurrences(of: "'", with: "\\'")
                formattedVal = "'\(escaped)'"
            } else if let dateVal = val as? Date {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let dateStr = formatter.string(from: dateVal)
                formattedVal = "'\(dateStr)'"
            } else if let anyCodable = val as? AnyCodable {
                formattedVal = formatAnyCodableForFilter(anyCodable)
            } else if val is NSNull {
                formattedVal = "null"
            } else {
                let anyCodable = AnyCodable(val)
                formattedVal = formatAnyCodableForFilter(anyCodable)
            }

            result = result.replacingOccurrences(of: placeholder, with: formattedVal)
        }

        return result
    }

    private func formatAnyCodableForFilter(_ anyCodable: AnyCodable) -> String {
        switch anyCodable.value {
        case .null:
            return "null"
        case .bool(let b):
            return String(b)
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        case .array, .dictionary:
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(anyCodable),
               let jsonStr = String(data: data, encoding: .utf8) {
                let escaped = jsonStr.replacingOccurrences(of: "'", with: "\\'")
                return "'\(escaped)'"
            }
            return "''"
        }
    }

    @available(*, deprecated, message: "Use files.getURL instead.")
    open func getFileUrl(record: RecordModel, filename: String, queryParams: [String: AnyCodable] = [:]) -> String {
        return files.getURL(record: record, filename: filename, queryParams: queryParams)
    }

    open func buildURL(path: String) -> String {
        var url = baseURL
        if path.isEmpty {
            return url
        }

        if !url.hasSuffix("/") {
            url += "/"
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return url + cleanPath
    }

    open func send<T: Decodable & Sendable>(path: String, options: SendOptions) async throws -> T {
        let rawData = try await sendRaw(path: path, options: options)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: rawData)
        } catch {
            throw ClientResponseError(
                url: buildURL(path: path),
                status: 0,
                originalError: error,
                message: "Failed to decode response: \(error.localizedDescription)"
            )
        }
    }

    open func sendRaw(path: String, options: SendOptions) async throws -> Data {
        var initOptions = initSendOptions(path: path, options: options)
        let cancellationKey = autoCancellationKey(path: path, options: initOptions)
        var urlString = buildURL(path: path)

        if let before = beforeSend {
            let (newUrl, newOptions) = try await before(urlString, initOptions)
            urlString = newUrl
            initOptions = newOptions
        }

        if !initOptions.query.isEmpty {
            let queryString = serializeQueryParams(initOptions.query)
            if !queryString.isEmpty {
                urlString += (urlString.contains("?") ? "&" : "?") + queryString
            }
        }

        guard let url = URL(string: urlString) else {
            throw ClientResponseError(url: urlString, status: 0, message: "Invalid URL string: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = initOptions.method

        for (k, v) in initOptions.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if let body = initOptions.body {
            switch body {
            case .data(let data):
                request.httpBody = data
            case .json(let dict):
                request.httpBody = try? JSONEncoder().encode(dict)
            case .rawJson(let anyCodable):
                request.httpBody = try? JSONEncoder().encode(anyCodable)
            case .form(let formFields):
                let multipart = MultipartFormData(fields: formFields)
                request.httpBody = multipart.bodyData
                request.setValue(multipart.contentTypeHeader, forHTTPHeaderField: "Content-Type")
            }
        }

        let handle = beginRequest(key: cancellationKey)
        defer {
            endRequest(key: cancellationKey, handle: handle)
        }

        // Run the request in a cancellable task so both key-based cancellation
        // and the caller's task cancellation abort the in-flight operation.
        let requestTask = Task { () -> (Data, URLResponse) in
            if let customFetch = initOptions.fetch {
                return try await customFetch(request)
            }
            return try await URLSession.shared.data(for: request)
        }
        handle?.onCancel {
            requestTask.cancel()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
        } catch {
            if handle?.isCancelled == true || Self.isCancellationError(error) {
                throw ClientResponseError(
                    url: urlString,
                    status: 0,
                    isAbort: true,
                    originalError: error
                )
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientResponseError(url: urlString, status: 0, message: "Invalid server response")
        }

        var finalData = data
        if let after = afterSend {
            finalData = try await after(httpResponse, finalData, initOptions)
        }

        if httpResponse.statusCode >= 400 {
            var responseDict: [String: AnyCodable] = [:]
            if let jsonObj = try? JSONDecoder().decode([String: AnyCodable].self, from: finalData) {
                responseDict = jsonObj
            }
            throw ClientResponseError(
                url: httpResponse.url?.absoluteString ?? urlString,
                status: httpResponse.statusCode,
                response: responseDict
            )
        }

        return finalData
    }

    private func initSendOptions(path: String, options: SendOptions) -> SendOptions {
        var opt = options

        if getHeader(opt.headers, name: "Content-Type") == nil && opt.body != nil {
            if case .form = opt.body {
                // Skip setting json Content-Type for form body
            } else {
                opt.headers["Content-Type"] = "application/json"
            }
        }

        if getHeader(opt.headers, name: "Accept-Language") == nil {
            opt.headers["Accept-Language"] = lang
        }

        if !authStore.token.isEmpty && getHeader(opt.headers, name: "Authorization") == nil {
            opt.headers["Authorization"] = authStore.token
        }

        return opt
    }

    /// Resolves the cancellation key for a request, or `nil` when the request
    /// should not participate in auto-cancellation.
    ///
    /// Mirrors the JS SDK: the key is `requestKey`, or `method + path` when not
    /// set; `autoCancel == false` opts the request out.
    private func autoCancellationKey(path: String, options: SendOptions) -> String? {
        lock.lock()
        let enabled = enableAutoCancellation
        lock.unlock()

        guard enabled, options.autoCancel != false else {
            return nil
        }

        if let key = options.requestKey, !key.isEmpty {
            return key
        }

        let method = options.method.isEmpty ? "GET" : options.method
        return method + path
    }

    private func beginRequest(key: String?) -> CancellationHandle? {
        guard let key = key else {
            return nil
        }

        lock.lock()
        let previous = cancelHandles.removeValue(forKey: key)
        let handle = CancellationHandle()
        cancelHandles[key] = handle
        lock.unlock()

        // Cancel the superseded request outside the lock to avoid re-entrancy.
        previous?.cancel()
        return handle
    }

    private func endRequest(key: String?, handle: CancellationHandle?) {
        guard let key = key, let handle = handle else {
            return
        }

        lock.lock()
        if let current = cancelHandles[key], current === handle {
            cancelHandles.removeValue(forKey: key)
        }
        lock.unlock()

        handle.clear()
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    private func getHeader(_ headers: [String: String], name: String) -> String? {
        let lowerName = name.lowercased()
        for (k, v) in headers {
            if k.lowercased() == lowerName {
                return v
            }
        }
        return nil
    }
}

public typealias Client = PocketBase
