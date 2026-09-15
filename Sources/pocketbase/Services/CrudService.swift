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

    /// Returns all records matching the options, fetching pages internally
    /// until the result set is exhausted.
    ///
    /// The page size is controlled by `SendOptions.batch` and defaults to
    /// `1000`; `skipTotal` is always applied to each request.
    ///
    /// - Parameter options: Request options such as a filter or sort order.
    /// - Returns: All matching items.
    /// - Throws: A ``ClientResponseError`` if a page request fails.
    open func getFullList<T: Codable & Sendable>(options: SendOptions? = nil) async throws -> [T] {
        var opt = options ?? SendOptions()
        let batch = opt.batch ?? 1000
        opt.applyDefaultQuery(["skipTotal": AnyCodable(1)])

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

    /// Returns a paginated list of items.
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

        return try await client.send(path: baseCrudPath, options: opt)
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
        return try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
    }

    /// Creates a new item.
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
        return try await client.send(path: baseCrudPath, options: opt)
    }

    /// Updates an existing item.
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
        return try await client.send(path: "\(baseCrudPath)/\(encodedId)", options: opt)
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
