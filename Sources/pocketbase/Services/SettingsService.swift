import Foundation

/// Service for reading and updating application settings.
///
/// Wraps the `/api/settings` endpoints, including the S3 and email test helpers.
open class SettingsService: BaseService, @unchecked Sendable {
    /// Returns the current application settings.
    ///
    /// - Parameter options: Additional send options. The `GET` method is applied by default.
    /// - Returns: The settings payload keyed by setting name.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func getAll(options: SendOptions? = nil) async throws -> [String: AnyCodable] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        return try await client.send(path: "/api/settings", options: opt)
    }

    /// Updates the application settings.
    ///
    /// - Parameter bodyParams: The settings fields to update.
    /// - Parameter options: Additional send options. The `PATCH` method is applied by default.
    /// - Returns: The updated settings payload.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func update(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) async throws -> [String: AnyCodable] {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("PATCH")
        opt.applyDefaultBody(bodyParams)
        return try await client.send(path: "/api/settings", options: opt)
    }

    /// Tests the S3 storage configuration.
    ///
    /// - Parameter filesystem: The filesystem name to test, `storage` by default.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: `true` when the test succeeds.
    /// - Throws: A ``ClientResponseError`` when the test fails.
    open func testS3(filesystem: String = "storage", options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["filesystem": AnyCodable(filesystem)]))
        let _: Data = try await client.sendRaw(path: "/api/settings/test/s3", options: opt)
        return true
    }

    /// Sends a test email using the configured mail settings.
    ///
    /// - Parameter collectionIdOrName: The auth collection used to resolve the template.
    /// - Parameter toEmail: The recipient email address.
    /// - Parameter emailTemplate: The email template name to render.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: `true` when the test succeeds.
    /// - Throws: A ``ClientResponseError`` when the test fails.
    open func testEmail(collectionIdOrName: String, toEmail: String, emailTemplate: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "email": AnyCodable(toEmail),
            "template": AnyCodable(emailTemplate),
            "collection": AnyCodable(collectionIdOrName)
        ]))
        let _: Data = try await client.sendRaw(path: "/api/settings/test/email", options: opt)
        return true
    }

    /// Generates an Apple OAuth2 client secret from the provided credentials.
    ///
    /// - Parameter clientId: The Apple client (services) identifier.
    /// - Parameter teamId: The Apple developer team identifier.
    /// - Parameter keyId: The private key identifier.
    /// - Parameter privateKey: The PEM-encoded private key contents.
    /// - Parameter duration: The secret lifetime in seconds.
    /// - Parameter options: Additional send options. The `POST` method and JSON body are applied by default.
    /// - Returns: The generated client secret response.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func generateAppleClientSecret(
        clientId: String,
        teamId: String,
        keyId: String,
        privateKey: String,
        duration: Int,
        options: SendOptions? = nil
    ) async throws -> AppleClientSecret {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "clientId": AnyCodable(clientId),
            "teamId": AnyCodable(teamId),
            "keyId": AnyCodable(keyId),
            "privateKey": AnyCodable(privateKey),
            "duration": AnyCodable(duration)
        ]))
        return try await client.send(path: "/api/settings/apple/generate-client-secret", options: opt)
    }
}
