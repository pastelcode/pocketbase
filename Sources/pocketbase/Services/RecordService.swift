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

    /// Factory for the one-off realtime service used by the interactive
    /// OAuth2 flow. Internal so tests can inject a fake transport.
    var oauth2RealtimeServiceFactory: (@Sendable () -> RealtimeService)?

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
        let encoded = collectionIdOrName.encodeURIComponent()
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
    ///
    /// - Note: Events whose payload cannot be decoded as
    ///   ``RecordSubscription`` of `T` are ignored. Subscribe through
    ///   ``RealtimeService`` directly to receive the raw payloads.
    /// - Note: The reference SDK orders the parameters as
    ///   `subscribe(topic, callback, options)`. In Swift, `options` precede the
    ///   `callback` so callers can pass them alongside a trailing closure.
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
    /// Prepares a successful authentication response.
    ///
    /// The record is materialized through ``CrudService/decode(_:)`` (so
    /// subclasses can customize it) and saved in ``PocketBase/authStore``.
    /// A missing `token` or `record` defaults to `""` and `{}`, matching the
    /// reference SDK.
    private func processAuthResponse<T: Codable & Sendable>(_ responseData: [String: AnyCodable]) throws -> RecordAuthResponse<T> {
        let token = responseData["token"]?.stringValue ?? ""

        var recordValue = responseData["record"] ?? AnyCodable([String: AnyCodable]())
        if case .null = recordValue.value {
            recordValue = AnyCodable([String: AnyCodable]())
        }

        let record: RecordModel = try decode(recordValue)
        client.authStore.save(token: token, record: record)

        let typedRecord: T
        if let typed = record as? T {
            typedRecord = typed
        } else {
            let data = try JSONEncoder().encode(record)
            typedRecord = try JSONDecoder().decode(T.self, from: data)
        }

        var meta: [String: AnyCodable]?
        if case .dictionary(let metaDict)? = responseData["meta"]?.value {
            meta = metaDict
        }

        return RecordAuthResponse(record: typedRecord, token: token, meta: meta)
    }

    /// Returns the enabled authentication methods for the collection.
    ///
    /// - Parameter options: Additional request options.
    /// - Returns: The configured MFA, OTP, password, and OAuth2 methods.
    /// - Throws: A ``ClientResponseError`` if the request fails.
    open func listAuthMethods(options: SendOptions? = nil) async throws -> AuthMethodsList {
        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("GET")
        opt.applyDefaultQuery(["fields": AnyCodable("mfa,otp,password,oauth2")])
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "identity": AnyCodable(usernameOrEmail),
            "password": AnyCodable(password)
        ]))

        let autoRefreshThreshold = isSuperusers ? opt.autoRefreshThreshold : nil
        if isSuperusers && opt.autoRefresh != true {
            AutoRefresh.resetAutoRefresh(client)
        }

        let respData: [String: AnyCodable] = try await client.send(path: "\(baseCollectionPath)/auth-with-password", options: opt)
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
        opt.applyDefaultMethod("POST")
        var bodyDict: [String: AnyCodable] = [
            "provider": AnyCodable(provider),
            "code": AnyCodable(code),
            "codeVerifier": AnyCodable(codeVerifier),
            "redirectURL": AnyCodable(redirectURL)
        ]
        if let createData = createData {
            bodyDict["createData"] = AnyCodable(createData)
        }
        opt.applyDefaultBody(.json(bodyDict))

        let respData: [String: AnyCodable] = try await client.send(path: "\(baseCollectionPath)/auth-with-oauth2", options: opt)
        return try processAuthResponse(respData)
    }

    /// Authenticates as a record with an interactive OAuth2 flow.
    ///
    /// The flow discovers the providers with ``listAuthMethods(options:)``,
    /// opens a one-off realtime subscription on the `@oauth2` topic, calls
    /// `urlCallback` with the provider authorization URL and waits for the
    /// provider to redirect to the server's `/api/oauth2-redirect` page, which
    /// delivers the authorization code back over the realtime connection. The
    /// code is then exchanged with
    /// ``authWithOAuth2Code(provider:code:codeVerifier:redirectURL:createData:options:)``
    /// and the token and record are saved in ``PocketBase/authStore``.
    ///
    /// The SDK never opens a browser itself; `urlCallback` receives the
    /// authorization URL and is responsible for opening it:
    ///
    /// ```swift
    /// let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithOAuth2(
    ///     provider: "google",
    ///     urlCallback: { url in
    ///         await UIApplication.shared.open(URL(string: url)!)
    ///     }
    /// )
    /// ```
    ///
    /// - Important: Configure `https://yourdomain.com/api/oauth2-redirect` as
    ///   the redirect URL in the provider dashboard. The one-off realtime
    ///   connection is closed when the flow finishes or fails.
    ///
    /// - Parameters:
    ///   - providerName: The name of the OAuth2 provider, e.g. `"google"`.
    ///   - urlCallback: Called with the authorization URL to open in a browser
    ///     or web view.
    ///   - scopes: Custom scopes that replace the provider defaults.
    ///   - createData: Extra fields used when creating a new auth record.
    ///   - options: Additional request options forwarded to the code exchange.
    /// - Returns: The authenticated record and token.
    /// - Throws: A ``ClientResponseError`` when the provider is unknown, the
    ///   realtime state does not match, the connection drops, the task is
    ///   cancelled (``ClientResponseError/isAbort``), or the code exchange
    ///   fails.
    open func authWithOAuth2<T: Codable & Sendable>(
        provider providerName: String,
        urlCallback: @escaping @Sendable (String) async throws -> Void,
        scopes: [String]? = nil,
        createData: [String: AnyCodable]? = nil,
        options: SendOptions? = nil
    ) async throws -> RecordAuthResponse<T> {
        let authMethods = try await listAuthMethods()
        guard let provider = authMethods.oauth2.providers.first(where: { $0.name == providerName }) else {
            throw ClientResponseError(message: "Missing or invalid provider \"\(providerName)\".")
        }

        let redirectURL = client.buildURL(path: "/api/oauth2-redirect")
        let realtime = oauth2RealtimeServiceFactory?() ?? RealtimeService(client)
        let inbox = OAuth2EventInbox()

        // A dropped connection while the flow is active can never complete.
        realtime.onDisconnect = { activeSubscriptions in
            guard !activeSubscriptions.isEmpty else { return }
            inbox.fail(ClientResponseError(message: "realtime connection interrupted"))
        }

        do {
            _ = try await realtime.subscribe(topic: "@oauth2") { data in
                let currentState = realtime.clientId
                let state = data["state"] as? String ?? ""
                let code = data["code"] as? String ?? ""
                let oauthError = data["error"] as? String ?? ""

                guard !state.isEmpty, state == currentState else {
                    inbox.fail(ClientResponseError(message: "State parameters don't match."))
                    return
                }

                guard oauthError.isEmpty, !code.isEmpty else {
                    let details = oauthError.isEmpty ? "" : ": \(oauthError)"
                    inbox.fail(ClientResponseError(message: "OAuth2 redirect error or missing code\(details)"))
                    return
                }

                inbox.succeed(code)
            }
        } catch {
            await cleanupOAuth2(realtime)
            throw error
        }

        do {
            let authURL = buildOAuth2AuthURL(
                provider: provider,
                redirectURL: redirectURL,
                state: realtime.clientId,
                scopes: scopes
            )
            try await urlCallback(authURL)

            let code = try await withTaskCancellationHandler {
                try await inbox.wait()
            } onCancel: {
                inbox.fail(ClientResponseError(isAbort: true, message: "manually cancelled"))
            }

            let result: RecordAuthResponse<T> = try await authWithOAuth2Code(
                provider: provider.name,
                code: code,
                codeVerifier: provider.codeVerifier,
                redirectURL: redirectURL,
                createData: createData,
                options: options
            )
            await cleanupOAuth2(realtime)
            return result
        } catch {
            await cleanupOAuth2(realtime)
            throw error
        }
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
        opt.applyDefaultMethod("POST")
        let respData: [String: AnyCodable] = try await client.send(path: "\(baseCollectionPath)/auth-refresh", options: opt)
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["email": AnyCodable(email)]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "token": AnyCodable(passwordResetToken),
            "password": AnyCodable(password),
            "passwordConfirm": AnyCodable(passwordConfirm)
        ]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["email": AnyCodable(email)]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["token": AnyCodable(verificationToken)]))
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/confirm-verification", options: opt)

        let payload = JWTUtils.getTokenPayload(verificationToken)
        if var model = client.authStore.record,
           model.id == payload["id"]?.value.string,
           model.collectionId == payload["collectionId"]?.value.string,
           model.rawFields["verified"]?.boolValue != true {
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["newEmail": AnyCodable(newEmail)]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "token": AnyCodable(emailChangeToken),
            "password": AnyCodable(password)
        ]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["email": AnyCodable(email)]))
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json([
            "otpId": AnyCodable(otpId),
            "password": AnyCodable(password)
        ]))
        let respData: [String: AnyCodable] = try await client.send(path: "\(baseCollectionPath)/auth-with-otp", options: opt)
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
        opt.applyDefaultMethod("POST")
        opt.applyDefaultBody(.json(["duration": AnyCodable(duration)]))

        if opt.headers["Authorization"] == nil {
            opt.headers["Authorization"] = client.authStore.token
        }

        let newClient = PocketBase(baseURL: client.baseURL, authStore: BaseAuthStore(), lang: client.lang)
        let encodedId = recordId.encodeURIComponent()
        let authData: RecordAuthResponse<RecordModel> = try await newClient.send(path: "\(baseCollectionPath)/impersonate/\(encodedId)", options: opt)

        newClient.authStore.save(token: authData.token, record: authData.record)
        return newClient
    }

    // MARK: - OAuth2 Flow Helpers
    /// Closes the one-off realtime connection used by the interactive OAuth2
    /// flow.
    private func cleanupOAuth2(_ realtime: RealtimeService) async {
        realtime.onDisconnect = nil
        try? await realtime.unsubscribe()
    }

    /// Builds the provider authorization URL for the one-off OAuth2 flow.
    private func buildOAuth2AuthURL(provider: AuthProviderInfo, redirectURL: String, state: String, scopes: [String]?) -> String {
        var replacements: [String: String?] = ["state": state]
        if let scopes = scopes, !scopes.isEmpty {
            replacements["scope"] = scopes.joined(separator: " ")
        }
        return replaceQueryParams(provider.authURL + redirectURL, replacements: replacements)
    }

    /// Replaces (or removes, when the value is `nil`) query parameters in a
    /// URL, mirroring the reference SDK's `_replaceQueryParams` helper. This
    /// keeps the provider's own parameters intact and re-encodes every value.
    private func replaceQueryParams(_ url: String, replacements: [String: String?]) -> String {
        var urlPath = url
        var query = ""

        if let queryIndex = url.firstIndex(of: "?") {
            urlPath = String(url[..<queryIndex])
            query = String(url[url.index(after: queryIndex)...])
        }

        var parsedParams: [(key: String, value: String)] = []
        for param in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(pair[0]).replacingOccurrences(of: "+", with: " ")
            let rawValue = pair.count > 1 ? String(pair[1]).replacingOccurrences(of: "+", with: " ") : ""
            guard let key = rawKey.removingPercentEncoding,
                  let value = rawValue.removingPercentEncoding else {
                continue
            }

            if let index = parsedParams.firstIndex(where: { $0.key == key }) {
                parsedParams[index].value = value
            } else {
                parsedParams.append((key, value))
            }
        }

        for (key, value) in replacements {
            if let index = parsedParams.firstIndex(where: { $0.key == key }) {
                if let value = value {
                    parsedParams[index].value = value
                } else {
                    parsedParams.remove(at: index)
                }
            } else if let value = value {
                parsedParams.append((key, value))
            }
        }

        let rebuilt = parsedParams
            .map { "\($0.key.encodeURIComponent())=\($0.value.encodeURIComponent())" }
            .joined(separator: "&")

        return rebuilt.isEmpty ? urlPath : "\(urlPath)?\(rebuilt)"
    }
}

/// A single-shot, thread-safe handoff of the OAuth2 authorization code (or
/// error) from the realtime callback to the awaiting flow.
private final class OAuth2EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingResult: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var isCompleted = false

    func succeed(_ code: String) {
        complete(with: .success(code))
    }

    func fail(_ error: Error) {
        complete(with: .failure(error))
    }

    func wait() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func complete(with result: Result<String, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true

        if let continuation = continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
