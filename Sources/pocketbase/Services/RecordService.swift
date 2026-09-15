import Foundation

/// A service for interacting with the records of a single collection.
///
/// Instances are vended by `PocketBase.collection(_:)`, which caches them per
/// collection. Auth methods such as
/// ``authWithPassword(usernameOrEmail:password:options:)`` store the resulting
/// token and record in the client's ``PocketBase/authStore``.
///
/// ```swift
/// let pb = PocketBase(baseURL: "https://example.com")
/// let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithPassword(
///     usernameOrEmail: "user@example.com",
///     password: "secret"
/// )
/// ```
open class RecordService<M: Codable & Sendable>: CrudService<M>, @unchecked Sendable {
    /// The id or name of the collection this service targets.
    public let collectionIdOrName: String

    /// Creates a record service for the given collection.
    ///
    /// - Parameters:
    ///   - client: The client the service belongs to.
    ///   - collectionIdOrName: The collection id or name.
    public init(_ client: PocketBase, collectionIdOrName: String) {
        self.collectionIdOrName = collectionIdOrName
        super.init(client)
    }

    /// The CRUD path for the collection's records
    /// (`<baseCollectionPath>/records`).
    open override var baseCrudPath: String {
        return "\(baseCollectionPath)/records"
    }

    /// The API path of the collection, e.g. `/api/collections/posts`.
    open var baseCollectionPath: String {
        let encoded = collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName
        return "/api/collections/\(encoded)"
    }

    /// Whether this service targets the built-in `_superusers` collection.
    open var isSuperusers: Bool {
        return collectionIdOrName == "_superusers" || collectionIdOrName == "_pbc_2773867675"
    }

    // MARK: - Subscriptions
    /// Subscribes to realtime events for a topic on the collection.
    ///
    /// The `topic` is prefixed with ``collectionIdOrName`` before being passed
    /// to ``RealtimeService``. The callback is invoked for each received event.
    ///
    /// ```swift
    /// let unsubscribe = try await pb.collection("posts").subscribe(topic: "*") { event in
    ///     print(event.action, event.record.id)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - topic: The topic to subscribe to, e.g. `"*"` for all records.
    ///   - options: Realtime request options.
    ///   - callback: A closure called for each received event.
    /// - Returns: A function that removes this subscription when called.
    /// - Throws: A ``ClientResponseError`` when `topic` is empty or the
    ///   subscription fails.
    open func subscribe<T: Codable & Sendable>(
        topic: String,
        options: SendOptions? = nil,
        callback: @escaping @Sendable (RecordSubscription<T>) -> Void
    ) async throws -> UnsubscribeFunc {
        guard !topic.isEmpty else {
            throw ClientResponseError(message: "Missing topic.")
        }

        let fullTopic = "\(collectionIdOrName)/\(topic)"
        return try await client.realtime.subscribe(topic: fullTopic, options: options) { dataDict in
            if let data = try? JSONSerialization.data(withJSONObject: dataDict),
               let subscription = try? JSONDecoder().decode(RecordSubscription<T>.self, from: data) {
                callback(subscription)
            }
        }
    }

    /// Unsubscribes from realtime events on the collection.
    ///
    /// - Parameter topic: The topic to unsubscribe from, or `nil` to remove all
    ///   subscriptions of this collection.
    /// - Throws: A ``ClientResponseError`` if the update request fails.
    open func unsubscribe(_ topic: String? = nil) async throws {
        if let topic = topic {
            try await client.realtime.unsubscribe("\(collectionIdOrName)/\(topic)")
        } else {
            try await client.realtime.unsubscribeByPrefix(collectionIdOrName)
        }
    }

    // MARK: - Crud Overrides
    /// Updates a record and refreshes the auth store when the updated record is
    /// the currently authenticated one.
    ///
    /// - Parameters:
    ///   - id: The id of the record to update.
    ///   - bodyParams: The fields to update.
    ///   - options: Additional request options.
    /// - Returns: The updated record.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open override func update<T: Codable & Sendable>(
        id: String,
        bodyParams: SendOptions.AnySendableBody? = nil,
        options: SendOptions? = nil
    ) async throws -> T {
        let item: RecordModel = try await super.update(id: id, bodyParams: bodyParams, options: options)

        if let currentAuthRecord = client.authStore.record,
           currentAuthRecord.id == item.id,
           (currentAuthRecord.collectionId == collectionIdOrName || currentAuthRecord.collectionName == collectionIdOrName) {
            var updatedRecord = item
            if let currentExpand = currentAuthRecord.expand {
                var mergedExpand = currentExpand
                if let itemExpand = item.expand {
                    for (k, v) in itemExpand {
                        mergedExpand[k] = v
                    }
                }
                updatedRecord.expand = mergedExpand
            }
            client.authStore.save(token: client.authStore.token, record: updatedRecord)
        }

        if let typedResult = item as? T {
            return typedResult
        } else {
            let data = try JSONEncoder().encode(item)
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Deletes a record and clears the auth store when the deleted record is
    /// the currently authenticated one.
    ///
    /// - Parameters:
    ///   - id: The id of the record to delete.
    ///   - options: Additional request options.
    /// - Returns: `true` when the deletion succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open override func delete(id: String, options: SendOptions? = nil) async throws -> Bool {
        let success = try await super.delete(id: id, options: options)
        if success,
           let currentAuthRecord = client.authStore.record,
           currentAuthRecord.id == id,
           (currentAuthRecord.collectionId == collectionIdOrName || currentAuthRecord.collectionName == collectionIdOrName) {
            client.authStore.clear()
        }
        return success
    }

    // MARK: - Auth Handlers
    private func processAuthResponse<T: Codable & Sendable>(_ responseData: RecordAuthResponse<RecordModel>) throws -> RecordAuthResponse<T> {
        client.authStore.save(token: responseData.token, record: responseData.record)

        if let typedRecord = responseData.record as? T {
            return RecordAuthResponse<T>(record: typedRecord, token: responseData.token, meta: responseData.meta)
        } else {
            let recData = try JSONEncoder().encode(responseData.record)
            let decodedRecord = try JSONDecoder().decode(T.self, from: recData)
            return RecordAuthResponse<T>(record: decodedRecord, token: responseData.token, meta: responseData.meta)
        }
    }

    /// Returns the enabled authentication methods for the collection.
    ///
    /// - Parameter options: Additional request options.
    /// - Returns: The configured MFA, OTP, password, and OAuth2 methods.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func listAuthMethods(options: SendOptions? = nil) async throws -> AuthMethodsList {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        if opt.query["fields"] == nil {
            opt.query["fields"] = AnyCodable("mfa,otp,password,oauth2")
        }
        return try await client.send(path: "\(baseCollectionPath)/auth-methods", options: opt)
    }

    /// Authenticates as a record with an identity and password.
    ///
    /// On success the token and record are saved in ``PocketBase/authStore``.
    /// For superusers, `options.autoRefreshThreshold` registers automatic
    /// token refresh before expiry.
    ///
    /// - Parameters:
    ///   - usernameOrEmail: The record's email or username, per the collection's
    ///     identity fields.
    ///   - password: The record's password.
    ///   - options: Additional request options.
    /// - Returns: The authenticated record and token.
    /// - Throws: A ``ClientResponseError`` if authentication fails.
    open func authWithPassword<T: Codable & Sendable>(
        usernameOrEmail: String,
        password: String,
        options: SendOptions? = nil
    ) async throws -> RecordAuthResponse<T> {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "identity": AnyCodable(usernameOrEmail),
            "password": AnyCodable(password)
        ])

        let autoRefreshThreshold = isSuperusers ? opt.autoRefreshThreshold : nil
        if isSuperusers && opt.autoRefresh != true {
            AutoRefresh.resetAutoRefresh(client)
        }

        let respData: RecordAuthResponse<RecordModel> = try await client.send(path: "\(baseCollectionPath)/auth-with-password", options: opt)
        let result: RecordAuthResponse<T> = try processAuthResponse(respData)

        if let threshold = autoRefreshThreshold, isSuperusers {
            AutoRefresh.registerAutoRefresh(
                client,
                threshold: threshold,
                refreshFunc: { [weak self] in
                    guard let self = self else { return }
                    let _: RecordAuthResponse<T> = try await self.authRefresh(options: SendOptions(autoRefresh: true))
                },
                reauthenticateFunc: { [weak self] in
                    guard let self = self else { return }
                    var reauthOpt = options ?? SendOptions()
                    reauthOpt.autoRefresh = true
                    let _: RecordAuthResponse<T> = try await self.authWithPassword(
                        usernameOrEmail: usernameOrEmail,
                        password: password,
                        options: reauthOpt
                    )
                }
            )
        }

        return result
    }

    /// Authenticates as a record using an OAuth2 authorization code.
    ///
    /// On success the token and record are saved in ``PocketBase/authStore``.
    ///
    /// - Parameters:
    ///   - provider: The OAuth2 provider name, e.g. `"google"`.
    ///   - code: The authorization code returned by the provider.
    ///   - codeVerifier: The PKCE code verifier used for the authorization
    ///     request.
    ///   - redirectURL: The redirect URL used for the authorization request.
    ///   - createData: Extra fields used when creating a new auth record.
    ///   - options: Additional request options.
    /// - Returns: The authenticated record and token.
    /// - Throws: A ``ClientResponseError`` if authentication fails.
    open func authWithOAuth2Code<T: Codable & Sendable>(
        provider: String,
        code: String,
        codeVerifier: String,
        redirectURL: String,
        createData: [String: AnyCodable]? = nil,
        options: SendOptions? = nil
    ) async throws -> RecordAuthResponse<T> {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        var bodyDict: [String: AnyCodable] = [
            "provider": AnyCodable(provider),
            "code": AnyCodable(code),
            "codeVerifier": AnyCodable(codeVerifier),
            "redirectURL": AnyCodable(redirectURL)
        ]
        if let createData = createData {
            bodyDict["createData"] = AnyCodable(createData)
        }
        opt.body = .json(bodyDict)

        let respData: RecordAuthResponse<RecordModel> = try await client.send(path: "\(baseCollectionPath)/auth-with-oauth2", options: opt)
        return try processAuthResponse(respData)
    }

    /// Refreshes the current authentication and returns the updated record.
    ///
    /// The refreshed token and record are saved in ``PocketBase/authStore``.
    ///
    /// - Parameter options: Additional request options.
    /// - Returns: The refreshed record and token.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func authRefresh<T: Codable & Sendable>(options: SendOptions? = nil) async throws -> RecordAuthResponse<T> {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let respData: RecordAuthResponse<RecordModel> = try await client.send(path: "\(baseCollectionPath)/auth-refresh", options: opt)
        return try processAuthResponse(respData)
    }

    /// Requests a password reset email.
    ///
    /// - Parameters:
    ///   - email: The email of the record.
    ///   - options: Additional request options.
    /// - Returns: `true` when the request succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func requestPasswordReset(email: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-password-reset", options: opt)
        return true
    }

    /// Confirms a password reset using the token from the reset email.
    ///
    /// - Parameters:
    ///   - passwordResetToken: The token from the reset email.
    ///   - password: The new password.
    ///   - passwordConfirm: The new password confirmation.
    ///   - options: Additional request options.
    /// - Returns: `true` when the reset succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func confirmPasswordReset(
        passwordResetToken: String,
        password: String,
        passwordConfirm: String,
        options: SendOptions? = nil
    ) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "token": AnyCodable(passwordResetToken),
            "password": AnyCodable(password),
            "passwordConfirm": AnyCodable(passwordConfirm)
        ])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/confirm-password-reset", options: opt)
        return true
    }

    /// Requests a verification email.
    ///
    /// - Parameters:
    ///   - email: The email of the record.
    ///   - options: Additional request options.
    /// - Returns: `true` when the request succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func requestVerification(email: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-verification", options: opt)
        return true
    }

    /// Confirms a record's email verification using the token from the
    /// verification email.
    ///
    /// When the verified record is the authenticated one, the auth store is
    /// updated with `verified = true`.
    ///
    /// - Parameters:
    ///   - verificationToken: The token from the verification email.
    ///   - options: Additional request options.
    /// - Returns: `true` when the verification succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func confirmVerification(verificationToken: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["token": AnyCodable(verificationToken)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/confirm-verification", options: opt)

        let payload = JWTUtils.getTokenPayload(verificationToken)
        if var model = client.authStore.record,
           model.id == payload["id"]?.value.string,
           model.collectionId == payload["collectionId"]?.value.string {
            model.rawFields["verified"] = AnyCodable(true)
            client.authStore.save(token: client.authStore.token, record: model)
        }

        return true
    }

    /// Requests a change of the record's email address.
    ///
    /// - Parameters:
    ///   - newEmail: The requested new email.
    ///   - options: Additional request options.
    /// - Returns: `true` when the request succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func requestEmailChange(newEmail: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["newEmail": AnyCodable(newEmail)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-email-change", options: opt)
        return true
    }

    /// Confirms an email change using the token from the confirmation email.
    ///
    /// When the changed record is the authenticated one, the auth store is
    /// cleared, requiring re-authentication.
    ///
    /// - Parameters:
    ///   - emailChangeToken: The token from the confirmation email.
    ///   - password: The record's password.
    ///   - options: Additional request options.
    /// - Returns: `true` when the change succeeds.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func confirmEmailChange(emailChangeToken: String, password: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "token": AnyCodable(emailChangeToken),
            "password": AnyCodable(password)
        ])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/confirm-email-change", options: opt)

        let payload = JWTUtils.getTokenPayload(emailChangeToken)
        if let model = client.authStore.record,
           model.id == payload["id"]?.value.string,
           model.collectionId == payload["collectionId"]?.value.string {
            client.authStore.clear()
        }

        return true
    }

    /// Returns the external auth links of a record.
    ///
    /// - Parameters:
    ///   - recordId: The id of the record.
    ///   - options: Additional request options.
    /// - Returns: The external auth records linked to the record.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    /// - Important: Deprecated. Use `collection('_externalAuths')` instead.
    @available(*, deprecated, message: "Use collection('_externalAuths').* instead.")
    open func listExternalAuths(recordId: String, options: SendOptions? = nil) async throws -> [RecordModel] {
        var opt = options ?? SendOptions()
        let filterStr = client.filter("recordRef = {:id}", params: ["id": recordId])
        opt.query["filter"] = AnyCodable(filterStr)
        let extAuthService: RecordService<RecordModel> = client.collection("_externalAuths")
        return try await extAuthService.getFullList(options: opt)
    }

    /// Removes an external auth link from a record.
    ///
    /// - Parameters:
    ///   - recordId: The id of the record.
    ///   - provider: The external auth provider name.
    ///   - options: Additional request options.
    /// - Returns: `true` when the link is removed.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    /// - Important: Deprecated. Use `collection('_externalAuths')` instead.
    @available(*, deprecated, message: "Use collection('_externalAuths').* instead.")
    open func unlinkExternalAuth(recordId: String, provider: String, options: SendOptions? = nil) async throws -> Bool {
        let filterStr = client.filter("recordRef = {:recordId} && provider = {:provider}", params: [
            "recordId": recordId,
            "provider": provider
        ])
        let extAuthService: RecordService<RecordModel> = client.collection("_externalAuths")
        let ea: RecordModel = try await extAuthService.getFirstListItem(filter: filterStr)
        return try await extAuthService.delete(id: ea.id, options: options)
    }

    /// Requests a one-time password email.
    ///
    /// - Parameters:
    ///   - email: The email of the record.
    ///   - options: Additional request options.
    /// - Returns: The OTP id to pass to ``authWithOTP(otpId:password:options:)``.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func requestOTP(email: String, options: SendOptions? = nil) async throws -> OTPResponse {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        return try await client.send(path: "\(baseCollectionPath)/request-otp", options: opt)
    }

    /// Authenticates as a record with an OTP id and password.
    ///
    /// On success the token and record are saved in ``PocketBase/authStore``.
    ///
    /// - Parameters:
    ///   - otpId: The id returned by ``requestOTP(email:options:)``.
    ///   - password: The one-time password.
    ///   - options: Additional request options.
    /// - Returns: The authenticated record and token.
    /// - Throws: A ``ClientResponseError`` if authentication fails.
    open func authWithOTP<T: Codable & Sendable>(otpId: String, password: String, options: SendOptions? = nil) async throws -> RecordAuthResponse<T> {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "otpId": AnyCodable(otpId),
            "password": AnyCodable(password)
        ])
        let respData: RecordAuthResponse<RecordModel> = try await client.send(path: "\(baseCollectionPath)/auth-with-otp", options: opt)
        return try processAuthResponse(respData)
    }

    /// Impersonates a record for the given duration.
    ///
    /// Returns a new ``PocketBase`` client authenticated as the impersonated
    /// record; the current client is left untouched.
    ///
    /// - Parameters:
    ///   - recordId: The id of the record to impersonate.
    ///   - duration: The impersonation duration in seconds.
    ///   - options: Additional request options.
    /// - Returns: A new client authenticated as the record.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func impersonate(recordId: String, duration: Int, options: SendOptions? = nil) async throws -> PocketBase {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["duration": AnyCodable(duration)])

        if opt.headers["Authorization"] == nil {
            opt.headers["Authorization"] = client.authStore.token
        }

        let newClient = PocketBase(baseURL: client.baseURL, authStore: BaseAuthStore(), lang: client.lang)
        let encodedId = recordId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? recordId
        let authData: RecordAuthResponse<RecordModel> = try await newClient.send(path: "\(baseCollectionPath)/impersonate/\(encodedId)", options: opt)

        newClient.authStore.save(token: authData.token, record: authData.record)
        return newClient
    }
}
