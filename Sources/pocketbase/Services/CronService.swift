import Foundation

/// Service for listing and running scheduled cron jobs.
///
/// Wraps the `/api/crons` endpoints.
open class CronService: BaseService, @unchecked Sendable {
    /// Returns all registered cron jobs.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The registered cron jobs.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getFullList(options: SendOptions? = nil) async throws -> [CronJob] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/crons", options: opt)
    }

    /// Runs a cron job immediately.
    ///
    /// - Parameter jobId: The cron job identifier.
    /// - Parameter options: Additional send options. The `POST` method is applied by default.
    /// - Returns: `true` when the job is triggered.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func run(jobId: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        let _: Data = try await client.sendRaw(path: "/api/crons/\(encoded)", options: opt)
        return true
    }
}
