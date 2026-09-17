import Testing
import Foundation
@testable import pocketbase

struct AuthStoreTests {
    @Test func testBaseAuthStoreSaveAndClear() {
        let store = BaseAuthStore()
        #expect(store.token == "")
        #expect(store.record == nil)
        #expect(store.isValid == false)

        let record = RecordModel(id: "rec1", collectionId: "col1", collectionName: "users")
        let futureToken = dummyJWT(payload: ["id": "rec1", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600])

        store.save(token: futureToken, record: record)
        #expect(store.token == futureToken)
        #expect(store.record?.id == "rec1")
        #expect(store.isValid == true)
        #expect(store.isSuperuser == false)

        store.clear()
        #expect(store.token == "")
        #expect(store.record == nil)
        #expect(store.isValid == false)
    }

    @Test func testSuperuserCheck() {
        let store = BaseAuthStore()
        let superuserRecord = RecordModel(id: "admin1", collectionId: "pbc_3142635823", collectionName: "_superusers")
        let superuserToken = dummyJWT(payload: ["id": "admin1", "type": "auth", "collectionId": "pbc_3142635823", "exp": Date().timeIntervalSince1970 + 3600])

        store.save(token: superuserToken, record: superuserRecord)
        #expect(store.isSuperuser == true)
    }

    @Test func testOnChangeCallbacks() {
        let store = BaseAuthStore()
        var callbackToken = ""
        var callbackRecordId: String? = nil

        let unsub = store.onChange { token, record in
            callbackToken = token
            callbackRecordId = record?.id
        }

        let record = RecordModel(id: "rec2", collectionId: "col1", collectionName: "users")
        store.save(token: "test_token", record: record)

        #expect(callbackToken == "test_token")
        #expect(callbackRecordId == "rec2")

        unsub()
        store.save(token: "new_token", record: nil)
        #expect(callbackToken == "test_token")
    }

    @Test func testOnChangeFiresImmediately() {
        let store = BaseAuthStore()
        store.save(token: "existing", record: nil)

        var calls = 0
        var seenToken = ""
        _ = store.onChange(fireImmediately: true) { token, _ in
            calls += 1
            seenToken = token
        }

        #expect(calls == 1)
        #expect(seenToken == "existing")

        store.save(token: "updated", record: nil)
        #expect(calls == 2)
        #expect(seenToken == "updated")

        store.clear()
        #expect(calls == 3)
        #expect(seenToken == "")
    }

    @Test func testClearDoesNotGoThroughSave() {
        let store = CountingAuthStore()
        var saves = 0
        _ = store.onChange { token, _ in
            if !token.isEmpty { saves += 1 }
        }

        store.save(token: "token", record: nil)
        store.clear()

        #expect(store.triggerCount == 2)
        #expect(saves == 1)
    }

    @Test func testTriggerChangeIsOverridable() {
        let store = CountingAuthStore()
        var callbacks = 0
        _ = store.onChange { _, _ in callbacks += 1 }

        store.save(token: "token", record: nil)
        store.clear()

        #expect(store.triggerCount == 2)
        #expect(callbacks == 2)
    }

    @Test func testCookieExportAndLoad() throws {
        let store = BaseAuthStore()
        let record = RecordModel(id: "rec3", collectionId: "col1", collectionName: "users")
        let token = dummyJWT(payload: ["id": "rec3", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600])

        store.save(token: token, record: record)
        let cookieStr = try store.exportToCookie()
        #expect(cookieStr.contains("pb_auth="))

        let store2 = BaseAuthStore()
        store2.loadFromCookie(cookieStr)
        #expect(store2.token == token)
        #expect(store2.record?.id == "rec3")
    }

    @Test func testCookieRoundTripPreservesReservedCharacters() throws {
        let store = BaseAuthStore()
        let record = RecordModel(id: "rec4", collectionId: "col1", collectionName: "users")
        let token = "a&b=c+d;e'f\"g\u{00E9}"

        store.save(token: token, record: record)
        let cookieStr = try store.exportToCookie()

        let store2 = BaseAuthStore()
        store2.loadFromCookie(cookieStr)
        #expect(store2.token == token)
        #expect(store2.record?.id == "rec4")
    }

    @Test func testExportToCookieTrimsLargeRecords() throws {
        let store = BaseAuthStore()
        let record = RecordModel(
            id: "rec_trim",
            collectionId: "col_trim",
            collectionName: "users",
            rawFields: [
                "email": AnyCodable("test@example.com"),
                "verified": AnyCodable(true),
                "bio": AnyCodable(String(repeating: "a", count: 6000)),
            ]
        )
        let token = dummyJWT(payload: ["id": "rec_trim", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600])

        store.save(token: token, record: record)
        let cookie = try store.exportToCookie()

        #expect(cookie.utf8.count <= 4096)

        let restored = BaseAuthStore()
        restored.loadFromCookie(cookie)
        #expect(restored.token == token)
        #expect(restored.record?.id == "rec_trim")
        #expect(restored.record?.collectionId == "col_trim")
        #expect(restored.record?.collectionName == "users")
        #expect(restored.record?["email"]?.stringValue == "test@example.com")
        #expect(restored.record?["verified"]?.boolValue == true)
        #expect(restored.record?["bio"] == nil)
    }

    @Test func testLocalAuthStore() throws {
        let suite = makeTestSuite()
        defer { suite.cleanup() }
        let store = LocalAuthStore(storageKey: "test_local_auth", storage: suite.defaults)
        let record = RecordModel(id: "local1", collectionId: "col1", collectionName: "users")
        store.save(token: "local_token", record: record)

        #expect(store.token == "local_token")
        #expect(store.record?.id == "local1")

        store.clear()
        #expect(store.token == "")
        #expect(store.record == nil)
        #expect(suite.defaults.data(forKey: "test_local_auth") == nil)
    }

    @Test func testLocalAuthStoreIsLiveAcrossInstances() throws {
        let suite = makeTestSuite()
        defer { suite.cleanup() }

        let storeA = LocalAuthStore(storageKey: "auth", storage: suite.defaults)
        let storeB = LocalAuthStore(storageKey: "auth", storage: suite.defaults)

        let token = dummyJWT(payload: ["id": "live1", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600])
        let record = RecordModel(id: "live1", collectionId: "col1", collectionName: "users")
        storeA.save(token: token, record: record)

        #expect(storeB.token == token)
        #expect(storeB.record?.id == "live1")
        #expect(storeB.isValid)

        storeA.clear()
        #expect(storeB.token == "")
        #expect(storeB.record == nil)
        #expect(storeB.isValid == false)
    }

    @Test func testLocalAuthStoreOnChange() throws {
        let suite = makeTestSuite()
        defer { suite.cleanup() }
        let store = LocalAuthStore(storageKey: "auth", storage: suite.defaults)

        var calls = 0
        var seenToken = ""
        _ = store.onChange(fireImmediately: true) { token, _ in
            calls += 1
            seenToken = token
        }

        #expect(calls == 1)
        #expect(seenToken == "")

        store.save(token: "local")
        #expect(calls == 2)
        #expect(seenToken == "local")

        store.clear()
        #expect(calls == 3)
        #expect(seenToken == "")
    }

    @Test func testLocalAuthStoreCorruptedStorage() throws {
        let suite = makeTestSuite()
        defer { suite.cleanup() }
        suite.defaults.set(Data("not-json".utf8), forKey: "auth")

        let store = LocalAuthStore(storageKey: "auth", storage: suite.defaults)
        #expect(store.token == "")
        #expect(store.record == nil)
        #expect(store.isValid == false)
    }

    @Test func testLocalAuthStoreLegacyModelKey() throws {
        let suite = makeTestSuite()
        defer { suite.cleanup() }
        let payload: [String: Any] = [
            "token": "legacy_token",
            "model": ["id": "legacy1", "collectionId": "col1", "collectionName": "users"],
        ]
        suite.defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "auth")

        let store = LocalAuthStore(storageKey: "auth", storage: suite.defaults)
        #expect(store.token == "legacy_token")
        #expect(store.record?.id == "legacy1")
    }

    @Test func testAsyncAuthStore() async throws {
        let actor = TestSaveActor()
        let store = AsyncAuthStore(
            save: { payload in
                await actor.setSavePayload(payload)
            },
            clear: {
                await actor.setSavePayload("CLEARED")
            }
        )

        let record = RecordModel(id: "async1", collectionId: "col1", collectionName: "users")
        store.save(token: "async_token", record: record)

        // The store persists asynchronously, so poll rather than assuming a
        // fixed scheduling delay (under parallel test load it can take longer).
        var saved = ""
        for _ in 0..<1000 {
            saved = await actor.getPayload()
            if saved.contains("async_token") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(saved.contains("async_token"))

        store.clear()

        var cleared = ""
        for _ in 0..<1000 {
            cleared = await actor.getPayload()
            if cleared == "CLEARED" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(cleared == "CLEARED", "unexpected payload: \(cleared.prefix(80))")
    }

    @Test func testAsyncAuthStoreInitialIsPersisted() async throws {
        let recorder = AuthStoreOpRecorder()
        let store = AsyncAuthStore(
            save: { payload in await recorder.recordSave(payload) },
            initial: #"{"token": "test", "record": {"id": "id1", "collectionId": "col1", "collectionName": "users"}}"#
        )

        #expect(await waitUntil { await recorder.saves().count >= 1 })

        let saves = await recorder.saves()
        #expect(saves.count == 1)
        let parsed = try JSONSerialization.jsonObject(with: Data(saves[0].utf8)) as? [String: Any]
        #expect(parsed?["token"] as? String == "test")

        #expect(store.token == "test")
        #expect(store.record?.id == "id1")
    }

    @Test func testAsyncAuthStoreInitialLoader() async throws {
        let recorder = AuthStoreOpRecorder()
        let store = AsyncAuthStore(
            save: { payload in await recorder.recordSave(payload) },
            initialLoader: {
                try await Task.sleep(nanoseconds: 10_000_000)
                return #"{"token": "loaded", "record": {"id": "loaded1"}}"#
            }
        )

        let loaded = await waitUntil { await recorder.saves().count >= 1 }
        #expect(loaded)
        #expect(store.token == "loaded")
        #expect(store.record?.id == "loaded1")
    }

    @Test func testAsyncAuthStoreInitialLoaderErrorLeavesStoreEmpty() async throws {
        let recorder = AuthStoreOpRecorder()
        let store = AsyncAuthStore(
            save: { payload in await recorder.recordSave(payload) },
            initialLoader: {
                throw TestAuthStoreError.loadFailed
            }
        )

        store.save(token: "after-error", record: nil)
        let done = await waitUntil { await recorder.saves().count >= 1 }
        #expect(done)

        let saves = await recorder.saves()
        #expect(saves.count == 1)
        #expect(saves[0].contains("after-error"))
    }

    @Test func testAsyncAuthStoreClearEnqueuesOnlyClear() async throws {
        let recorder = AuthStoreOpRecorder()
        let store = AsyncAuthStore(
            save: { payload in await recorder.recordSave(payload) },
            clear: { await recorder.recordClear("cleared") }
        )

        store.save(token: "t1", record: nil)
        store.clear()

        let done = await waitUntil { await recorder.clears().count == 1 }
        #expect(done)

        let saves = await recorder.saves()
        #expect(saves.count == 1)
        #expect(!saves.contains(""))
        #expect(!saves.contains(where: { $0.isEmpty }))
    }

    @Test func testAsyncAuthStoreSaveErrorDoesNotBreakQueue() async throws {
        let recorder = AuthStoreOpRecorder()
        let store = AsyncAuthStore(
            save: { payload in
                let count = await recorder.recordSave(payload)
                if count == 1 {
                    throw TestAuthStoreError.saveFailed
                }
            }
        )

        store.save(token: "first", record: nil)
        store.save(token: "second", record: nil)

        let done = await waitUntil { await recorder.saves().count >= 2 }
        #expect(done)

        let saves = await recorder.saves()
        #expect(saves.count == 2)
        #expect(saves[1].contains("second"))
    }
}

/// A base store that counts how often ``BaseAuthStore/triggerChange()`` runs.
final class CountingAuthStore: BaseAuthStore, @unchecked Sendable {
    private let countLock = NSLock()
    private var _triggerCount = 0

    var triggerCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return _triggerCount
    }

    override func triggerChange() {
        countLock.lock()
        _triggerCount += 1
        countLock.unlock()

        super.triggerChange()
    }
}

enum TestAuthStoreError: Error {
    case saveFailed
    case loadFailed
}

actor AuthStoreOpRecorder {
    private var saveCalls: [String] = []
    private var clearCalls: [String] = []

    @discardableResult
    func recordSave(_ payload: String) -> Int {
        saveCalls.append(payload)
        return saveCalls.count
    }

    func recordClear(_ value: String) {
        clearCalls.append(value)
    }

    func saves() -> [String] { saveCalls }
    func clears() -> [String] { clearCalls }
}

/// A `UserDefaults` suite isolated from the standard defaults.
struct TestUserDefaultsSuite {
    let name: String
    let defaults: UserDefaults

    func cleanup() {
        defaults.removePersistentDomain(forName: name)
    }
}

@discardableResult
func makeTestSuite() -> TestUserDefaultsSuite {
    let name = "test_pocketbase_auth_\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("Failed to create the test UserDefaults suite")
    }
    return TestUserDefaultsSuite(name: name, defaults: defaults)
}

/// Polls `condition` until it is `true` or `timeout` elapses.
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

actor TestSaveActor {
    var payload: String = ""
    func setSavePayload(_ p: String) { self.payload = p }
    func getPayload() -> String { return payload }
}
