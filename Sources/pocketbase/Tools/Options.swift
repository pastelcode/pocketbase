import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A custom request executor used in place of the default transport.
///
/// The closure receives the fully prepared request and returns the raw
/// response body together with its response. Use it to mock, intercept, or
/// re-route requests issued by ``PocketBase``.
public typealias CustomFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// A file payload for multipart form submissions.
///
/// Pass instances to the server through ``SendOptions`` form values.
public struct FileParam: Equatable, Sendable, Codable {
    /// The name reported to the server, including the file extension.
    public var filename: String
    /// The MIME type of the payload; defaults to `application/octet-stream`.
    public var mimeType: String
    /// The raw file bytes.
    public var data: Data

    /// Creates a file payload.
    ///
    /// - Parameter filename: The name reported to the server.
    /// - Parameter mimeType: The MIME type of the payload. Defaults to `application/octet-stream`.
    /// - Parameter data: The raw file bytes.
    public init(filename: String, mimeType: String = "application/octet-stream", data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Per-request configuration for ``PocketBase`` and its services.
///
/// `SendOptions` controls the HTTP method, headers, body, and query parameters
/// of a single request. The typed shorthands (`filter`, `sort`, `expand`,
/// `fields`, `skipTotal`) are folded into `query` before sending and override
/// values already present there; `batch` is consumed locally and never sent.
///
/// ```swift
/// var options = SendOptions()
/// options.filter = "status = 'active'"
/// options.sort = "-created"
/// options.query["perPage"] = 50
/// ```
public struct SendOptions: Sendable {
    /// The HTTP method for the request.
    ///
    /// `nil` means "not set": the service or the client applies
    /// its default (`GET` when nothing else applies).
    public var method: String?
    /// Additional HTTP headers merged into the request.
    public var headers: [String: String]
    /// The request body, if any.
    public var body: AnySendableBody?
    /// Query parameters appended to the request URL.
    ///
    /// Typed shorthands (`filter`, `sort`, `expand`, `fields`, `skipTotal`)
    /// take precedence over values stored here.
    public var query: [String: AnyCodable]

    /// Shorthand for the `filter` query parameter. Takes precedence over a
    /// value already present in `query`.
    public var filter: String?
    /// Shorthand for the `sort` query parameter.
    ///
    /// Takes precedence over a value already present in `query`.
    public var sort: String?
    /// Shorthand for the `expand` query parameter.
    ///
    /// Takes precedence over a value already present in `query`.
    public var expand: String?
    /// Shorthand for the `fields` query parameter.
    ///
    /// Takes precedence over a value already present in `query`.
    public var fields: String?
    /// Shorthand for the `skipTotal` query parameter.
    ///
    /// Takes precedence over a value already present in `query`.
    public var skipTotal: Bool?
    /// Number of records fetched per page by `getFullList`.
    ///
    /// Consumed locally only and never sent to the server. Defaults to `1000`.
    public var batch: Int?

    /// Explicit key used for auto-cancellation.
    ///
    /// When `nil`, the client derives a key from the request method and path.
    public var requestKey: String?
    /// Set to `false` to exclude this request from auto-cancellation.
    ///
    /// When `nil` (the default) the request participates in auto-cancellation
    /// normally. See `PocketBase.autoCancellation(_:)` for the global toggle.
    public var autoCancel: Bool?
    /// Custom fetch implementation used instead of the default transport.
    public var fetch: CustomFetch?
    /// Whether the request bypasses the auth auto-refresh hook.
    ///
    /// When `true`, the registered auto-refresh handler is skipped and the
    /// request is sent with the current auth state.
    public var autoRefresh: Bool?
    /// Seconds added to the token expiry check during auth auto-refresh.
    ///
    /// A token is refreshed when it expires within this many seconds.
    public var autoRefreshThreshold: Double?

    /// The body payload of a request.
    public enum AnySendableBody: Sendable {
        /// A raw byte body sent as-is.
        case data(Data)
        /// A JSON object encoded by the client.
        case json([String: AnyCodable])
        /// A pre-built JSON value encoded by the client.
        case rawJson(AnyCodable)
        /// A multipart form body assembled from the given fields.
        case form([String: FormValue])
    }

    /// A single multipart form field value.
    public enum FormValue: Sendable {
        /// A plain text field.
        case string(String)
        /// A single file field.
        case file(FileParam)
        /// A multiple-file field.
        case files([FileParam])
        /// A JSON-encoded field value.
        case json(AnyCodable)
    }

    /// Creates a set of request options.
    ///
    /// All parameters are optional; unset values fall back to the service or
    /// client defaults at send time.
    ///
    /// - Parameter method: The HTTP method, or `nil` to let the service pick one.
    /// - Parameter headers: Additional HTTP headers.
    /// - Parameter body: The request body, if any.
    /// - Parameter query: Query parameters, combined with the typed shorthands.
    /// - Parameter filter: Shorthand for the `filter` query parameter.
    /// - Parameter sort: Shorthand for the `sort` query parameter.
    /// - Parameter expand: Shorthand for the `expand` query parameter.
    /// - Parameter fields: Shorthand for the `fields` query parameter.
    /// - Parameter skipTotal: Shorthand for the `skipTotal` query parameter.
    /// - Parameter batch: Local page size used by `getFullList`.
    /// - Parameter requestKey: Auto-cancellation key for the request.
    /// - Parameter autoCancel: Pass `false` to exclude the request from auto-cancellation.
    /// - Parameter fetch: Custom fetch used instead of the default transport.
    /// - Parameter autoRefresh: Pass `true` to bypass the auto-refresh hook.
    /// - Parameter autoRefreshThreshold: Token expiry threshold in seconds for auto-refresh.
    public init(
        method: String? = nil,
        headers: [String: String] = [:],
        body: AnySendableBody? = nil,
        query: [String: AnyCodable] = [:],
        filter: String? = nil,
        sort: String? = nil,
        expand: String? = nil,
        fields: String? = nil,
        skipTotal: Bool? = nil,
        batch: Int? = nil,
        requestKey: String? = nil,
        autoCancel: Bool? = nil,
        fetch: CustomFetch? = nil,
        autoRefresh: Bool? = nil,
        autoRefreshThreshold: Double? = nil
    ) {
        self.method = method
        self.headers = headers
        self.body = body
        self.query = query
        self.filter = filter
        self.sort = sort
        self.expand = expand
        self.fields = fields
        self.skipTotal = skipTotal
        self.batch = batch
        self.requestKey = requestKey
        self.autoCancel = autoCancel
        self.fetch = fetch
        self.autoRefresh = autoRefresh
        self.autoRefreshThreshold = autoRefreshThreshold
    }
}

extension SendOptions {
    /// Applies a default method unless the caller already set one.
    mutating func applyDefaultMethod(_ value: String) {
        if method == nil {
            method = value
        }
    }

    /// Applies default body params unless the caller already set a body.
    mutating func applyDefaultBody(_ value: AnySendableBody?) {
        if body == nil {
            body = value
        }
    }

    /// Applies default query parameters without overwriting caller values.
    mutating func applyDefaultQuery(_ defaults: [String: AnyCodable]) {
        for (key, value) in defaults where query[key] == nil {
            query[key] = value
        }
    }

    /// Moves the typed shorthands into `query`, taking precedence over values
    /// already present there (matching the reference SDK's unknown-option
    /// normalization).
    mutating func applyShorthandQuery() {
        if let filter = filter {
            query["filter"] = AnyCodable(filter)
        }
        if let sort = sort {
            query["sort"] = AnyCodable(sort)
        }
        if let expand = expand {
            query["expand"] = AnyCodable(expand)
        }
        if let fields = fields {
            query["fields"] = AnyCodable(fields)
        }
        if let skipTotal = skipTotal {
            query["skipTotal"] = AnyCodable(skipTotal)
        }
    }
}

extension String {
    /// Percent-encodes the receiver exactly like JavaScript's `encodeURIComponent`:
    /// alphanumerics and `-_.!~*'()` are left as-is, everything else is
    /// percent-encoded (UTF-8 bytes for non-ASCII characters).
    public func encodeURIComponent() -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// Serializes query parameters into a URL-encoded query string.
///
/// Keys are sorted for deterministic output, array values produce one
/// `key=value` pair per element, `null` values are omitted, and dates are
/// formatted as `YYYY-MM-DD HH:MM:SS.sssZ` before percent-encoding.
///
/// - Parameter params: The parameters to serialize.
/// - Returns: A percent-encoded query string without the leading `?`.
public func serializeQueryParams(_ params: [String: AnyCodable]) -> String {
    var result: [String] = []

    let sortedKeys = params.keys.sorted()

    for key in sortedKeys {
        guard let value = params[key] else { continue }
        let encodedKey = key.encodeURIComponent()

        let arrValues: [AnyCodable]
        if case .array(let arr) = value.value {
            arrValues = arr
        } else {
            arrValues = [value]
        }

        for v in arrValues {
            if let prepared = prepareQueryParamValue(v) {
                result.append("\(encodedKey)=\(prepared)")
            }
        }
    }

    return result.joined(separator: "&")
}

/// Converts a single query value to its wire representation.
///
/// Returns `nil` for `null` values, which omits the pair entirely. Dates use
/// the PocketBase query format `YYYY-MM-DD HH:MM:SS.sssZ`; arrays and
/// dictionaries are JSON-encoded.
///
/// - Parameter val: The value to convert.
/// - Returns: The encoded value, or `nil` when the pair should be skipped.
private func prepareQueryParamValue(_ val: AnyCodable) -> String? {
    switch val.value {
    case .null:
        return nil
    case .bool(let b):
        return String(b)
    case .int(let i):
        return String(i)
    case .double(let d):
        return String(d)
    case .string(let s):
        return s.encodeURIComponent()
    case .date(let d):
        return d.pocketBaseISO8601
            .replacingOccurrences(of: "T", with: " ")
            .encodeURIComponent()
    case .array, .dictionary:
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(val),
           let jsonStr = String(data: data, encoding: .utf8) {
            return jsonStr.encodeURIComponent()
        }
        return nil
    }
}
