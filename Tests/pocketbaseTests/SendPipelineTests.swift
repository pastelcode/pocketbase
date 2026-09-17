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
            #expect(error.originalError is PipelineBoom)
            #expect(error.message.contains("afterSend"))
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
