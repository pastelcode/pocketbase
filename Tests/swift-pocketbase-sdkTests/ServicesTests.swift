import Testing
import Foundation
@testable import swift_pocketbase_sdk

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
}
