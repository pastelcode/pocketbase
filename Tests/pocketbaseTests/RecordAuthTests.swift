import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import pocketbase

private let authBaseURL = "http://127.0.0.1:8090"
private let authMethodsURL = "http://127.0.0.1:8090/api/collections/users/auth-methods?fields=mfa%2Cotp%2Cpassword%2Coauth2"
private let oauth2ExchangeURL = "http://127.0.0.1:8090/api/collections/users/auth-with-oauth2"

private func oauth2AuthMethodsBody() -> [String: Any] {
    return [
        "mfa": ["enabled": false, "duration": 0],
        "otp": ["enabled": false, "duration": 0],
        "password": ["enabled": true, "identityFields": ["email"]],
        "oauth2": [
            "enabled": true,
            "providers": [
                [
                    "name": "google",
                    "displayName": "Google",
                    "state": "provider-state",
                    "authURL": "https://accounts.example.com/o/oauth2/v2/auth?client_id=abc&redirect_uri=",
                    "codeVerifier": "verifier123",
                    "codeChallenge": "challenge123",
                    "codeChallengeMethod": "S256"
                ]
            ]
        ]
    ]
}

private struct URLCallbackError: LocalizedError {
    var errorDescription: String? { "opener failed" }
}

private final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: String?

    var url: String? {
        lock.lock()
        defer { lock.unlock() }
        return _url
    }

    func set(_ url: String) {
        lock.lock()
        _url = url
        lock.unlock()
    }
}

private func waitForAuthFlow(timeout: Double = 3, _ condition: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private final class SaveSpyStore: BaseAuthStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _saveCount = 0

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _saveCount
    }

    override func save(token: String, record: RecordModel? = nil) {
        lock.lock()
        _saveCount += 1
        lock.unlock()
        super.save(token: token, record: record)
    }
}

private final class DecodeSpyService: RecordService<RecordModel>, @unchecked Sendable {
    private let lock = NSLock()
    private var _decodedValues: [AnyCodable] = []

    var decodedValues: [AnyCodable] {
        lock.lock()
        defer { lock.unlock() }
        return _decodedValues
    }

    override func decode<T: Codable & Sendable>(_ item: AnyCodable) throws -> T {
        lock.lock()
        _decodedValues.append(item)
        lock.unlock()
        return try super.decode(item)
    }
}

struct RecordAuthTests {
    private func makeClient(authStore: BaseAuthStore = BaseAuthStore()) -> PocketBase {
        return PocketBase(baseURL: authBaseURL, authStore: authStore)
    }

    private func installFetchMock(on client: PocketBase, _ mocks: [RequestMock]) async {
        let fetchMock = FetchMock()
        for mock in mocks {
            await fetchMock.on(mock)
        }
        client.beforeSend = { url, options in
            var updated = options
            updated.fetch = await fetchMock.customFetch()
            return (url, updated)
        }
    }

    private func makeOAuth2Service(on client: PocketBase, transport: FakeTransport) -> RecordService<RecordModel> {
        let service: RecordService<RecordModel> = client.collection("users")
        let realtime = RealtimeService(client)
        realtime.makeTransport = { transport }
        service.oauth2RealtimeServiceFactory = { realtime }
        return service
    }

    private func installOAuth2Mocks(on client: PocketBase, exchange: RequestMock? = nil) async {
        var mocks = [
            RequestMock(method: "GET", url: authMethodsURL, jsonBody: oauth2AuthMethodsBody()),
            RequestMock(method: "POST", url: "\(authBaseURL)/api/realtime", replyCode: 204)
        ]
        if let exchange = exchange {
            mocks.append(exchange)
        }
        await installFetchMock(on: client, mocks)
    }

    // MARK: - Interactive OAuth2 flow

    @Test func authWithOAuth2CompletesInteractiveFlow() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client, exchange: RequestMock(
            method: "POST",
            url: oauth2ExchangeURL,
            jsonBody: [
                "token": "token_oauth",
                "record": ["id": "rec_oauth", "collectionId": "users", "collectionName": "users"]
            ]
        ))
        let service = makeOAuth2Service(on: client, transport: transport)

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) },
                scopes: ["email", "profile"]
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        let authURL = try #require(urlBox.url)
        #expect(authURL.hasPrefix("https://accounts.example.com/o/oauth2/v2/auth?client_id=abc&redirect_uri="))
        #expect(authURL.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8090%2Fapi%2Foauth2-redirect"))
        #expect(authURL.contains("state=client-1"))
        #expect(authURL.contains("scope=email%20profile"))

        transport.emit(SSEEvent(event: "@oauth2", data: "{\"state\":\"client-1\",\"code\":\"code123\"}"))

        let result = try await task.value
        #expect(result.token == "token_oauth")
        #expect(result.record.id == "rec_oauth")
        #expect(client.authStore.token == "token_oauth")
        #expect(client.authStore.record?.id == "rec_oauth")

        await waitForAuthFlow { transport.cancelCount == 1 }
        #expect(transport.cancelCount == 1)
    }

    @Test func authWithOAuth2ThrowsForUnknownProvider() async throws {
        let client = makeClient()
        await installFetchMock(on: client, [
            RequestMock(method: "GET", url: authMethodsURL, jsonBody: oauth2AuthMethodsBody())
        ])

        let service: RecordService<RecordModel> = client.collection("users")
        do {
            _ = try await service.authWithOAuth2(
                provider: "github",
                urlCallback: { _ in }
            ) as RecordAuthResponse<RecordModel>
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.message == "Missing or invalid provider \"github\".")
        }
    }

    @Test func authWithOAuth2RejectsStateMismatch() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) }
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        transport.emit(SSEEvent(event: "@oauth2", data: "{\"state\":\"other-state\",\"code\":\"code123\"}"))

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.message == "State parameters don't match.")
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
        #expect(transport.cancelCount == 1)
    }

    @Test func authWithOAuth2RejectsProviderErrors() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) }
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        transport.emit(SSEEvent(event: "@oauth2", data: "{\"state\":\"client-1\",\"error\":\"access_denied\"}"))

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.message == "OAuth2 redirect error or missing code: access_denied")
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
    }

    @Test func authWithOAuth2CancellationAbortsAndCleansUp() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) }
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
            #expect(error.message == "manually cancelled")
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
        #expect(transport.cancelCount == 1)
    }

    @Test func authWithOAuth2FailsWhenRealtimeDisconnects() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) }
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        transport.simulateDisconnect(ClientResponseError(message: "network drop"))

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.message == "realtime connection interrupted")
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
    }

    @Test func authWithOAuth2PropagatesURLCallbackErrors() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { _ in
                    throw URLCallbackError()
                }
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.message == "opener failed")
            #expect(error.originalError is URLCallbackError)
            #expect(!error.isAbort)
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
    }

    @Test func authWithOAuth2RequestKeyCancellationAbortsFlow() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        await installOAuth2Mocks(on: client)
        let service = makeOAuth2Service(on: client, transport: transport)

        var options = SendOptions()
        options.requestKey = "flow-key"

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) },
                options: options
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }

        client.cancelRequest("flow-key")

        do {
            _ = try await task.value
            Issue.record("Expected the flow to throw")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
            #expect(error.message == "manually cancelled")
        }
        await waitForAuthFlow { transport.cancelCount == 1 }
        #expect(client.pendingRequestCount == 0)
    }

    @Test func authWithOAuth2ForwardsOptionsAndCreateData() async throws {
        let client = makeClient()
        let transport = FakeTransport()
        let exchangeURL = "\(oauth2ExchangeURL)?q1=456"
        await installOAuth2Mocks(on: client, exchange: RequestMock(
            method: "POST",
            url: exchangeURL,
            jsonBody: ["token": "t", "record": ["id": "r"]],
            additionalMatcher: { request in
                guard let body = request.httpBody,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return false
                }
                let createData = json["createData"] as? [String: Any]
                return createData?["plan"] as? String == "pro"
                    && request.value(forHTTPHeaderField: "x-test") == "789"
            }
        ))
        let service = makeOAuth2Service(on: client, transport: transport)

        var options = SendOptions()
        options.query["q1"] = AnyCodable(456)
        options.headers["x-test"] = "789"

        let urlBox = LockedURLBox()
        let task = Task {
            try await service.authWithOAuth2(
                provider: "google",
                urlCallback: { url in urlBox.set(url) },
                createData: ["plan": AnyCodable("pro")],
                options: options
            ) as RecordAuthResponse<RecordModel>
        }

        await waitForAuthFlow { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        await waitForAuthFlow { urlBox.url != nil }
        transport.emit(SSEEvent(event: "@oauth2", data: "{\"state\":\"client-1\",\"code\":\"code123\"}"))

        let result = try await task.value
        #expect(result.token == "t")
        #expect(result.record.id == "r")
    }

    // MARK: - Auth response semantics

    @Test func authResponseDefaultsMissingTokenAndRecord() async throws {
        let client = makeClient()
        await installFetchMock(on: client, [
            RequestMock(
                method: "POST",
                url: "\(authBaseURL)/api/collections/users/auth-with-password",
                jsonBody: [String: Any]()
            ),
            RequestMock(
                method: "POST",
                url: "\(authBaseURL)/api/collections/users/auth-refresh",
                jsonBody: ["token": "refreshed", "record": NSNull()]
            )
        ])

        let service: RecordService<RecordModel> = client.collection("users")

        let passwordAuth: RecordAuthResponse<RecordModel> = try await service.authWithPassword(
            usernameOrEmail: "user@example.com",
            password: "secret"
        )
        #expect(passwordAuth.token == "")
        #expect(passwordAuth.record.id == "")
        #expect(client.authStore.token == "")

        let refreshAuth: RecordAuthResponse<RecordModel> = try await service.authRefresh()
        #expect(refreshAuth.token == "refreshed")
        #expect(refreshAuth.record.id == "")
    }

    @Test func authResponseUsesTheDecodeHook() async throws {
        let client = makeClient()
        await installFetchMock(on: client, [
            RequestMock(
                method: "POST",
                url: "\(authBaseURL)/api/collections/users/auth-with-password",
                jsonBody: [
                    "token": "token_hook",
                    "record": ["id": "rec_hook", "collectionId": "users"]
                ]
            )
        ])

        let service = DecodeSpyService(client, collectionIdOrName: "users")
        let auth: RecordAuthResponse<RecordModel> = try await service.authWithPassword(
            usernameOrEmail: "user@example.com",
            password: "secret"
        )

        #expect(auth.token == "token_hook")
        #expect(auth.record.id == "rec_hook")
        #expect(service.decodedValues.count == 1)
        #expect(service.decodedValues.first?.dictionaryValue?["id"]?.stringValue == "rec_hook")
    }

    // MARK: - confirmVerification

    @Test func confirmVerificationSkipsSaveWhenAlreadyVerified() async throws {
        let store = SaveSpyStore()
        let client = makeClient(authStore: store)
        await installFetchMock(on: client, [
            RequestMock(
                method: "POST",
                url: "\(authBaseURL)/api/collections/users/confirm-verification",
                replyCode: 204
            )
        ])

        let record = RecordModel(
            id: "rec1",
            collectionId: "users",
            collectionName: "users",
            rawFields: ["verified": AnyCodable(true)]
        )
        store.save(token: "token", record: record)
        let baseline = store.saveCount

        let service: RecordService<RecordModel> = client.collection("users")
        let token = dummyJWT(payload: ["id": "rec1", "collectionId": "users"])
        _ = try await service.confirmVerification(verificationToken: token)

        #expect(store.saveCount == baseline)
        #expect(store.record?.rawFields["verified"]?.boolValue == true)
    }

    @Test func confirmVerificationMarksRecordVerified() async throws {
        let store = SaveSpyStore()
        let client = makeClient(authStore: store)
        await installFetchMock(on: client, [
            RequestMock(
                method: "POST",
                url: "\(authBaseURL)/api/collections/users/confirm-verification",
                replyCode: 204
            )
        ])

        let record = RecordModel(id: "rec1", collectionId: "users", collectionName: "users")
        store.save(token: "token", record: record)
        let baseline = store.saveCount

        let service: RecordService<RecordModel> = client.collection("users")
        let token = dummyJWT(payload: ["id": "rec1", "collectionId": "users"])
        _ = try await service.confirmVerification(verificationToken: token)

        #expect(store.saveCount == baseline + 1)
        #expect(store.record?.rawFields["verified"]?.boolValue == true)
    }

    // MARK: - update auth store merge

    @Test func updateMergesAuthStoreRecordWithPartialResponse() async throws {
        let store = SaveSpyStore()
        let client = makeClient(authStore: store)
        await installFetchMock(on: client, [
            RequestMock(
                method: "PATCH",
                url: "\(authBaseURL)/api/collections/users/records/rec1",
                jsonBody: [
                    "id": "rec1",
                    "collectionId": "users",
                    "collectionName": "users",
                    "name": "New Name"
                ]
            )
        ])

        let current = RecordModel(
            id: "rec1",
            collectionId: "users",
            collectionName: "users",
            rawFields: [
                "email": AnyCodable("user@example.com"),
                "verified": AnyCodable(true),
                "name": AnyCodable("Old Name")
            ]
        )
        store.save(token: "token", record: current)

        let service: RecordService<RecordModel> = client.collection("users")
        let updated: RecordModel = try await service.update(
            id: "rec1",
            bodyParams: .json(["name": AnyCodable("New Name")])
        )

        #expect(updated["name"]?.stringValue == "New Name")

        let stored = try #require(store.record)
        #expect(stored["name"]?.stringValue == "New Name")
        #expect(stored["email"]?.stringValue == "user@example.com")
        #expect(stored["verified"]?.boolValue == true)
    }

    // MARK: - impersonate

    @Test func impersonateUsesTheDecodeHook() async throws {
        let client = makeClient()
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(
            method: "POST",
            url: "\(authBaseURL)/api/collections/users/impersonate/rec1",
            jsonBody: [
                "token": "imp-token",
                "record": ["id": "rec1", "collectionId": "users", "email": "imp@example.com"]
            ]
        ))
        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()

        let service = DecodeSpyService(client, collectionIdOrName: "users")
        let impersonated = try await service.impersonate(recordId: "rec1", duration: 300, options: options)

        #expect(impersonated.authStore.token == "imp-token")
        #expect(impersonated.authStore.record?.id == "rec1")
        #expect(impersonated.authStore.record?["email"]?.stringValue == "imp@example.com")
        #expect(service.decodedValues.count == 1)
    }

    @Test func impersonateAppliesResponseDefaults() async throws {
        let client = makeClient()
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(
            method: "POST",
            url: "\(authBaseURL)/api/collections/users/impersonate/rec1",
            jsonBody: [String: Any]()
        ))
        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()

        let service: RecordService<RecordModel> = client.collection("users")
        let impersonated = try await service.impersonate(recordId: "rec1", duration: 60, options: options)

        #expect(impersonated.authStore.token == "")
        #expect(impersonated.authStore.record?.id == "")
    }
}
