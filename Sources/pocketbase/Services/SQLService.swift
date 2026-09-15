import Foundation

/// Service for executing raw SQL statements against the application database.
///
/// Wraps the `/api/sql` endpoint.
open class SQLService: BaseService, @unchecked Sendable {
    /// Executes a raw SQL statement.
    ///
    /// - Parameter query: The SQL statement to run.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: The execution result, including columns and rows for select statements.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func run(query: String, options: SendOptions? = nil) async throws -> SQLResult {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["query": AnyCodable(query)])
        return try await client.send(path: "/api/sql", options: opt)
    }
}
