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

    @Test func testCollectionCacheIsScopedToModelType() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")

        let untyped = client.collection("posts")
        let typed: RecordService<CustomPost> = client.collection("posts")
        let untypedAgain = client.collection("posts")
        let typedAgain: RecordService<CustomPost> = client.collection("posts")

        #expect(untyped === untypedAgain)
        #expect(typed === typedAgain)
        #expect((untyped as AnyObject) !== (typed as AnyObject))
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
        #expect(result1 == "a > {:test1} && b = \"hello\"")

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
        #expect(filterFormatted.contains("t1=\"a'b'c'\""))
        #expect(filterFormatted.contains("t2=null"))
        #expect(filterFormatted.contains("t3=true"))
        #expect(filterFormatted.contains("t4=false"))
        #expect(filterFormatted.contains("t5=123"))
        #expect(filterFormatted.contains("t6=-123.45"))
        #expect(filterFormatted.contains("t7=\"2023-10-18 07:11:12.000Z\""))
    }

    @Test func testFilterPlaceholderChaining() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let raw = "a > {:test1} && b = {:test2} || c = {:test3}"

        let result = client.filter(raw, params: [
            "test1": "{:test2}",
            "test2": "{:test1}",
            "test3": "{:test3}"
        ])

        #expect(result == #"a > "{:test2}" && b = "{:test1}" || c = "{:test3}""#)
    }

    @Test func testFilterPlaceholdersWithRegexSpecialChars() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let raw = "a > {:test1} && b = {:test2} || c = {:test2}"

        let result = client.filter(raw, params: [
            "test0": "abc",
            "test2": "test$$"
        ])

        #expect(result == #"a > {:test1} && b = "test$$" || c = "test$$""#)
    }

    @Test func testFilterAllPlaceholderTypes() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let date = Date(timeIntervalSince1970: 1697613072) // 2023-10-18T07:11:12Z
        let params: [String: Any] = [
            "test1": "a'b'c'\"\n\\",
            "test2": NSNull(),
            "test3": true,
            "test4": false,
            "test5": 123,
            "test6": -123.45,
            "test7": 123.45,
            "test8": date,
            "test9": [1, 2, 3, "test'12\"3"] as [Any],
            "test10": ["a": "test'123"] as [String: Any]
        ]
        let raw = "test1={:test1} || test2={:test2} || test3={:test3} || test4={:test4} || test5={:test5} || test6={:test6} || test7={:test7} || test8={:test8} || test9={:test9} || test10={:test10}"
        let expected = #"test1="a'b'c'\"\n\\" || test2=null || test3=true || test4=false || test5=123 || test6=-123.45 || test7=123.45 || test8="2023-10-18 07:11:12.000Z" || test9="[1,2,3,\"test'12\\\"3\"]" || test10="{\"a\":\"test'123\"}""#

        #expect(client.filter(raw, params: params) == expected)
    }

    @Test func testFilterNumberFormatting() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let raw = "a={:a} && b={:b} && c={:c} && d={:d}"

        let result = client.filter(raw, params: [
            "a": 1.0,
            "b": 1e-6,
            "c": 1e16,
            "d": 1e21
        ])

        #expect(result == "a=1 && b=0.000001 && c=10000000000000000 && d=1000000000000000000000")
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

/// A custom record model used to verify the typed collection service cache.
private struct CustomPost: Codable, Sendable {
    var id: String
}
