import Foundation

open class FileService: BaseService, @unchecked Sendable {
    @available(*, deprecated, message: "Use getURL instead.")
    open func getUrl(record: RecordModel, filename: String, queryParams: [String: AnyCodable] = [:]) -> String {
        return getURL(record: record, filename: filename, queryParams: queryParams)
    }

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

    open func getToken(options: SendOptions? = nil) async throws -> String {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let resp: [String: AnyCodable] = try await client.send(path: "/api/files/token", options: opt)
        return resp["token"]?.value.string ?? ""
    }
}
