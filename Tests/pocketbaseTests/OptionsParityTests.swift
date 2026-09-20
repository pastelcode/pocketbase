import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    private var _methods: [String] = []
    private var _bodies: [Data?] = []

    var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
    var lastURL: String? { urls.last }
    var callCount: Int { urls.count }

    var lastMethod: String? {
        lock.lock(); defer { lock.unlock() }
        return _methods.last
    }

    var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return _bodies.last ?? nil
    }

    func fetch(response: @escaping @Sendable (URLRequest) -> [String: Any]) -> CustomFetch {
        return { [self] request in
            record(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod,
                body: request.httpBody
            )
            let data = (try? JSONSerialization.data(withJSONObject: response(request))) ?? Data()
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, http)
        }
    }

    private func record(url: String, method: String?, body: Data?) {
        lock.lock()
        _urls.append(url)
        _methods.append(method ?? "")
        _bodies.append(body)
        lock.unlock()
    }
}

private func listResultJSON(
    page: Int = 1,
    perPage: Int = 30,
    items: [[String: Any]] = []
) -> [String: Any] {
    return [
        "page": page,
        "perPage": perPage,
        "totalItems": items.count,
        "totalPages": items.isEmpty ? 0 : 1,
        "items": items
    ]
}

private func recordJSON(id: String) -> [String: Any] {
    return ["id": id, "collectionId": "col1", "collectionName": "posts"]
}

struct OptionsParityTests {
    @Test func encodeURIComponentMatchesJavaScript() {
        #expect("a/b".encodeURIComponent() == "a%2Fb")
        #expect("a b".encodeURIComponent() == "a%20b")
        #expect("a&b=c".encodeURIComponent() == "a%26b%3Dc")
        #expect("a+b;c".encodeURIComponent() == "a%2Bb%3Bc")
        #expect("a?b#c".encodeURIComponent() == "a%3Fb%23c")
        #expect("safe-_.!~*'()".encodeURIComponent() == "safe-_.!~*'()")
        #expect("café".encodeURIComponent() == "caf%C3%A9")
    }

    @Test func serializeQueryParamsMatchesJavaScript() {
        let params: [String: AnyCodable] = [
            "a": AnyCodable("x/y"),
            "arr": AnyCodable([1, 2]),
            "flag": AnyCodable(true),
            "obj": AnyCodable(["k": "v"]),
            "skip": AnyCodable(nil),
            "when": AnyCodable(Date(timeIntervalSince1970: 0))
        ]

        // Keys are sorted for deterministic output (the URL order is not
        // significant to the server).
        let encoded = serializeQueryParams(params)
        #expect(encoded.contains("a=x%2Fy"))
        #expect(encoded.contains("arr=1&arr=2"))
        #expect(encoded.contains("flag=true"))
        #expect(encoded.contains("obj=%7B%22k%22%3A%22v%22%7D"))
        #expect(encoded.contains("when=1970-01-01%2000%3A00%3A00.000Z"))
        #expect(!encoded.contains("skip"))
    }

    @Test func serializeQueryParamsFormatsNumbersWithoutScientificNotation() {
        let params: [String: AnyCodable] = [
            "whole": AnyCodable(1.0),
            "negative": AnyCodable(-123.45),
            "small": AnyCodable(1e-6),
            "tiny": AnyCodable(1e-7),
            "large": AnyCodable(1e16),
            "huge": AnyCodable(1e21),
            "negZero": AnyCodable(-0.0),
            "nan": AnyCodable(Double.nan),
            "inf": AnyCodable(Double.infinity)
        ]

        let encoded = serializeQueryParams(params)
        #expect(encoded.contains("whole=1"))
        #expect(encoded.contains("negative=-123.45"))
        #expect(encoded.contains("small=0.000001"))
        #expect(encoded.contains("tiny=0.0000001"))
        #expect(encoded.contains("large=10000000000000000"))
        #expect(encoded.contains("huge=1000000000000000000000"))
        #expect(encoded.contains("negZero=0"))
        #expect(encoded.contains("nan=NaN"))
        #expect(encoded.contains("inf=Infinity"))
        #expect(!encoded.contains("e%2B"))
        #expect(!encoded.contains("1e-"))
    }

    @Test func typedShorthandsOverrideQuery() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in [:] }

        var options = SendOptions()
        options.fetch = fetch
        options.filter = "name = 'a'"
        options.sort = "-created"
        options.expand = "author"
        options.fields = "id,name"
        options.skipTotal = true
        options.query["filter"] = AnyCodable("ignored")

        _ = try await client.sendRaw(path: "/api/things", options: options)

        let url = try #require(recorder.lastURL)
        #expect(url.contains("filter=name%20%3D%20'a'"))
        #expect(url.contains("sort=-created"))
        #expect(url.contains("expand=author"))
        #expect(url.contains("fields=id%2Cname"))
        #expect(url.contains("skipTotal=true"))
        #expect(!url.contains("ignored"))
    }

    @Test func listQueryValuesOverrideServiceDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in listResultJSON(page: 3, perPage: 5) }

        var options = SendOptions()
        options.fetch = fetch
        options.query["page"] = AnyCodable(3)
        options.query["perPage"] = AnyCodable(5)

        let _: ListResult<RecordModel> = try await client.collection("posts")
            .getList(page: 1, perPage: 30, options: options)

        let url = try #require(recorder.lastURL)
        #expect(url.contains("page=3"))
        #expect(url.contains("perPage=5"))
        #expect(!url.contains("page=1"))
        #expect(!url.contains("perPage=30"))
    }

    @Test func serviceDefaultsApplyWhenUnset() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in listResultJSON(page: 2, perPage: 10) }

        var options = SendOptions()
        options.fetch = fetch

        let _: ListResult<RecordModel> = try await client.collection("posts")
            .getList(page: 2, perPage: 10, options: options)

        let url = try #require(recorder.lastURL)
        #expect(url.contains("page=2"))
        #expect(url.contains("perPage=10"))
    }

    @Test func callerBodyOverridesBodyParams() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in recordJSON(id: "r1") }

        var options = SendOptions()
        options.body = .json(["title": AnyCodable("caller")])
        options.fetch = fetch

        let _: RecordModel = try await client.collection("posts")
            .create(bodyParams: .json(["title": AnyCodable("param")]), options: options)

        let body = try #require(recorder.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("caller"))
        #expect(!json.contains("param"))
    }

    @Test func bodyParamsApplyWhenCallerBodyIsUnset() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in recordJSON(id: "r1") }

        var options = SendOptions()
        options.fetch = fetch

        let _: RecordModel = try await client.collection("posts")
            .create(bodyParams: .json(["title": AnyCodable("param")]), options: options)

        let body = try #require(recorder.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("param"))
    }

    @Test func callerMethodOverridesServiceDefault() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in listResultJSON() }

        let options = SendOptions(method: "POST", fetch: fetch)
        let _: ListResult<RecordModel> = try await client.collection("posts")
            .getList(page: 1, perPage: 30, options: options)

        #expect(recorder.lastMethod == "POST")
    }

    @Test func fullListUsesBatchFromOptionsAndDoesNotSendIt() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in listResultJSON(perPage: 2) }

        var options = SendOptions()
        options.batch = 2
        options.fetch = fetch

        let items: [RecordModel] = try await client.collection("posts").getFullList(options: options)

        #expect(items.isEmpty)
        #expect(recorder.callCount == 1)
        let url = try #require(recorder.lastURL)
        #expect(url.contains("perPage=2"))
        #expect(url.contains("skipTotal=1"))
        #expect(!url.contains("batch"))
    }

    @Test func idsAreEscapedLikeJavaScript() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in recordJSON(id: "a/b") }

        var options = SendOptions()
        options.fetch = fetch

        let _: RecordModel = try await client.collection("posts").getOne(id: "a/b", options: options)

        let url = try #require(recorder.lastURL)
        #expect(url.contains("a%2Fb"))
    }

    // MARK: - Admin service option precedence

    @Test func backupServiceCallerMethodAndBodyOverrideDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in [:] }

        var options = SendOptions(method: "PUT", fetch: fetch)
        options.body = .json(["name": AnyCodable("caller")])

        _ = try await client.backups.create(basename: "param", options: options)

        #expect(recorder.lastMethod == "PUT")
        let body = try #require(recorder.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("caller"))
        #expect(!json.contains("param"))
    }

    @Test func backupDownloadURLPercentEncodesReservedCharacters() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let url = client.backups.getDownloadURL(token: "tok/en?x&y=z+1", key: "back up/2026?x&y=z+1")

        #expect(url == "http://127.0.0.1:8090/api/backups/back%20up%2F2026%3Fx%26y%3Dz%2B1?token=tok%2Fen%3Fx%26y%3Dz%2B1")
    }

    @Test func settingsServiceCallerOptionsOverrideDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in ["secret": "generated"] }

        var options = SendOptions(method: "PUT", fetch: fetch)
        options.query["test"] = AnyCodable("1")
        options.body = .json(["clientId": AnyCodable("caller")])

        let secret: AppleClientSecret = try await client.settings.generateAppleClientSecret(
            clientId: "param",
            teamId: "team",
            keyId: "key",
            privateKey: "pem",
            duration: 60,
            options: options
        )

        #expect(secret.secret == "generated")
        #expect(recorder.lastMethod == "PUT")
        let url = try #require(recorder.lastURL)
        #expect(url.contains("test=1"))
        let body = try #require(recorder.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("caller"))
        #expect(!json.contains("param"))
    }

    @Test func logServiceCallerOptionsOverrideDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in listResultJSON() }

        var options = SendOptions(method: "PUT", fetch: fetch)
        options.query["page"] = AnyCodable(7)
        options.query["perPage"] = AnyCodable(99)

        _ = try await client.logs.getList(page: 1, perPage: 30, options: options)

        #expect(recorder.lastMethod == "PUT")
        let url = try #require(recorder.lastURL)
        #expect(url.contains("page=7"))
        #expect(url.contains("perPage=99"))
        #expect(!url.contains("page=1"))
        #expect(!url.contains("perPage=30"))
    }

    @Test func logServiceTruncateCallerMethodOverridesDefault() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in [:] }

        let options = SendOptions(method: "GET", fetch: fetch)
        _ = try await client.logs.truncate(options: options)

        #expect(recorder.lastMethod == "GET")
    }

    @Test func cronServiceCallerOptionsOverrideDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in [:] }

        var options = SendOptions(method: "GET", fetch: fetch)
        options.query["custom"] = AnyCodable("x")

        _ = try await client.crons.run(jobId: "job/1", options: options)

        #expect(recorder.lastMethod == "GET")
        let url = try #require(recorder.lastURL)
        #expect(url.contains("job%2F1"))
        #expect(url.contains("custom=x"))
    }

    @Test func healthServiceCallerMethodOverridesDefault() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in ["code": 200, "message": "ok", "data": [String: Any]()] }

        let options = SendOptions(method: "POST", fetch: fetch)
        _ = try await client.health.check(options: options)

        #expect(recorder.lastMethod == "POST")
    }

    @Test func sqlServiceCallerMethodAndBodyOverrideDefaults() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let recorder = RequestRecorder()
        let fetch = recorder.fetch { _ in
            ["execTime": 0.1, "affectedRows": 0, "columns": [Any](), "rows": [Any]()]
        }

        var options = SendOptions(method: "GET", fetch: fetch)
        options.body = .json(["query": AnyCodable("SELECT caller")])

        _ = try await client.sql.run(query: "SELECT param", options: options)

        #expect(recorder.lastMethod == "GET")
        let body = try #require(recorder.lastBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("caller"))
        #expect(!json.contains("param"))
    }
}
