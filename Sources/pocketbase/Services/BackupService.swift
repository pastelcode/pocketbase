import Foundation

open class BackupService: BaseService, @unchecked Sendable {
    open func getFullList(options: SendOptions? = nil) async throws -> [BackupFileInfo] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/backups", options: opt)
    }

    open func create(basename: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["name": AnyCodable(basename)])
        let _: Data = try await client.sendRaw(path: "/api/backups", options: opt)
        return true
    }

    open func upload(bodyParams: SendOptions.AnySendableBody, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = bodyParams
        let _: Data = try await client.sendRaw(path: "/api/backups/upload", options: opt)
        return true
    }

    open func delete(key: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "DELETE"
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let _: Data = try await client.sendRaw(path: "/api/backups/\(encodedKey)", options: opt)
        return true
    }

    open func restore(key: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let _: Data = try await client.sendRaw(path: "/api/backups/\(encodedKey)/restore", options: opt)
        return true
    }

    @available(*, deprecated, message: "Use getDownloadURL instead.")
    open func getDownloadUrl(token: String, key: String) -> String {
        return getDownloadURL(token: token, key: key)
    }

    open func getDownloadURL(token: String, key: String) -> String {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return client.buildURL(path: "/api/backups/\(encodedKey)?token=\(encodedToken)")
    }
}
