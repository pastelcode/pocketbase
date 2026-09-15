import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0
    private var _completed = 0

    var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return _completed }

    func recordStart() { lock.lock(); _started += 1; lock.unlock() }
    func recordComplete() { lock.lock(); _completed += 1; lock.unlock() }
}

private func waitUntil(timeout: Double = 3, _ condition: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func slowFetch(box: CancellationBox, nanoseconds: UInt64 = 500_000_000) -> CustomFetch {
    return { request in
        box.recordStart()
        try await Task.sleep(nanoseconds: nanoseconds)
        box.recordComplete()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data("ok".utf8), response)
    }
}

private func immediateFetch() -> CustomFetch {
    return { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data("ok".utf8), response)
    }
}

struct RequestCancellationTests {
    private func makeClient() -> PocketBase {
        PocketBase(baseURL: "http://127.0.0.1:8090")
    }

    @Test func sameKeyRequestCancelsPrevious() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box)

        let first = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 1 }

        // Same method + path derives the same cancellation key.
        let second = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 2 }

        _ = try await second.value

        do {
            _ = try await first.value
            #expect(Bool(false), "the superseded request should have been cancelled")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
    }

    @Test func cancelRequestOnlyCancelsMatchingKey() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var firstOptions = SendOptions()
        firstOptions.fetch = slowFetch(box: box)
        firstOptions.requestKey = "first"
        var secondOptions = SendOptions()
        secondOptions.fetch = slowFetch(box: box)
        secondOptions.requestKey = "second"

        let first = Task { try await client.sendRaw(path: "/api/a", options: firstOptions) }
        let second = Task { try await client.sendRaw(path: "/api/b", options: secondOptions) }
        await waitUntil { box.started == 2 }

        client.cancelRequest("first")

        do {
            _ = try await first.value
            #expect(Bool(false), "first should have been cancelled")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }

        _ = try await second.value
    }

    @Test func cancelAllRequestsCancelsEveryRequest() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var firstOptions = SendOptions()
        firstOptions.fetch = slowFetch(box: box)
        firstOptions.requestKey = "first"
        var secondOptions = SendOptions()
        secondOptions.fetch = slowFetch(box: box)
        secondOptions.requestKey = "second"

        let first = Task { try await client.sendRaw(path: "/api/a", options: firstOptions) }
        let second = Task { try await client.sendRaw(path: "/api/b", options: secondOptions) }
        await waitUntil { box.started == 2 }

        client.cancelAllRequests()

        for task in [first, second] {
            do {
                _ = try await task.value
                #expect(Bool(false), "request should have been cancelled")
            } catch let error as ClientResponseError {
                #expect(error.isAbort)
            }
        }
    }

    @Test func globalAutoCancellationCanBeDisabled() async throws {
        let client = makeClient().autoCancellation(false)
        let box = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box, nanoseconds: 200_000_000)

        let first = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 1 }
        let second = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 2 }

        _ = try await first.value
        _ = try await second.value
        #expect(box.completed == 2)
    }

    @Test func perRequestAutoCancelDisablesCancellation() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box, nanoseconds: 200_000_000)
        options.autoCancel = false

        let first = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 1 }
        let second = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 2 }

        _ = try await first.value
        _ = try await second.value
        #expect(box.completed == 2)
    }

    @Test func callerTaskCancellationReportsAbort() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box)

        let request = Task { try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 1 }

        request.cancel()

        do {
            _ = try await request.value
            #expect(Bool(false), "request should have been cancelled")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
    }

    @Test func registryIsCleanedUpAfterCompletion() async throws {
        let client = makeClient()
        var options = SendOptions()
        options.fetch = immediateFetch()

        _ = try await client.sendRaw(path: "/api/things", options: options)
        #expect(client.pendingRequestCount == 0)
    }
}
