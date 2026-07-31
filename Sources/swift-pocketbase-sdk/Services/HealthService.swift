import Foundation

open class HealthService: BaseService, @unchecked Sendable {
    open func check(options: SendOptions? = nil) async throws -> HealthCheckResponse {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/health", options: opt)
    }
}
