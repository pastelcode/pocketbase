import Foundation

/// Service for managing application backups.
///
/// Wraps the `/api/backups` endpoints for listing, creating, uploading,
/// restoring, deleting, and downloading backup archives.
open class BackupService: BaseService, @unchecked Sendable {
    /// Returns all available backup files.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The backup files known to the server.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getFullList(options: SendOptions? = nil) async throws -> [BackupFileInfo] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/backups", options: opt)
    }

    /// Creates a new backup archive.
    ///
    /// - Parameter basename: The archive base name, without the file extension.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: `true` when the backup is created.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func create(basename: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["name": AnyCodable(basename)])
        let _: Data = try await client.sendRaw(path: "/api/backups", options: opt)
        return true
    }

    /// Uploads a backup archive.
    ///
    /// - Parameter bodyParams: The multipart form data containing the backup file.
    /// - Parameter options: Additional send options. The `POST` method is applied by default.
    /// - Returns: `true` when the upload succeeds.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func upload(bodyParams: SendOptions.AnySendableBody, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = bodyParams
        let _: Data = try await client.sendRaw(path: "/api/backups/upload", options: opt)
        return true
    }

    /// Deletes a backup archive.
    ///
    /// - Parameter key: The backup file key or name.
    /// - Parameter options: Additional send options. The `DELETE` method is applied by default.
    /// - Returns: `true` when the backup is deleted.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func delete(key: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "DELETE"
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let _: Data = try await client.sendRaw(path: "/api/backups/\(encodedKey)", options: opt)
        return true
    }

    /// Restores the application from a backup archive.
    ///
    /// - Parameter key: The backup file key or name.
    /// - Parameter options: Additional send options. The `POST` method is applied by default.
    /// - Returns: `true` when the restore succeeds.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func restore(key: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let _: Data = try await client.sendRaw(path: "/api/backups/\(encodedKey)/restore", options: opt)
        return true
    }

    /// Builds the download URL of a backup archive.
    ///
    /// - Parameter token: A superuser token with access to the backups API.
    /// - Parameter key: The backup file key or name.
    /// - Returns: The backup download URL.
    ///
    /// - Important: Deprecated. Use ``getDownloadURL(token:key:)`` instead.
    @available(*, deprecated, message: "Use getDownloadURL instead.")
    open func getDownloadUrl(token: String, key: String) -> String {
        return getDownloadURL(token: token, key: key)
    }

    /// Builds the download URL of a backup archive.
    ///
    /// The returned URL has the shape `/api/backups/{key}?token={token}`, resolved
    /// against the configured base URL.
    ///
    /// - Parameter token: A superuser token with access to the backups API.
    /// - Parameter key: The backup file key or name.
    /// - Returns: The backup download URL.
    open func getDownloadURL(token: String, key: String) -> String {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return client.buildURL(path: "/api/backups/\(encodedKey)?token=\(encodedToken)")
    }
}
