import Foundation

/// A generic service exposing the standard PocketBase CRUD endpoints.
///
/// Subclasses provide the CRUD base path via ``baseCrudPath``;
/// ``RecordService`` is the most common subclass, targeting a collection's
/// records.
///
/// ```swift
/// let pb = PocketBase(baseURL: "https://example.com")
/// let posts: [RecordModel] = try await pb.collection("posts").getFullList()
/// ```
open class CrudService<M: Codable & Sendable>: BaseService, @unchecked Sendable {
    /// The base path for this service's CRUD endpoints.
    ///
    /// - Important: Subclasses must override this property; the base
    ///   implementation traps.
    open var baseCrudPath: String {
        fatalError("baseCrudPath must be overridden by subclass")
    }

    /// Converts a raw response value into the service's model type.
    ///
    /// The default implementation re-encodes the value and decodes it as `T`.
    /// Override this method to customize how responses are materialized, for
    /// example to normalize field names before decoding.
    ///
    /// The hook is applied to every CRUD response: each item returned by
    /// ``getList(page:perPage:options:)`` and ``getFullList(options:)``, and
    /// the results of ``getOne(id:options:)``, ``create(bodyParams:options:)``,
    /// and ``update(id:bodyParams:options:)``. ``RecordService`` additionally
    /// routes auth records through it.
    ///
    /// ```swift
    /// final class PostsService: CrudService<RecordModel> {
    ///     override var baseCrudPath: String { "/api/collections/posts/records" }
    ///
    ///     override func decode<T: Codable & Sendable>(_ item: AnyCodable) throws -> T {
    ///         // transform `item` before decoding
    ///         try super.decode(item)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter item: The raw value decoded from the response.
    /// - Returns: The typed item.
    /// - Throws: An error when the value cannot be converted to `T`.
    open func decode<T: Codable & Sendable>(_ item: AnyCodable) throws -> T {
        let data = try JSONEncoder().encode(item)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Returns all records matching the options, fetching pages internally
    /// until the result set is exhausted.
    ///
    /// The page size is controlled by `SendOptions.batch` and defaults to
    /// `1000`; non-positive values fall back to the default. A `skipTotal=1`
    /// query value is applied by default, but caller options can override it.
    ///
    /// - Parameter options: Request options such as a filter or sort order.
    /// - Returns: All matching items.
    /// - Throws: A ``ClientResponseError`` if a page request fails.
    open func getFullList<T: Codable & Sendable>(options: SendOptions? = nil) async throws -> [T] {
        var opt = options ?? SendOptions()
        var batch = opt.batch ?? 1000
        if batch <= 0 {
            batch = 1000
        }
        opt.applyDefaultQuery(["skipTotal": AnyCodable(1)])

        var result: [T] = []
        var page = 1

        while true {
            let list: ListResult<T> = try await getList(page: page, perPage: batch, options: opt)
            result.append(contentsOf: list.items)
            if list.items.count != list.perPage {
                break
            }
            page += 1
        }

        return result
    }

    /// Returns a paginated list of items.
    ///
    /// Items are materialized through ``decode(_:)``, which subclasses can
    /// override to customize decoding.
    ///
    /// - Parameters:
    ///   - page: The 1-based page number. Defaults to `1`.
    ///   - perPage: The number of items per page. Defaults to `30`.
    ///   - options: Request options such as a filter or sort order.
    /// - Returns: A page of matching items.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func getList<T: Codable & Sendable>(page: Int = 1, perPage: Int = 30, options: SendOptions? = nil) async throws -> ListResult<T> {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        opt.applyDefaultQuery([
            "page": AnyCodable(page),
            "perPage": AnyCodable(perPage)
        ])

        let rawList: ListResult<AnyCodable> = try await client.send(path: baseCrudPath, options: opt)
        let items: [T] = try rawList.items.map { try decode($0) }
        return ListResult(
            page: rawList.page,
            perPage: rawList.perPage,
            totalItems: rawList.totalItems,
            totalPages: rawList.totalPages,
            items: items
        )
    }

    /// Returns the first item matching the filter.
    ///
    /// - Parameters:
    ///   - filter: The PocketBase filter expression.
    ///   - options: Request options such as a sort order.
    /// - Returns: The first matching item.
    /// - Throws: A ``ClientResponseError`` with status `404` when no item
    ///   matches the filter.
    open func getFirstListItem<T: Codable & Sendable>(filter: String, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        if opt.requestKey == nil {
            opt.requestKey = "one_by_filter_\(baseCrudPath)_\(filter)"
        }
        opt.applyDefaultQuery([
            "filter": AnyCodable(filter),
            "skipTotal": AnyCodable(1)
        ])

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

    /// Returns a single item by id.
    ///
    /// The response is materialized through ``decode(_:)``, which subclasses
    /// can override to customize decoding.
    ///
    /// - Parameters:
    ///   - id: The record id.
    ///   - options: Additional request options.
    /// - Returns: The matching item.
    /// - Throws: A ``ClientResponseError`` when `id` is empty (status `404`)
    ///   or the request fails.
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
        opt.applyDefaultMethod("GET")
        let encodedId = id.encodeURIComponent()
        let raw: AnyCodable = try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
        return try decode(raw)
    }

    /// Creates a new item.
    ///
    /// The response is materialized through ``decode(_:)``, which subclasses
    /// can override to customize decoding.
    ///
    /// - Parameters:
    ///   - bodyParams: The fields to set on the new item. Defaults to `nil`.
    ///   - options: Additional request options.
    /// - Returns: The created item.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func create<T: Codable & Sendable>(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(bodyParams)
        let raw: AnyCodable = try await client.send(path: baseCrudPath, options: opt)
        return try decode(raw)
    }

    /// Updates an existing item.
    ///
    /// The response is materialized through ``decode(_:)``, which subclasses
    /// can override to customize decoding.
    ///
    /// - Parameters:
    ///   - id: The id of the item to update.
    ///   - bodyParams: The fields to update. Defaults to `nil`.
    ///   - options: Additional request options.
    /// - Returns: The updated item.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func update<T: Codable & Sendable>(id: String, bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> T {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("PATCH")
        opt.applyDefaultBody(bodyParams)
        let encodedId = id.encodeURIComponent()
        let raw: AnyCodable = try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
        return try decode(raw)
    }

    /// Deletes an item by id.
    ///
    /// - Parameters:
    ///   - id: The id of the item to delete.
    ///   - options: Additional request options.
    /// - Returns: `true` when the deletion succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func delete(id: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("DELETE")
        let encodedId = id.encodeURIComponent()
        let _: Data = try await client.sendRaw(path: "\(baseCrudPath)/\(encodedId)", options: opt)
        return true
    }
}
