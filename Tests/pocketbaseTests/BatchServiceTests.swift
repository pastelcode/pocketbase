import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

/// Captures every request passed to a custom fetch.
private final class BatchRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private func batchResponse(for request: URLRequest) -> (Data, URLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    let data = (try? JSONEncoder().encode([BatchRequestResult(status: 200, body: AnyCodable(["id": "1"]))]))
        ?? Data("[]".utf8)
    return (data, response)
}

struct BatchServiceTests {
    private func makeClient() -> PocketBase {
        PocketBase(baseURL: "http://127.0.0.1:8090")
    }

    private func makeOptions(_ capture: BatchRequestCapture) -> SendOptions {
        var options = SendOptions()
        options.fetch = { request in
            capture.store(request)
            return batchResponse(for: request)
        }
        return options
    }

    private func jsonPayload(of request: URLRequest?) throws -> AnyCodable {
        let request = try #require(request)
        let part = try #require(parseMultipartParts(of: request).first { $0.name == "@jsonPayload" })
        return try JSONDecoder().decode(AnyCodable.self, from: Data(part.value.utf8))
    }

    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func firstRequest(in payload: AnyCodable) throws -> [String: AnyCodable] {
        let requests = payload.dictionaryValue?["requests"]?.arrayValue
        return try #require(requests?.first?.dictionaryValue)
    }

    // MARK: - Wire format (fixtures generated from the JavaScript SDK)

    @Test func mixedArrayMatchesJSReferenceWireFormat() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "title": .string("Hello"),
            "attachments": .array([
                .string("keep"),
                .file(FileParam(filename: "a.txt", mimeType: "text/plain", data: Data("A".utf8))),
                .string("also"),
                .file(FileParam(filename: "b.txt", mimeType: "text/plain", data: Data("B".utf8)))
            ])
        ]))

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let expected = try decode(#"{"requests":[{"method":"POST","url":"/api/collections/posts/records","body":{"title":"Hello","attachments":["keep","also"]}}]}"#)
        #expect(payload == expected)

        let request = try #require(capture.requests.last)
        let fileParts = parseMultipartParts(of: request).filter { $0.name.hasPrefix("requests.0.") }
        #expect(fileParts.map(\.name) == ["requests.0.attachments+", "requests.0.attachments+"])
        #expect(fileParts.map(\.filename) == ["a.txt", "b.txt"])
        #expect(fileParts.map(\.value) == ["A", "B"])
        #expect(fileParts.allSatisfy { $0.contentType == "text/plain" })
    }

    @Test func fileOnlyArrayKeepsThePlainFieldName() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "attachments": .array([
                .file(FileParam(filename: "a.txt", data: Data("A".utf8))),
                .file(FileParam(filename: "b.txt", data: Data("B".utf8)))
            ])
        ]))

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let expected = try decode(#"{"requests":[{"method":"POST","url":"/api/collections/posts/records","body":{}}]}"#)
        #expect(payload == expected)

        let request = try #require(capture.requests.last)
        let fileParts = parseMultipartParts(of: request).filter { $0.name.hasPrefix("requests.0.") }
        #expect(fileParts.map(\.name) == ["requests.0.attachments", "requests.0.attachments"])
    }

    @Test func regularAndEmptyArraysStayInTheJSONBody() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "tags": .array([.string("a"), .json(AnyCodable(1))]),
            "empty": .array([])
        ]))

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let body = try #require(firstRequest(in: payload)["body"]?.dictionaryValue)
        #expect(body["tags"]?.arrayValue?.count == 2)
        #expect(body["tags"]?.arrayValue?.first?.stringValue == "a")
        #expect(body["tags"]?.arrayValue?.last?.intValue == 1)
        #expect(body["empty"]?.arrayValue?.isEmpty == true)

        let request = try #require(capture.requests.last)
        #expect(parseMultipartParts(of: request).allSatisfy { $0.name == "@jsonPayload" })
    }

    @Test func plusSuffixedKeysAreNotDoubled() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "attachments+": .array([
                .string("x"),
                .file(FileParam(filename: "a.txt", data: Data("A".utf8)))
            ])
        ]))

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let expected = try decode(#"{"requests":[{"method":"POST","url":"/api/collections/posts/records","body":{"attachments+":["x"]}}]}"#)
        #expect(payload == expected)

        let request = try #require(capture.requests.last)
        let fileParts = parseMultipartParts(of: request).filter { $0.name.hasPrefix("requests.0.") }
        #expect(fileParts.map(\.name) == ["requests.0.attachments+"])
    }

    @Test func requestsWithoutFieldsStillSerializeAnEmptyBodyAndHeaders() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        var deleteOptions = SendOptions()
        deleteOptions.headers["X-Test"] = "1"

        batch.collection("posts").upsert()
        batch.collection("posts").delete(id: "REC1", options: deleteOptions)

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let expected = try decode(#"{"requests":[{"method":"PUT","url":"/api/collections/posts/records","body":{}},{"method":"DELETE","url":"/api/collections/posts/records/REC1","headers":{"X-Test":"1"},"body":{}}]}"#)
        #expect(payload == expected)
    }

    @Test func queryAndShorthandsAreAppendedToTheRequestURL() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        var queueOptions = SendOptions()
        queueOptions.expand = "author"
        queueOptions.query["filter"] = AnyCodable("a=1")
        batch.collection("posts").create(bodyParams: .json(["title": AnyCodable("T")]), options: queueOptions)

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let url = try #require(firstRequest(in: payload)["url"]?.stringValue)
        #expect(url.hasPrefix("/api/collections/posts/records?"))
        #expect(url.contains("expand=author"))
        #expect(url.contains("filter=a%3D1"))
    }

    // MARK: - Body types and precedence

    @Test func optionsBodyTakesPrecedenceOverBodyParams() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        var queueOptions = SendOptions()
        queueOptions.body = .json(["from": AnyCodable("options")])
        batch.collection("posts").create(
            bodyParams: .json(["from": AnyCodable("bodyParams")]),
            options: queueOptions
        )

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let body = try #require(firstRequest(in: payload)["body"]?.dictionaryValue)
        #expect(body["from"]?.stringValue == "options")
    }

    @Test func rawJsonObjectsAreSupported() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .rawJson(AnyCodable(["title": "T"])))

        _ = try await batch.send(options: makeOptions(capture))

        let payload = try jsonPayload(of: capture.requests.last)
        let body = try #require(firstRequest(in: payload)["body"]?.dictionaryValue)
        #expect(body["title"]?.stringValue == "T")
    }

    @Test func dataBodiesAreRejectedBeforeSending() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()
        let options = makeOptions(capture)

        batch.collection("posts").create(bodyParams: .data(Data("{}".utf8)))

        await #expect(throws: BatchServiceError.unsupportedBody(
            index: 0,
            reason: "raw data bodies are not supported; use .json or .form instead"
        )) {
            _ = try await batch.send(options: options)
        }
        #expect(capture.requests.isEmpty)
    }

    @Test func nonObjectRawJsonIsRejectedWithItsIndex() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()
        let options = makeOptions(capture)

        batch.collection("posts").create(bodyParams: .json(["ok": AnyCodable(true)]))
        batch.collection("posts").create(bodyParams: .rawJson(AnyCodable([1, 2])))

        await #expect(throws: BatchServiceError.unsupportedBody(
            index: 1,
            reason: "rawJson must wrap a JSON object; use .json or .form instead"
        )) {
            _ = try await batch.send(options: options)
        }
        #expect(capture.requests.isEmpty)
    }

    // MARK: - Queue lifecycle

    @Test func sendReplaysTheQueueWithoutClearingIt() async throws {
        let capture = BatchRequestCapture()
        let client = makeClient()
        let batch = client.createBatch()
        let options = makeOptions(capture)

        batch.collection("posts").create(bodyParams: .json(["title": AnyCodable("P1")]))

        _ = try await batch.send(options: options)
        _ = try await batch.send(options: options)

        #expect(capture.requests.count == 2)
        let first = try jsonPayload(of: capture.requests.first)
        let second = try jsonPayload(of: capture.requests.last)
        #expect(first == second)
    }
}
