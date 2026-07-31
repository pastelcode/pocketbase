import Foundation

open class SQLService: BaseService, @unchecked Sendable {
    open func run(query: String, options: SendOptions? = nil) async throws -> SQLResult {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["query": AnyCodable(query)])
        return try await client.send(path: "/api/sql", options: opt)
    }
}
