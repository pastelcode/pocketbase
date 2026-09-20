import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

struct ServicesTests {
    @Test func testFileServiceGetURL() {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let record = RecordModel(id: "rec456", collectionId: "col123", collectionName: "posts")

        let url = client.files.getURL(record: record, filename: "test.png")
        #expect(url == "http://127.0.0.1:8090/api/files/col123/rec456/test.png")

        let urlWithQuery = client.files.getURL(record: record, filename: "test.png", queryParams: ["thumb": AnyCodable("100x100")])
        #expect(urlWithQuery.contains("thumb=100x100"))
    }

    @Test func testHealthService() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/health",
            replyCode: 200,
            jsonBody: ["code": 200, "message": "API is healthy.", "data": [String: AnyCodable]()]
        ))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let health = try await client.health.check(options: opt)
        #expect(health.code == 200)
        #expect(health.message == "API is healthy.")
    }

    @Test func testBatchService() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "POST",
            url: "http://127.0.0.1:8090/api/batch",
            replyCode: 200,
            jsonBody: [
                ["status": 200, "body": ["id": "1"]],
                ["status": 200, "body": ["id": "2"]]
            ]
        ))

        let batch = client.createBatch()
        batch.collection("posts").create(bodyParams: .json(["title": AnyCodable("P1")]))
        batch.collection("posts").update(id: "2", bodyParams: .json(["title": AnyCodable("P2")]))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let results = try await batch.send(options: opt)
        #expect(results.count == 2)
        #expect(results[0].status == 200)
    }

    @Test func testCronService() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/crons",
            replyCode: 200,
            jsonBody: [["id": "job1", "expression": "* * * * *"]]
        ))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let jobs = try await client.crons.getFullList(options: opt)
        #expect(jobs.count == 1)
        #expect(jobs[0].id == "job1")
    }

    @Test func testSQLService() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "POST",
            url: "http://127.0.0.1:8090/api/sql",
            replyCode: 200,
            jsonBody: [
                "execTime": 0.005,
                "affectedRows": 1,
                "columns": [["name": "id", "type": "TEXT", "nullable": false]],
                "rows": [["1"]]
            ]
        ))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let sqlResult = try await client.sql.run(query: "SELECT 1;", options: opt)
        #expect(sqlResult.affectedRows == 1)
        #expect(sqlResult.columns.first?.name == "id")
    }

    @Test func testLogServiceTruncate() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "DELETE",
            url: "http://127.0.0.1:8090/api/logs",
            replyCode: 204
        ))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let result = try await client.logs.truncate(options: opt)
        #expect(result == true)
    }

    @Test func testCollectionImport() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetchMock = FetchMock()

        await fetchMock.on(RequestMock(
            method: "PUT",
            url: "http://127.0.0.1:8090/api/collections/import",
            replyCode: 204
        ))

        var opt = SendOptions()
        opt.fetch = await fetchMock.customFetch()

        let collection = CollectionModel(id: "c1", name: "posts", type: "base")
        let result = try await client.collections.import([collection], deleteMissing: true, options: opt)
        #expect(result == true)
    }

    @Test func testCollectionImportPreservesUnknownFieldOptions() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = ImportRequestCapture()

        let collection: CollectionModel = try JSONDecoder().decode(CollectionModel.self, from: Data(#"""
        {
            "id":"c1","name":"posts","type":"base","system":false,
            "created":"2026-01-01 00:00:00.000Z","updated":"2026-01-02 00:00:00.000Z",
            "fields":[{
                "id":"f1","name":"tags","type":"select","system":false,"required":true,
                "hidden":false,"presentable":false,"maxSelect":3,"values":["a","b"]
            }],
            "indexes":["CREATE INDEX idx ON posts (name)"]
        }
        """#.utf8))

        var opt = SendOptions()
        opt.fetch = { request in
            capture.store(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), response)
        }

        _ = try await client.collections.import([collection], deleteMissing: true, options: opt)

        let request = try #require(capture.last)
        let body = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["deleteMissing"] as? Bool == true)

        let collections = try #require(payload["collections"] as? [[String: Any]])
        let sent = try #require(collections.first)
        #expect(sent["created"] as? String == "2026-01-01 00:00:00.000Z")
        #expect(sent["updated"] as? String == "2026-01-02 00:00:00.000Z")

        let fields = try #require(sent["fields"] as? [[String: Any]])
        let field = try #require(fields.first)
        #expect(field["required"] as? Bool == true)
        #expect(field["maxSelect"] as? Int == 3)
        #expect(field["values"] as? [String] == ["a", "b"])
    }
}

/// Captures the last request passed to a custom fetch.
private final class ImportRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }

    func store(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}
