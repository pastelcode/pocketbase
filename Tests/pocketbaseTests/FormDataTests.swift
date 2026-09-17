import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

/// Builds a request carrying the multipart encoding of the given fields.
private func multipartRequest(
    _ fields: [String: SendOptions.FormValue],
    boundary: String = "TestBoundary"
) -> URLRequest {
    let multipart = MultipartFormData(fields: fields, boundary: boundary)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/api/things")!)
    request.setValue(multipart.contentTypeHeader, forHTTPHeaderField: "Content-Type")
    request.httpBody = multipart.bodyData
    return request
}

/// Decodes every `@jsonPayload` part of a multipart body.
private func jsonPayloads(in parts: [MultipartPart]) throws -> [AnyCodable] {
    try parts
        .filter { $0.name == "@jsonPayload" }
        .map { try JSONDecoder().decode(AnyCodable.self, from: Data($0.value.utf8)) }
}

struct FormDataTests {
    @Test func jsonFieldsAreMergedThroughJSONPayload() throws {
        let request = multipartRequest([
            "title": .string("Hello"),
            "meta": .json(AnyCodable(["tags": ["a", "b"], "nested": ["k": 1]]))
        ])
        let parts = parseMultipartParts(of: request)

        #expect(parts.first { $0.name == "title" }?.value == "Hello")
        #expect(parts.first { $0.name == "meta" } == nil)

        let payloads = try jsonPayloads(in: parts)
        #expect(payloads.count == 1)
        let meta = payloads.first?.dictionaryValue?["meta"]
        #expect(meta?.dictionaryValue?["tags"]?.arrayValue?.map(\.stringValue) == ["a", "b"])
        #expect(meta?.dictionaryValue?["nested"]?.dictionaryValue?["k"]?.intValue == 1)
    }

    @Test func eachJSONFieldKeepsItsOwnPayloadPart() throws {
        let request = multipartRequest([
            "one": .json(AnyCodable(1)),
            "two": .json(AnyCodable(["a": true]))
        ])
        let payloads = try jsonPayloads(in: parseMultipartParts(of: request))
        #expect(payloads.count == 2)

        var merged: [String: AnyCodable] = [:]
        for payload in payloads {
            for (key, value) in payload.dictionaryValue ?? [:] {
                merged[key] = value
            }
        }
        #expect(merged["one"]?.intValue == 1)
        #expect(merged["two"]?.dictionaryValue?["a"]?.boolValue == true)
    }

    @Test func rawJSONPayloadIsAppendedVerbatim() throws {
        let request = multipartRequest([
            "@jsonPayload": .jsonPayload(AnyCodable(["requests": [["method": "POST"]]]))
        ])
        let payloads = try jsonPayloads(in: parseMultipartParts(of: request))

        #expect(payloads.count == 1)
        #expect(payloads.first?.dictionaryValue?["requests"]?.arrayValue?.count == 1)
        #expect(payloads.first?.dictionaryValue?["@jsonPayload"] == nil)
    }

    @Test func partNamesAndFilenamesAreEscaped() throws {
        let request = multipartRequest([
            "na\"me\r\n": .string("value"),
            "file": .file(FileParam(filename: "a\"b\r.txt", data: Data("A".utf8)))
        ])
        let parts = parseMultipartParts(of: request)

        #expect(parts.contains { $0.name == "na%22me%0D%0A" })
        #expect(parts.contains { $0.filename == "a%22b%0D.txt" })
    }

    @Test func stringValuesAreSentWithoutInference() throws {
        let request = multipartRequest([
            "count": .string("42"),
            "enabled": .string("true"),
            "disabled": .string("false"),
            "code": .string("007"),
            "empty": .string("")
        ])
        let parts = parseMultipartParts(of: request)
        #expect(parts.count == 5)

        func value(_ name: String) -> String? {
            parts.first { $0.name == name }?.value
        }
        #expect(value("count") == "42")
        #expect(value("enabled") == "true")
        #expect(value("disabled") == "false")
        #expect(value("code") == "007")
        #expect(value("empty") == "")
    }
}

/// Captures the last request passed to a custom fetch.
private final class FormDataRequestCapture: @unchecked Sendable {
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

struct FormDataBatchTests {
    /// Batch `.form` values keep their declared type instead of going through
    /// the reference SDK's FormData string round-trip (which would infer
    /// `"42"` and `"true"` as JSON number/boolean).
    @Test func batchFormValuesKeepTheirDeclaredTypes() async throws {
        let capture = FormDataRequestCapture()
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "count": .string("42"),
            "enabled": .string("true"),
            "views": .json(AnyCodable(3)),
            "attachments": .file(FileParam(filename: "a.txt", data: Data("A".utf8)))
        ]))

        var options = SendOptions()
        options.fetch = { request in
            capture.store(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("[]".utf8), response)
        }
        _ = try await batch.send(options: options)

        let request = try #require(capture.last)
        let payloadPart = try #require(parseMultipartParts(of: request).first { $0.name == "@jsonPayload" })
        let payload = try JSONDecoder().decode(AnyCodable.self, from: Data(payloadPart.value.utf8))
        let body = try #require(
            payload.dictionaryValue?["requests"]?
                .arrayValue?.first?
                .dictionaryValue?["body"]?
                .dictionaryValue
        )

        #expect(body["count"]?.stringValue == "42")
        #expect(body["enabled"]?.stringValue == "true")
        #expect(body["views"]?.intValue == 3)
    }

    /// A raw `@jsonPayload` form value is merged into the batch JSON body.
    @Test func batchRawJSONPayloadIsMergedIntoTheBody() async throws {
        let capture = FormDataRequestCapture()
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let batch = client.createBatch()

        batch.collection("posts").create(bodyParams: .form([
            "title": .string("Hello"),
            "@jsonPayload": .jsonPayload(AnyCodable(["views": 7]))
        ]))

        var options = SendOptions()
        options.fetch = { request in
            capture.store(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("[]".utf8), response)
        }
        _ = try await batch.send(options: options)

        let request = try #require(capture.last)
        let payloadPart = try #require(parseMultipartParts(of: request).first { $0.name == "@jsonPayload" })
        let payload = try JSONDecoder().decode(AnyCodable.self, from: Data(payloadPart.value.utf8))
        let body = try #require(
            payload.dictionaryValue?["requests"]?
                .arrayValue?.first?
                .dictionaryValue?["body"]?
                .dictionaryValue
        )

        #expect(body["title"]?.stringValue == "Hello")
        #expect(body["views"]?.intValue == 7)
    }
}
