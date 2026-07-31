import Foundation

open class RecordService<M: Codable & Sendable>: CrudService<M>, @unchecked Sendable {
    public let collectionIdOrName: String

    public init(_ client: PocketBase, collectionIdOrName: String) {
        self.collectionIdOrName = collectionIdOrName
        super.init(client)
    }

    open override var baseCrudPath: String {
        return "\(baseCollectionPath)/records"
    }

    open var baseCollectionPath: String {
        let encoded = collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName
        return "/api/collections/\(encoded)"
    }

    open var isSuperusers: Bool {
        return collectionIdOrName == "_superusers" || collectionIdOrName == "_pbc_2773867675"
    }

    // MARK: - Subscriptions
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

    open func unsubscribe(_ topic: String? = nil) async throws {
        if let topic = topic {
            try await client.realtime.unsubscribe("\(collectionIdOrName)/\(topic)")
        } else {
            try await client.realtime.unsubscribeByPrefix(collectionIdOrName)
        }
    }

    // MARK: - Crud Overrides
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

    open func listAuthMethods(options: SendOptions? = nil) async throws -> AuthMethodsList {
        var opt = options ?? SendOptions()
        opt.method = "GET"
        if opt.query["fields"] == nil {
            opt.query["fields"] = AnyCodable("mfa,otp,password,oauth2")
        }
        return try await client.send(path: "\(baseCollectionPath)/auth-methods", options: opt)
    }

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

    open func authRefresh<T: Codable & Sendable>(options: SendOptions? = nil) async throws -> RecordAuthResponse<T> {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        let respData: RecordAuthResponse<RecordModel> = try await client.send(path: "\(baseCollectionPath)/auth-refresh", options: opt)
        return try processAuthResponse(respData)
    }

    open func requestPasswordReset(email: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-password-reset", options: opt)
        return true
    }

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

    open func requestVerification(email: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-verification", options: opt)
        return true
    }

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

    open func requestEmailChange(newEmail: String, options: SendOptions? = nil) async throws -> Bool {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["newEmail": AnyCodable(newEmail)])
        let _: Data = try await client.sendRaw(path: "\(baseCollectionPath)/request-email-change", options: opt)
        return true
    }

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

    @available(*, deprecated, message: "Use collection('_externalAuths').* instead.")
    open func listExternalAuths(recordId: String, options: SendOptions? = nil) async throws -> [RecordModel] {
        var opt = options ?? SendOptions()
        let filterStr = client.filter("recordRef = {:id}", params: ["id": recordId])
        opt.query["filter"] = AnyCodable(filterStr)
        let extAuthService: RecordService<RecordModel> = client.collection("_externalAuths")
        return try await extAuthService.getFullList(options: opt)
    }

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

    open func requestOTP(email: String, options: SendOptions? = nil) async throws -> OTPResponse {
        var opt = options ?? SendOptions()
        opt.method = "POST"
        opt.body = .json(["email": AnyCodable(email)])
        return try await client.send(path: "\(baseCollectionPath)/request-otp", options: opt)
    }

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
