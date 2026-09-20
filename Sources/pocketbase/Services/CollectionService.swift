import Foundation

/// Manages collections and their metadata through the `/api/collections` endpoints.
///
/// Extends ``CrudService`` with collection import, truncation, scaffold generation,
/// OAuth2 provider discovery, and view query helpers.
open class CollectionService: CrudService<CollectionModel>, @unchecked Sendable {
    /// The base path of the collections API.
    open override var baseCrudPath: String {
        return "/api/collections"
    }

    /// Imports the provided collections into the application.
    ///
    /// Existing collections with matching names are updated, and new ones are created.
    /// Decoded collections are re-encoded with their known and unknown field
    /// data (see ``CollectionField/rawFields``), so importing collections
    /// fetched from the server keeps their original configuration.
    ///
    /// - Warning: When `deleteMissing` is `true`, every collection that is not
    ///   part of `collections` is deleted, including its fields and records.
    ///
    /// Declared using Swift's escaped-identifier syntax because `import` is a
    /// reserved keyword; the escaping backticks are not required at the call
    /// site (`service.import(...)`).
    ///
    /// - Parameter collections: The collections to import.
    /// - Parameter deleteMissing: Whether collections absent from `collections` should be deleted.
    /// - Parameter options: Additional send options. The `PUT` method and JSON body are applied by default.
    /// - Returns: `true` when the import succeeds.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func `import`(_ collections: [CollectionModel], deleteMissing: Bool = false, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("PUT")
        opt.applyDefaultBody(.json([
            "collections": AnyCodable(collections),
            "deleteMissing": AnyCodable(deleteMissing)
        ]))
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/import", options: opt)
        return true
    }

    /// Deletes all records stored in a collection.
    ///
    /// The collection schema itself is preserved.
    ///
    /// - Parameter collectionIdOrName: The collection identifier or name.
    /// - Parameter options: Additional send options. The `DELETE` method is applied by default.
    /// - Returns: `true` when the collection is truncated.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func truncate(_ collectionIdOrName: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("DELETE")
        let encoded = collectionIdOrName.encodeURIComponent()
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/\(encoded)/truncate", options: opt)
        return true
    }

    /// Returns scaffold collections for each built-in collection type.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: Scaffold collections keyed by collection type.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getScaffolds(options: SendOptions? = nil) async throws -> [String: CollectionModel] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        return try await client.send(path: "\(baseCrudPath)/meta/scaffolds", options: opt)
    }

    /// Returns all OAuth2 providers that can be configured for auth collections.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The available OAuth2 provider definitions.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getAllOAuth2Providers(options: SendOptions? = nil) async throws -> [ConfigurableOAuth2Provider] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        return try await client.send(path: "\(baseCrudPath)/meta/oauth2-providers", options: opt)
    }

    /// Executes a view collection query without persisting it.
    ///
    /// - Parameter query: The view query to test.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: The query result rows, each keyed by column name.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func dryRunViewQuery(_ query: String, options: SendOptions? = nil) async throws -> [[String: AnyCodable]] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["query": AnyCodable(query)]))
        return try await client.send(path: "\(baseCrudPath)/meta/dry-run-view", options: opt)
    }
}
