import Testing
import Foundation
@testable import pocketbase

struct ClientTests {
    @Test func testConstructor() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: nil, lang: "fr-FR")
        #expect(client.baseURL == "http://127.0.0.1:8090")
        #expect(client.lang == "fr-FR")
        #expect(client.collections != nil)
        #expect(client.files != nil)
        #expect(client.logs != nil)
        #expect(client.settings != nil)
        #expect(client.realtime != nil)
        #expect(client.health != nil)
        #expect(client.backups != nil)
        #expect(client.crons != nil)
        #expect(client.sql != nil)
    }

    @Test func testCollectionInitialization() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let service1 = client.collection("posts")
        let service2 = client.collection("users")
        let service3 = client.collection("posts")

        #expect(service1.baseCrudPath == "/api/collections/posts/records")
        #expect(service2.baseCrudPath == "/api/collections/users/records")
        #expect(service1.collectionIdOrName == service3.collectionIdOrName)
    }

    @Test func testBuildURL() {
        let client1 = PocketBase(baseURL: "http://127.0.0.1:8090/")
        #expect(client1.buildURL(path: "test123") == "http://127.0.0.1:8090/test123")
        #expect(client1.buildURL(path: "/test123") == "http://127.0.0.1:8090/test123")

        let client2 = PocketBase(baseURL: "http://127.0.0.1:8090")
        #expect(client2.buildURL(path: "test123") == "http://127.0.0.1:8090/test123")
        #expect(client2.buildURL(path: "/test123") == "http://127.0.0.1:8090/test123")
    }

    @Test func testFilterExpression() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")

        let raw = "a > {:test1} && b = {:test2}"
        #expect(client.filter(raw) == raw)

        let result1 = client.filter(raw, params: ["test2": "hello"])
        #expect(result1 == "a > {:test1} && b = 'hello'")

        let date = Date(timeIntervalSince1970: 1697613072) // 2023-10-18T07:11:12Z
        let params: [String: Any] = [
            "test1": "a'b'c'",
            "test2": NSNull(),
            "test3": true,
            "test4": false,
            "test5": 123,
            "test6": -123.45,
            "test7": date
        ]

        let filterFormatted = client.filter("t1={:test1} && t2={:test2} && t3={:test3} && t4={:test4} && t5={:test5} && t6={:test6} && t7={:test7}", params: params)
        #expect(filterFormatted.contains("t1='a\\'b\\'c\\''"))
        #expect(filterFormatted.contains("t2=null"))
        #expect(filterFormatted.contains("t3=true"))
        #expect(filterFormatted.contains("t4=false"))
        #expect(filterFormatted.contains("t5=123"))
        #expect(filterFormatted.contains("t6=-123.45"))
    }

    @Test func testSendRequestsWithMock() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/test?q1=123",
            replyCode: 200,
            jsonBody: ["message": "ok"]
        ))

        var options = SendOptions()
        options.method = "GET"
        options.query["q1"] = AnyCodable(123)
        options.fetch = await fetchMock.customFetch()

        let resp: [String: AnyCodable] = try await client.send(path: "/api/test", options: options)
        #expect(resp["message"]?.value.string == "ok")
    }

    @Test func testBeforeAndAfterSendHooks() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/new",
            replyCode: 200,
            jsonBody: ["status": "hooked"],
            additionalMatcher: { req in
                return req.value(forHTTPHeaderField: "X-Custom") == "789"
            }
        ))

        client.beforeSend = { url, options in
            var opt = options
            opt.headers["X-Custom"] = "789"
            let newUrl = client.buildURL(path: "/api/new")
            return (newUrl, opt)
        }

        client.afterSend = { response, data, options in
            return data
        }

        var options = SendOptions()
        options.fetch = await fetchMock.customFetch()

        let result: [String: AnyCodable] = try await client.send(path: "/api/old", options: options)
        #expect(result["status"]?.value.string == "hooked")
    }
}
