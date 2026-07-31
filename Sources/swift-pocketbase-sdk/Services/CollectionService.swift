import Foundation

open class CollectionService: CrudService<CollectionModel>, @unchecked Sendable {
    open override var baseCrudPath: String {
        return "/api/collections"
    }

    open func importCollections(_ collections: [CollectionModel], deleteMissing: Bool = false, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "PUT"
        opt.body = .json([
            "collections": AnyCodable(collections),
            "deleteMissing": AnyCodable(deleteMissing)
        ])
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/import", options: opt)
        return true
    }

    open func truncate(_ collectionIdOrName: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "DELETE"
        let encoded = collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/\(encoded)/truncate", options: opt)
        return true
    }

    open func getScaffolds(options: SendOptions? = nil) async throws -> [String: CollectionModel] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "\(baseCrudPath)/meta/scaffolds", options: opt)
    }

    open func getAllOAuth2Providers(options: SendOptions? = nil) async throws -> [ConfigurableOAuth2Provider] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "\(baseCrudPath)/meta/oauth2-providers", options: opt)
    }

    open func dryRunViewQuery(_ query: String, options: SendOptions? = nil) async throws -> [[String: AnyCodable]] {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["query": AnyCodable(query)])
        return try await client.send(path: "\(baseCrudPath)/meta/dry-run-view", options: opt)
    }
}
