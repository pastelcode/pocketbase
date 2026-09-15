import Foundation

open class LogService: BaseService, @unchecked Sendable {
    open func getList(page: Int = 1, perPage: Int = 30, options: SendOptions? = nil) async throws -> ListResult<LogModel> {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        opt.query["page"] = AnyCodable(page)
        opt.query["perPage"] = AnyCodable(perPage)
        return try await client.send(path: "/api/logs", options: opt)
    }

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
        opt.method = "GET"
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await client.send(path: "/api/logs/\(encodedId)", options: opt)
    }

    open func getStats(options: SendOptions? = nil) async throws -> [HourlyStats] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/logs/stats", options: opt)
    }
}
