import Foundation

/// Service for building record file URLs and issuing file access tokens.
open class FileService: BaseService, @unchecked Sendable {
    /// Builds the URL of a record file.
    ///
    /// - Parameter record: The record that owns the file.
    /// - Parameter filename: The stored file name.
    /// - Parameter queryParams: Additional query parameters, such as `thumb` or `token`.
    /// - Returns: The file URL, or an empty string when required identifiers are missing.
    ///
    /// - Important: Deprecated. Use ``getURL(record:filename:queryParams:)`` instead.
    @available(*, deprecated, message: "Use getURL instead.")
    open func getUrl(record: RecordModel, filename: String, queryParams: [String: AnyCodable] = [:]) -> String {
        return getURL(record: record, filename: filename, queryParams: queryParams)
    }

    /// Builds the URL of a record file.
    ///
    /// The returned URL has the shape
    /// `{baseURL}/api/files/{collectionIdOrName}/{recordId}/{filename}`, with any
    /// query parameters appended.
    ///
    /// - Parameter record: The record that owns the file.
    /// - Parameter filename: The stored file name.
    /// - Parameter queryParams: Additional query parameters, such as `thumb` or `token`.
    ///   A `download` parameter explicitly set to `false` is omitted.
    /// - Returns: The file URL, or an empty string when the record id, collection, or filename is missing.
    open func getURL(record: RecordModel, filename: String, queryParams: [String: AnyCodable] = [:]) -> String {
        let col = record.collectionId.isEmpty ? record.collectionName : record.collectionId
        if filename.isEmpty || record.id.isEmpty || col.isEmpty {
            return ""
        }

        let encodedCol = col.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? col
        let encodedId = record.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? record.id
        let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename

        let path = "api/files/\(encodedCol)/\(encodedId)/\(encodedFilename)"
        var result = client.buildURL(path: path)

        var params = queryParams
        if let downloadVal = params["download"]?.value, case .bool(let b) = downloadVal, b == false {
            params.removeValue(forKey: "download")
        }

        let queryString = serializeQueryParams(params)
        if !queryString.isEmpty {
            result += (result.contains("?") ? "&" : "?") + queryString
        }

        return result
    }

    /// Requests a short-lived token that grants access to protected record files.
    ///
    /// Pass the token through the `token` query parameter of
    /// ``getURL(record:filename:queryParams:)``.
    ///
    /// - Parameter options: Additional send options. The `POST` method is applied by default.
    /// - Returns: The file access token.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getToken(options: SendOptions? = nil) async throws -> String {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let resp: [String: AnyCodable] = try await client.send(path: "/api/files/token", options: opt)
        return resp["token"]?.value.string ?? ""
    }
}
