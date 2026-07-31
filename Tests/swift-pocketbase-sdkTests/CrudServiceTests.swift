import Testing
import Foundation
@testable import swift_pocketbase_sdk

struct CrudServiceTests {
    @Test func testCrudOperations() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let service: RecordService<RecordModel> = client.collection("posts")
        let fetchMock = FetchMock()

        // Mock getList
        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/collections/posts/records?page=1&perPage=2",
            replyCode: 200,
            jsonBody: [
                "page": 1,
                "perPage": 2,
                "totalItems": 3,
                "totalPages": 2,
                "items": [
                    ["id": "p1", "collectionId": "col1", "collectionName": "posts", "title": "Post 1"],
                    ["id": "p2", "collectionId": "col1", "collectionName": "posts", "title": "Post 2"]
                ]
            ]
        ))

        // Mock getOne
        await fetchMock.on(RequestMock(
            method: "GET",
            url: "http://127.0.0.1:8090/api/collections/posts/records/p1",
            replyCode: 200,
            jsonBody: ["id": "p1", "collectionId": "col1", "collectionName": "posts", "title": "Post 1"]
        ))

        // Mock create
        await fetchMock.on(RequestMock(
            method: "POST",
            url: "http://127.0.0.1:8090/api/collections/posts/records",
            replyCode: 200,
            jsonBody: ["id": "p3", "collectionId": "col1", "collectionName": "posts", "title": "Post 3"]
        ))

        // Mock update
        await fetchMock.on(RequestMock(
            method: "PATCH",
            url: "http://127.0.0.1:8090/api/collections/posts/records/p1",
            replyCode: 200,
            jsonBody: ["id": "p1", "collectionId": "col1", "collectionName": "posts", "title": "Updated Title"]
        ))

        // Mock delete
        await fetchMock.on(RequestMock(
            method: "DELETE",
            url: "http://127.0.0.1:8090/api/collections/posts/records/p1",
            replyCode: 204
        ))

        let customFetch = await fetchMock.customFetch()
        var opt = SendOptions()
        opt.fetch = customFetch

        // Test getList
        let list: ListResult<RecordModel> = try await service.getList(page: 1, perPage: 2, options: opt)
        #expect(list.items.count == 2)
        #expect(list.items[0].id == "p1")

        // Test getOne
        let one: RecordModel = try await service.getOne(id: "p1", options: opt)
        #expect(one.id == "p1")
        #expect(one["title"]?.value.string == "Post 1")

        // Test create
        let created: RecordModel = try await service.create(bodyParams: .json(["title": AnyCodable("Post 3")]), options: opt)
        #expect(created.id == "p3")

        // Test update
        let updated: RecordModel = try await service.update(id: "p1", bodyParams: .json(["title": AnyCodable("Updated Title")]), options: opt)
        #expect(updated["title"]?.value.string == "Updated Title")

        // Test delete
        let deleted = try await service.delete(id: "p1", options: opt)
        #expect(deleted == true)
    }

    @Test func testGetOneEmptyIdThrows404() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let service: RecordService<RecordModel> = client.collection("posts")

        do {
            let _: RecordModel = try await service.getOne(id: "")
            #expect(Bool(false), "Should have thrown 404 error")
        } catch let err as ClientResponseError {
            #expect(err.status == 404)
            #expect(err.message.contains("Missing required record id"))
        }
    }
}
