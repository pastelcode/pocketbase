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

    @Test func testCookieExportAndLoad() {
        let store = BaseAuthStore()
        let record = RecordModel(id: "rec3", collectionId: "col1", collectionName: "users")
        let token = dummyJWT(payload: ["id": "rec3", "type": "auth", "exp": Date().timeIntervalSince1970 + 3600])

        store.save(token: token, record: record)
        let cookieStr = store.exportToCookie()
        #expect(cookieStr.contains("pb_auth="))

        let store2 = BaseAuthStore()
        store2.loadFromCookie(cookieStr)
        #expect(store2.token == token)
        #expect(store2.record?.id == "rec3")
    }

    @Test func testLocalAuthStore() {
        let store = LocalAuthStore(storageKey: "test_local_auth_\(UUID().uuidString)")
        let record = RecordModel(id: "local1", collectionId: "col1", collectionName: "users")
        store.save(token: "local_token", record: record)

        #expect(store.token == "local_token")
        #expect(store.record?.id == "local1")

        store.clear()
        #expect(store.token == "")
        #expect(store.record == nil)
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
        #expect(cleared == "CLEARED")
    }
}

actor TestSaveActor {
    var payload: String = ""
    func setSavePayload(_ p: String) { self.payload = p }
    func getPayload() -> String { return payload }
}
