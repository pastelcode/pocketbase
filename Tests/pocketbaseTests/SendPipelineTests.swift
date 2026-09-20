import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

/// A stand-in error used to verify wrapping behavior.
private struct PipelineBoom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _request
    }

    func store(_ request: URLRequest) {
        lock.lock()
        _request = request
        lock.unlock()
    }
}

private func httpResponse(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    return HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

struct SendPipelineTests {
    @Test func transportErrorsAreWrapped() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { _ in throw PipelineBoom() }

        var options = SendOptions()
        options.fetch = fetch

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 0)
            #expect(error.originalError is PipelineBoom)
            #expect(error.originalErrorDescription == "boom")
            #expect(!error.isAbort)
        }
    }

    @Test func cancellationErrorsAreMarkedAborted() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")

        let cancelled: CustomFetch = { _ in throw CancellationError() }
        var options = SendOptions()
        options.fetch = cancelled
        do {
            _ = try await client.sendRaw(path: "/api/a", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }

        let urlCancelled: CustomFetch = { _ in throw URLError(.cancelled) }
        options.fetch = urlCancelled
        do {
            _ = try await client.sendRaw(path: "/api/b", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
    }

    @Test func emptyBodyIsTreatedAsEmptyJSONObject() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data(), httpResponse(for: request, status: 204)) }

        var options = SendOptions()
        options.fetch = fetch

        let decoded: [String: AnyCodable] = try await client.send(path: "/api/things", options: options)
        #expect(decoded.isEmpty)

        let raw = try await client.sendRaw(path: "/api/things", options: options)
        #expect(raw.isEmpty)
    }

    @Test func contentTypeDefaultsToJSONWithoutBody() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch

        _ = try await client.sendRaw(path: "/api/things", options: options)
        #expect(capture.last?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func explicitContentTypeIsPreserved() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.headers["Content-Type"] = "application/vnd.api+json"

        _ = try await client.sendRaw(path: "/api/things", options: options)
        #expect(capture.last?.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    }

    @Test func formBodyUsesMultipartContentType() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.body = .form([
            "file": .file(FileParam(filename: "a.txt", data: Data("hi".utf8)))
        ])

        _ = try await client.sendRaw(path: "/api/things", options: options)
        let header = capture.last?.value(forHTTPHeaderField: "Content-Type")
        #expect(header?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func formExplicitContentTypeIsPreserved() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.headers["Content-Type"] = "multipart/form-data; boundary=custom"
        options.body = .form([
            "file": .file(FileParam(filename: "a.txt", data: Data("hi".utf8)))
        ])

        _ = try await client.sendRaw(path: "/api/things", options: options)
        #expect(capture.last?.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=custom")
    }

    @Test func formArrayAppendsRepeatedParts() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.body = .form([
            "tags": .array([.string("a"), .string("b")]),
            "attachments": .array([
                .file(FileParam(filename: "a.txt", data: Data("A".utf8))),
                .string("note")
            ])
        ])

        _ = try await client.sendRaw(path: "/api/things", options: options)

        let request = try #require(capture.last)
        let parts = parseMultipartParts(of: request)
        #expect(parts.filter { $0.name == "tags" }.map(\.value) == ["a", "b"])
        let attachmentParts = parts.filter { $0.name == "attachments" }
        #expect(attachmentParts.count == 2)
        #expect(attachmentParts.first?.filename == "a.txt")
    }

    @Test func beforeSendErrorsAreWrapped() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("{}".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        client.beforeSend = { _, _ in throw PipelineBoom() }

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 0)
            #expect(error.originalError is PipelineBoom)
            #expect(error.message == "Something went wrong.")
        }
    }

    @Test func beforeSendThrownClientResponseErrorPreservesMetadata() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("{}".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        client.beforeSend = { _, _ in
            throw ClientResponseError(
                url: "http://127.0.0.1:8090/custom",
                status: 418,
                response: ["message": AnyCodable("teapot")],
                isAbort: true,
                originalError: PipelineBoom()
            )
        }

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 418)
            #expect(error.url == "http://127.0.0.1:8090/custom")
            #expect(error.response["message"]?.value.string == "teapot")
            #expect(error.message == "teapot")
            #expect(error.isAbort)
            #expect(error.originalError is PipelineBoom)
        }
    }

    @Test func emptyFormCollectionsSerializeAsEmptyJSONArrays() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.body = .form([
            "tags": .array([]),
            "attachments": .files([])
        ])

        _ = try await client.sendRaw(path: "/api/things", options: options)

        let request = try #require(capture.last)
        let parts = parseMultipartParts(of: request)
        #expect(parts.allSatisfy { $0.name == "@jsonPayload" })

        var merged: [String: AnyCodable] = [:]
        for part in parts {
            let payload = try JSONDecoder().decode(AnyCodable.self, from: Data(part.value.utf8))
            for (key, value) in payload.dictionaryValue ?? [:] {
                merged[key] = value
            }
        }
        #expect(merged["tags"]?.arrayValue?.isEmpty == true)
        #expect(merged["attachments"]?.arrayValue?.isEmpty == true)
    }

    @Test func nonFiniteJSONValuesSerializeAsNull() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let capture = RequestCapture()
        let fetch: CustomFetch = { request in
            capture.store(request)
            return (Data("{}".utf8), httpResponse(for: request))
        }

        var options = SendOptions()
        options.fetch = fetch
        options.body = .form([
            "meta": .json(AnyCodable(["score": Double.nan, "ratio": Double.infinity]))
        ])

        _ = try await client.sendRaw(path: "/api/things", options: options)

        let request = try #require(capture.last)
        let part = try #require(parseMultipartParts(of: request).first { $0.name == "@jsonPayload" })
        let payload = try JSONDecoder().decode(AnyCodable.self, from: Data(part.value.utf8))
        let expected = try JSONDecoder().decode(AnyCodable.self, from: Data(#"{"meta":{"score":null,"ratio":null}}"#.utf8))
        #expect(payload == expected)
    }

    @Test func afterSendErrorsAreWrapped() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("{}".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        client.afterSend = { _, _, _ in throw PipelineBoom() }

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 0)
            #expect(error.originalError is PipelineBoom)
            #expect(error.message == "Something went wrong.")
        }
    }

    @Test func afterSendThrownClientResponseErrorPreservesMetadata() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("{}".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        client.afterSend = { _, _, _ in
            throw ClientResponseError(
                url: "http://127.0.0.1:8090/mapped",
                status: 400,
                response: ["message": AnyCodable("mapped error")]
            )
        }

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 400)
            #expect(error.url == "http://127.0.0.1:8090/mapped")
            #expect(error.response["message"]?.value.string == "mapped error")
            #expect(error.message == "mapped error")
        }
    }

    @Test func decodeErrorsReportFinalURL() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("not json".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        options.query = ["page": 1]
        client.beforeSend = { _, options in
            return (url: "http://127.0.0.1:8090/rewritten", options: options)
        }

        do {
            let _: RecordModel = try await client.send(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.originalError is DecodingError)
            #expect(error.url == "http://127.0.0.1:8090/rewritten?page=1")
        }
    }

    @Test func httpErrorWithNonObjectBodyCollapsesToEmptyResponse() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in
            (Data("[\"email is required\"]".utf8), httpResponse(for: request, status: 400))
        }

        var options = SendOptions()
        options.fetch = fetch

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 400)
            #expect(error.response.isEmpty)
            #expect(error.originalError == nil)
        }
    }

    @Test func httpErrorWithObjectBodyIsPreserved() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in
            (Data("{\"message\":\"nope\"}".utf8), httpResponse(for: request, status: 400))
        }

        var options = SendOptions()
        options.fetch = fetch

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.status == 400)
            #expect(error.response["message"]?.value.string == "nope")
            #expect(error.message == "nope")
        }
    }

    @Test func decodeFailuresAreWrapped() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("not json".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch

        do {
            let _: RecordModel = try await client.send(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.originalError is DecodingError)
        }
    }

    @Test func bodyEncodingErrorsAreWrapped() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let fetch: CustomFetch = { request in (Data("{}".utf8), httpResponse(for: request)) }

        var options = SendOptions()
        options.fetch = fetch
        options.body = .rawJson(AnyCodable(Double.nan))

        do {
            _ = try await client.sendRaw(path: "/api/things", options: options)
            #expect(Bool(false), "expected a ClientResponseError")
        } catch let error as ClientResponseError {
            #expect(error.originalError is EncodingError)
        }
    }
}
