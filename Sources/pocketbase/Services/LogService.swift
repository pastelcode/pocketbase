import Foundation

/// Service for reading application logs and log statistics.
///
/// Wraps the `/api/logs` endpoints.
open class LogService: BaseService, @unchecked Sendable {
    /// Returns a paginated list of logs.
    ///
    /// - Parameter page: The page number, starting at `1`.
    /// - Parameter perPage: The number of logs per page.
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The paginated log entries.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getList(page: Int = 1, perPage: Int = 30, options: SendOptions? = nil) async throws -> ListResult<LogModel> {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        opt.applyDefaultQuery([
            "page": AnyCodable(page),
            "perPage": AnyCodable(perPage)
        ])
        return try await client.send(path: "/api/logs", options: opt)
    }

    /// Returns a single log entry by its identifier.
    ///
    /// - Parameter id: The log identifier.
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The requested log entry.
    /// - Throws: A ``ClientResponseError`` with status `404` when `id` is empty, or when the request fails.
    open func getOne(id: String, options: SendOptions? = nil) async throws -> LogModel {
        if id.isEmpty {
            throw ClientResponseError(
                url: client.buildURL(path: "/api/logs/"),
                status: 404,
                response: [
                    "code": AnyCodable(404),
                    "message": AnyCodable("Missing required log id."),
                    "data": AnyCodable([String: AnyCodable]())
                ]
            )
        }

        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        let encodedId = id.encodeURIComponent()
        return try await client.send(path: "/api/logs/\(encodedId)", options: opt)
    }

    /// Returns hourly log statistics.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The hourly statistics entries.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getStats(options: SendOptions? = nil) async throws -> [HourlyStats] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        return try await client.send(path: "/api/logs/stats", options: opt)
    }
}
