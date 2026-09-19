import Testing
import Foundation
@testable import pocketbase

struct AutoRefreshTests {
    @Test func testAutoRefreshRefreshesExpiringToken() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let refreshCalls = CallCounter()
        let reauthCalls = CallCounter()

        let expiring = dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 10])
        client.authStore.save(token: expiring, record: RecordModel(id: "u1", collectionId: "c1", collectionName: "users"))

        AutoRefresh.registerAutoRefresh(
            client,
            threshold: 60,
            refreshFunc: {
                await refreshCalls.increment()
                client.authStore.save(
                    token: dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600]),
                    record: client.authStore.record
                )
            },
            reauthenticateFunc: { await reauthCalls.increment() }
        )

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)

        #expect(await refreshCalls.value == 1)
        #expect(await reauthCalls.value == 0)
    }

    @Test func testAutoRefreshFallsBackToReauthenticate() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let refreshCalls = CallCounter()
        let reauthCalls = CallCounter()

        let expiring = dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 10])
        client.authStore.save(token: expiring, record: RecordModel(id: "u1", collectionId: "c1", collectionName: "users"))

        AutoRefresh.registerAutoRefresh(
            client,
            threshold: 60,
            refreshFunc: {
                await refreshCalls.increment()
                throw TestAuthStoreError.saveFailed
            },
            reauthenticateFunc: {
                await reauthCalls.increment()
                client.authStore.save(
                    token: dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600]),
                    record: client.authStore.record
                )
            }
        )

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)

        #expect(await refreshCalls.value == 1)
        #expect(await reauthCalls.value == 1)
    }

    @Test func testAutoRefreshResetsOnStoreClear() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let refreshCalls = CallCounter()
        let reauthCalls = CallCounter()

        let expiring = dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 10])
        client.authStore.save(token: expiring, record: RecordModel(id: "u1", collectionId: "c1", collectionName: "users"))

        AutoRefresh.registerAutoRefresh(
            client,
            threshold: 60,
            refreshFunc: { await refreshCalls.increment() },
            reauthenticateFunc: { await reauthCalls.increment() }
        )

        client.authStore.clear()

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)

        #expect(await refreshCalls.value == 0)
        #expect(await reauthCalls.value == 0)
    }

    @Test func testAutoRefreshResetsOnRecordChange() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let refreshCalls = CallCounter()
        let reauthCalls = CallCounter()

        let expiring = dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 10])
        client.authStore.save(token: expiring, record: RecordModel(id: "u1", collectionId: "c1", collectionName: "users"))

        AutoRefresh.registerAutoRefresh(
            client,
            threshold: 60,
            refreshFunc: { await refreshCalls.increment() },
            reauthenticateFunc: { await reauthCalls.increment() }
        )

        // Authenticating a different record resets the hook.
        client.authStore.save(
            token: dummyJWT(payload: ["id": "u2", "type": "auth", "exp": Date().timeIntervalSince1970 + 10]),
            record: RecordModel(id: "u2", collectionId: "c1", collectionName: "users")
        )

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)

        #expect(await refreshCalls.value == 0)
        #expect(await reauthCalls.value == 0)
    }

    @Test func testAutoRefreshBypass() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let refreshCalls = CallCounter()
        let reauthCalls = CallCounter()

        let expiring = dummyJWT(payload: ["id": "u1", "type": "auth", "exp": Date().timeIntervalSince1970 + 10])
        client.authStore.save(token: expiring, record: RecordModel(id: "u1", collectionId: "c1", collectionName: "users"))

        AutoRefresh.registerAutoRefresh(
            client,
            threshold: 60,
            refreshFunc: { await refreshCalls.increment() },
            reauthenticateFunc: { await reauthCalls.increment() }
        )

        var typed = SendOptions()
        typed.autoRefresh = true
        typed.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: typed)

        var query = SendOptions()
        query.query["autoRefresh"] = AnyCodable(true)
        query.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: query)

        #expect(await refreshCalls.value == 0)
        #expect(await reauthCalls.value == 0)
    }

    @Test func testResetRestoresPreviousBeforeSend() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(method: "GET", jsonBody: ["ok": true]))

        let originalCalls = CallCounter()
        client.beforeSend = { url, options in
            await originalCalls.increment()
            return (url, options)
        }

        AutoRefresh.registerAutoRefresh(client, threshold: 60, refreshFunc: {}, reauthenticateFunc: {})
        AutoRefresh.resetAutoRefresh(client)

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()
        let _: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)

        #expect(await originalCalls.value == 1)
    }

    @Test func testAutoRefreshDoesNotRetainClient() async throws {
        var client: PocketBase? = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: BaseAuthStore())
        weak var weakClient = client

        AutoRefresh.registerAutoRefresh(client!, threshold: 60, refreshFunc: {}, reauthenticateFunc: {})
        client = nil

        #expect(weakClient == nil)
    }
}

actor CallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int { count }
}
