import Foundation

/// Service for checking the health of the PocketBase server.
///
/// Wraps the `/api/health` endpoint.
open class HealthService: BaseService, @unchecked Sendable {
    /// Performs a health check against the server.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The health check response, including server code and message.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func check(options: SendOptions? = nil) async throws -> HealthCheckResponse {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/health", options: opt)
    }
}
