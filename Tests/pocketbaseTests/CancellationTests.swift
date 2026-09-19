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

    @Test func cancelRequestDuringSlowHookCancelsPendingRequest() async throws {
        let client = makeClient()
        let box = CancellationBox()
        let hookBox = CancellationBox()
        let gate = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box)
        options.requestKey = "hook"
        client.beforeSend = { url, sendOptions in
            hookBox.recordStart()
            // Hold the hook open until the test has cancelled the request.
            await waitUntil { gate.started == 1 }
            return (url, sendOptions)
        }

        let request = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { hookBox.started == 1 }

        // The handle must be registered before the hook finishes; otherwise
        // `cancelRequest` is a no-op, the hook returns, and the request reaches
        // the fetch and succeeds.
        client.cancelRequest("hook")
        gate.recordStart()

        do {
            _ = try await request.value
            #expect(Bool(false), "the request should have been cancelled during its hook")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
    }

    @Test func sameKeyRequestSupersedesEarlierWhileItsHookIsSuspended() async throws {
        let client = makeClient()
        let fetchBox = CancellationBox()
        let hookBox = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: fetchBox)
        options.requestKey = "hook"
        client.beforeSend = { url, sendOptions in
            hookBox.recordStart()
            // The first (older) request holds its hook until the newer request
            // has entered its own, so the older one finishes its hook last.
            // Without pre-hook registration the older request would then
            // supersede the newer one (the inverted ordering from the issue).
            if hookBox.started == 1 {
                await waitUntil { hookBox.started == 2 }
            }
            hookBox.recordComplete()
            return (url, sendOptions)
        }

        let first = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { hookBox.started == 1 }

        let second = Task { [options] in try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { hookBox.started == 2 }

        _ = try await second.value

        do {
            _ = try await first.value
            #expect(Bool(false), "the older request should have been superseded during its hook")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
    }

    @Test func beforeSendCannotChangeTheCancellationKey() async throws {
        let client = makeClient()
        let box = CancellationBox()
        var options = SendOptions()
        options.fetch = slowFetch(box: box)
        // No requestKey: the key is derived from method + path, resolved before
        // the hook runs.
        client.beforeSend = { url, sendOptions in
            var changed = sendOptions
            changed.method = "POST"
            return (url, changed)
        }

        let request = Task { try await client.sendRaw(path: "/api/things", options: options) }
        await waitUntil { box.started == 1 }

        // The pre-hook method was GET, so the request is registered under
        // "GET/api/things" even though the hook switched the request to POST.
        client.cancelRequest("GET/api/things")

        do {
            _ = try await request.value
            #expect(Bool(false), "the request should have been registered under its pre-hook key")
        } catch let error as ClientResponseError {
            #expect(error.isAbort)
        }
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
