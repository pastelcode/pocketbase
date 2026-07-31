import Foundation

open class CrudService<M: Codable & Sendable>: BaseService, @unchecked Sendable {
    open var baseCrudPath: String {
        fatalError("baseCrudPath must be overridden by subclass")
    }

    open func getFullList<T: Codable & Sendable>(batch: Int = 1000, options: SendOptions? = nil) async throws -> [T] {
        var opt = options ?? SendOptions()
        opt.query["skipTotal"] = AnyCodable(1)

        var result: [T] = []
        var page = 1

        while true {
            let list: ListResult<T> = try await getList(page: page, perPage: batch, options: opt)
            result.append(contentsOf: list.items)
            if list.items.count < list.perPage {
                break
            }
            page += 1
        }

        return result
    }

    open func getList<T: Codable & Sendable>(page: Int = 1, perPage: Int = 30, options: SendOptions? = nil) async throws -> ListResult<T> {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        opt.query["page"] = AnyCodable(page)
        opt.query["perPage"] = AnyCodable(perPage)

        return try await client.send(path: baseCrudPath, options: opt)
    }

    open func getFirstListItem<T: Codable & Sendable>(filter: String, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        if opt.requestKey == nil {
            opt.requestKey = "one_by_filter_\(baseCrudPath)_\(filter)"
        }
        opt.query["filter"] = AnyCodable(filter)
        opt.query["skipTotal"] = AnyCodable(1)

        let list: ListResult<T> = try await getList(page: 1, perPage: 1, options: opt)
        guard let first = list.items.first else {
            throw ClientResponseError(
                status: 404,
                response: [
                    "code": AnyCodable(404),
                    "message": AnyCodable("The requested resource wasn't found."),
                    "data": AnyCodable([String: AnyCodable]())
                ]
            )
        }
        return first
    }

    open func getOne<T: Codable & Sendable>(id: String, options: SendOptions? = nil) async throws -> T {
        if id.isEmpty {
            throw ClientResponseError(
                url: client.buildURL(path: "\(baseCrudPath)/"),
                status: 404,
                response: [
                    "code": AnyCodable(404),
                    "message": AnyCodable("Missing required record id."),
                    "data": AnyCodable([String: AnyCodable]())
                ]
            )
        }

        var opt = options ?? SendOptions()
        opt.method = "GET"
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
    }

    open func create<T: Codable & Sendable>(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        if let body = bodyParams {
            opt.body = body
        }
        return try await client.send(path: baseCrudPath, options: opt)
    }

    open func update<T: Codable & Sendable>(id: String, bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        opt.method = "PATCH"
        if let body = bodyParams {
            opt.body = body
        }
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
    }

    open func delete(id: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "DELETE"
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/\(encodedId)", options: opt)
        return true
    }
}
