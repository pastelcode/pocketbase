import Foundation

open class SettingsService: BaseService, @unchecked Sendable {
    open func getAll(options: SendOptions? = nil) async throws -> [String: AnyCodable] {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        return try await client.send(path: "/api/settings", options: opt)
    }

    open func update(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> [String: AnyCodable] {
        var opt = options ?? SendOptions()
        opt.method = "PATCH"
        if let body = bodyParams {
            opt.body = body
        }
        return try await client.send(path: "/api/settings", options: opt)
    }

    open func testS3(filesystem: String = "storage", options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["filesystem": AnyCodable(filesystem)])
        let _: Data = try await client.sendRaw(path: "/api/settings/test/s3", options: opt)
        return true
    }

    open func testEmail(collectionIdOrName: String, toEmail: String, emailTemplate: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "email": AnyCodable(toEmail),
            "template": AnyCodable(emailTemplate),
            "collection": AnyCodable(collectionIdOrName)
        ])
        let _: Data = try await client.sendRaw(path: "/api/settings/test/email", options: opt)
        return true
    }

    open func generateAppleClientSecret(
        clientId: String,
        teamId: String,
        keyId: String,
        privateKey: String,
        duration: Int,
        options: SendOptions? = nil
    ) async throws -> [String: String] {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "clientId": AnyCodable(clientId),
            "teamId": AnyCodable(teamId),
            "keyId": AnyCodable(keyId),
            "privateKey": AnyCodable(privateKey),
            "duration": AnyCodable(duration)
        ])
        return try await client.send(path: "/api/settings/apple/generate-client-secret", options: opt)
    }
}
