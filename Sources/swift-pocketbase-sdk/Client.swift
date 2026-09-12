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

    @discardableResult
    open func cancelRequest(_ requestKey: String) -> PocketBase {
        return self
    }

    @discardableResult
    open func cancelAllRequests() -> PocketBase {
        return self
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

        let data: Data
        let response: URLResponse

        if let customFetch = initOptions.fetch {
            (data, response) = try await customFetch(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
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
