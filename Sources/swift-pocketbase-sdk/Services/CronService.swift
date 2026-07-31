import Foundation

open class CronService: BaseService, @unchecked Sendable {
    open func getFullList(options: SendOptions? = nil) async throws -> [CronJob] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/crons", options: opt)
    }

    open func run(jobId: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let encoded = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        let _: Data = try await client.sendRaw(path: "/api/crons/\(encoded)", options: opt)
        return true
    }
}
