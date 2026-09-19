import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The entry point for interacting with a PocketBase server.
///
/// A client owns the auth store and the service singletons (`collections`,
/// `files`, `logs`, and so on). All service calls funnel through
/// ``sendRaw(path:options:)``, which applies the ``beforeSend`` and
/// ``afterSend`` hooks, serializes the request, and maps error responses to
/// ``ClientResponseError``.
///
/// Requests participate in auto-cancellation by default: starting a request
/// cancels a pending one with the same `SendOptions.requestKey`, or the same
/// method and path. Use ``autoCancellation(_:)`` to disable this globally or
/// set `SendOptions.autoCancel` to `false` per request.
///
/// ```swift
/// let pb = PocketBase(baseURL: "https://example.com")
/// let posts: [RecordModel] = try await pb.collection("posts").getFullList()
/// ```
open class PocketBase: @unchecked Sendable {
    /// The base URL of the PocketBase server, e.g. `https://example.com`.
    open var baseURL: String
    /// The default `Accept-Language` header value applied to requests.
    open var lang: String
    /// The auth store used to persist authentication for this client.
    ///
    /// Defaults to a ``LocalAuthStore`` when none is provided at initialization.
    open var authStore: BaseAuthStore

    /// Service for managing collection schemas.
    public private(set) var collections: CollectionService!
    /// Service for managing files and building file URLs.
    public private(set) var files: FileService!
    /// Service for querying application logs.
    public private(set) var logs: LogService!
    /// Service for reading and updating application settings.
    public private(set) var settings: SettingsService!
    /// Service for realtime subscriptions.
    public private(set) var realtime: RealtimeService!
    /// Service for server health checks.
    public private(set) var health: HealthService!
    /// Service for managing backups.
    public private(set) var backups: BackupService!
    /// Service for managing cron jobs.
    public private(set) var crons: CronService!
    /// Service for executing raw SQL statements.
    public private(set) var sql: SQLService!

    /// An optional hook invoked before each request is sent.
    ///
    /// Receives the resolved URL and ``SendOptions`` and returns a possibly
    /// modified pair. Useful for injecting headers or refreshing an expired
    /// token before the request goes out.
    ///
    /// - Note: The hook must return both the URL and the options. The
    ///   deprecated options-only return shape from the reference SDK is not
    ///   supported.
    open var beforeSend: (@Sendable (String, SendOptions) async throws -> (url: String, options: SendOptions))?
    /// An optional hook invoked after a response is received.
    ///
    /// Receives the raw `HTTPURLResponse` and body data together with the
    /// ``SendOptions`` used for the request, and returns the data that
    /// continues through the pipeline. Called before error statuses are
    /// converted into ``ClientResponseError``.
    open var afterSend: (@Sendable (HTTPURLResponse, Data, SendOptions) async throws -> Data)?

    private let lock = NSRecursiveLock()
    private var recordServices: [String: Any] = [:]
    private var enableAutoCancellation: Bool = true
    private var cancelHandles: [String: CancellationHandle] = [:]
    private var resetAutoRefreshHandler: (@Sendable () -> Void)?

    /// Creates a client for the given PocketBase server.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL of the server. Defaults to `"/"`.
    ///   - authStore: The store used to persist authentication. Pass `nil` to
    ///     use a default ``LocalAuthStore``.
    ///   - lang: The default `Accept-Language` header value. Defaults to
    ///     `"en-US"`.
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

    /// Convenience accessor for the built-in `_superusers` collection.
    open var admins: RecordService<RecordModel> {
        return collection("_superusers")
    }

    /// Returns the record service for the collection with the given id or name.
    ///
    /// Services are cached per collection, so repeated calls with the same
    /// argument return the same instance.
    ///
    /// - Parameter idOrName: The collection id or name.
    /// - Returns: A record service bound to the collection.
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

    /// Returns the record service for the collection with the given id or name,
    /// decoding records as `M`.
    ///
    /// Services are cached per collection, so repeated calls with the same
    /// argument return the same instance.
    ///
    /// - Parameter idOrName: The collection id or name.
    /// - Returns: A typed record service bound to the collection.
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

    /// Creates a batch service for sending multiple requests in one call.
    ///
    /// - Returns: A fresh ``BatchService``.
    open func createBatch() -> BatchService {
        return BatchService(self)
    }

    /// Enables or disables auto-cancellation globally.
    ///
    /// When enabled (the default), starting a request cancels a pending request
    /// registered under the same key.
    ///
    /// - Parameter enable: `true` to enable auto-cancellation, `false` to
    ///   disable it.
    /// - Returns: This client, for chaining.
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
    ///
    /// - Parameter requestKey: The key the request was registered under.
    /// - Returns: This client, for chaining.
    @discardableResult
    open func cancelRequest(_ requestKey: String) -> PocketBase {
        lock.lock()
        let handle = cancelHandles.removeValue(forKey: requestKey)
        lock.unlock()

        handle?.cancel()
        return self
    }

    /// Cancels all pending cancellable requests.
    ///
    /// - Returns: This client, for chaining.
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

    /// Replaces `{:name}` placeholders in a filter expression with formatted
    /// values.
    ///
    /// Values are converted by type: strings are quoted and escaped, booleans
    /// and numbers are inserted as-is, dates use the PocketBase ISO 8601
    /// format, `nil` becomes `null`, and arrays/dictionaries are JSON-encoded.
    /// Placeholders without a matching entry in `params` are left untouched.
    ///
    /// ```swift
    /// let filter = pb.filter("author = {:author}", params: ["author": "john"])
    /// ```
    ///
    /// - Parameters:
    ///   - raw: The filter expression containing `{:name}` placeholders.
    ///   - params: The placeholder values keyed by placeholder name.
    /// - Returns: The filter expression with the provided placeholders replaced.
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
        case .date(let d):
            return "'\(d.pocketBaseISO8601.replacingOccurrences(of: "T", with: " "))'"
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

    /// Builds the URL for a file stored in a record.
    ///
    /// - Parameters:
    ///   - record: The record that owns the file.
    ///   - filename: The stored filename.
    ///   - queryParams: Additional query parameters such as `thumb` or `token`.
    /// - Returns: The absolute file URL.
    /// - Important: Deprecated. Use ``FileService/getURL(record:filename:queryParams:)`` instead.
    @available(*, deprecated, message: "Use files.getURL instead.")
    open func getFileUrl(record: RecordModel, filename: String, queryParams: [String: AnyCodable] = [:]) -> String {
        return files.getURL(record: record, filename: filename, queryParams: queryParams)
    }

    /// Joins a path with the client's base URL.
    ///
    /// A single slash is inserted between the base URL and the path. An empty
    /// path returns the base URL unchanged.
    ///
    /// - Parameter path: The API path, with or without a leading slash.
    /// - Returns: The absolute URL string.
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

    /// Sends a request and decodes the JSON response into `T`.
    ///
    /// An empty response body (for example a `204 No Content`) is decoded as an
    /// empty JSON object, matching the reference SDK.
    ///
    /// - Parameters:
    ///   - path: The API path, relative to ``baseURL``.
    ///   - options: The request options.
    /// - Returns: The decoded response.
    /// - Throws: A ``ClientResponseError`` when the request fails or the
    ///   response cannot be decoded into `T`.
    open func send<T: Decodable & Sendable>(path: String, options: SendOptions) async throws -> T {
        let (rawData, finalURL) = try await sendRawResponse(path: path, options: options)
        // Match the reference SDK: an empty/unparsable body is treated as `{}`.
        let data = rawData.isEmpty ? Data("{}".utf8) : rawData
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientResponseError(
                url: finalURL.absoluteString,
                status: 0,
                originalError: error,
                message: "Failed to decode response: \(error.localizedDescription)"
            )
        }
    }

    /// Sends a request and returns the raw response body.
    ///
    /// This is the pipeline used by every service: it runs the ``beforeSend``
    /// and ``afterSend`` hooks, serializes query parameters and the body,
    /// registers the request for auto-cancellation, and maps HTTP error
    /// statuses to ``ClientResponseError``.
    ///
    /// Cancellation aborts the wrapping Swift `Task` and only that: a
    /// ``CustomFetch`` closure is not handed an `AbortSignal`, so a closure
    /// that ignores task cancellation keeps running. See ``CustomFetch``.
    ///
    /// - Parameters:
    ///   - path: The API path, relative to ``baseURL``.
    ///   - options: The request options.
    /// - Returns: The raw response body.
    /// - Throws: A ``ClientResponseError`` when the request fails or the server
    ///   responds with an error status.
    open func sendRaw(path: String, options: SendOptions) async throws -> Data {
        let (data, _) = try await sendRawResponse(path: path, options: options)
        return data
    }

    /// Sends a request and returns the raw response body together with the
    /// final response URL.
    ///
    /// The URL reflects the ``beforeSend`` result and includes the serialized
    /// query parameters, and follows any redirect performed by the transport.
    /// Both ``send(path:options:)`` and ``sendRaw(path:options:)`` route through
    /// this method, so it is the override point for customizing the send
    /// pipeline.
    ///
    /// The request is registered for auto-cancellation before ``beforeSend``
    /// runs, matching the reference SDK, so a suspended hook does not delay
    /// supersession and ``cancelRequest(_:)`` can interrupt a request whose
    /// hook is still running. Cancellation cancels the wrapping `Task` only;
    /// see ``CustomFetch`` for the limits that places on custom transports.
    ///
    /// - Parameters:
    ///   - path: The API path, relative to ``baseURL``.
    ///   - options: The request options.
    /// - Returns: The raw response body and the final response URL.
    /// - Throws: A ``ClientResponseError`` when the request fails or the server
    ///   responds with an error status.
    open func sendRawResponse(path: String, options: SendOptions) async throws -> (Data, URL) {
        var initOptions = initSendOptions(path: path, options: options)

        // Resolve the cancellation key from the pre-hook options and register
        // the request before `beforeSend` runs, matching the reference SDK
        // (`initSendOptions` registers synchronously). Doing this after the
        // hook would let a suspended `beforeSend` — such as the one installed
        // by ``AutoRefresh`` — delay supersession and make ``cancelRequest(_:)``
        // a no-op while the hook is in flight. The key deliberately stays the
        // pre-hook value: a superseding request has already cancelled this
        // handle, and the cancellation handle invokes its cancel block
        // immediately when it is registered after cancellation.
        let cancellationKey = autoCancellationKey(path: path, options: initOptions)
        let handle = beginRequest(key: cancellationKey)
        defer {
            endRequest(key: cancellationKey, handle: handle)
        }

        var urlString = buildURL(path: path)

        if let before = beforeSend {
            do {
                let (newUrl, newOptions) = try await before(urlString, initOptions)
                urlString = newUrl
                initOptions = newOptions
            } catch {
                throw ClientResponseError(wrapping: error, url: urlString)
            }
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
        request.httpMethod = initOptions.method ?? "GET"

        for (k, v) in initOptions.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        if let body = initOptions.body {
            do {
                switch body {
                case .data(let data):
                    request.httpBody = data
                case .json(let dict):
                    request.httpBody = try JSONEncoder().encode(dict)
                case .rawJson(let anyCodable):
                    request.httpBody = try JSONEncoder().encode(anyCodable)
                case .form(let formFields):
                    let multipart = MultipartFormData(fields: formFields)
                    request.httpBody = multipart.bodyData
                    request.setValue(multipart.contentTypeHeader, forHTTPHeaderField: "Content-Type")
                }
            } catch {
                throw ClientResponseError(
                    url: urlString,
                    status: 0,
                    originalError: error,
                    message: "Failed to encode request body: \(error.localizedDescription)"
                )
            }
        }

        // Run the request in a cancellable task so both key-based cancellation
        // and the caller's task cancellation abort the in-flight operation.
        // Capture by value: `initOptions` is still used below.
        let requestTask = Task { [request, initOptions] () -> (Data, URLResponse) in
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
            throw ClientResponseError(
                url: urlString,
                status: 0,
                isAbort: handle?.isCancelled == true,
                originalError: error
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientResponseError(url: urlString, status: 0, message: "Invalid server response")
        }

        var finalData = data
        if let after = afterSend {
            do {
                finalData = try await after(httpResponse, finalData, initOptions)
            } catch {
                throw ClientResponseError(
                    wrapping: error,
                    url: httpResponse.url?.absoluteString ?? urlString
                )
            }
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

        return (finalData, httpResponse.url ?? url)
    }

    private func initSendOptions(path: String, options: SendOptions) -> SendOptions {
        var opt = options

        if opt.method == nil {
            opt.method = "GET"
        }

        // Typed shorthands take precedence over an explicit `query` value,
        // matching the reference SDK's unknown-option normalization.
        opt.applyShorthandQuery()

        if getHeader(opt.headers, name: "Content-Type") == nil {
            if case .form = opt.body {
                // A multipart body sets its own Content-Type (with boundary).
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

        let method = options.method.flatMap { $0.isEmpty ? nil : $0 } ?? "GET"
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

/// An alias for ``PocketBase``.
public typealias Client = PocketBase
