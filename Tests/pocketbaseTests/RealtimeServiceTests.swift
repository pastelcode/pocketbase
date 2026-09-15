import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import pocketbase

struct SSEParserTests {
    @Test func parsesSingleFrame() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: PB_CONNECT\nid: abc\ndata: {}\n\n".utf8))

        #expect(events.count == 1)
        #expect(events[0].event == "PB_CONNECT")
        #expect(events[0].id == "abc")
        #expect(events[0].data == "{}")
    }

    @Test func parsesFrameSplitAcrossChunks() {
        var parser = SSEParser()
        #expect(parser.feed(Data("event: a\nda".utf8)).isEmpty)
        #expect(parser.feed(Data("ta: 1\n".utf8)).isEmpty)

        let events = parser.feed(Data("\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].event == "a")
        #expect(events[0].data == "1")
    }

    @Test func handlesCommentsAndMultiLineData() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keep-alive\nevent: x\ndata: line1\ndata: line2\n\n".utf8))

        #expect(events.count == 1)
        #expect(events[0].event == "x")
        #expect(events[0].data == "line1\nline2")
    }

    @Test func doesNotEmitFrameWithoutData() {
        var parser = SSEParser()
        #expect(parser.feed(Data("event: x\n\n".utf8)).isEmpty)
    }

    @Test func parsesMultipleFramesInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n".utf8))

        #expect(events.count == 2)
        #expect(events[0].event == "a")
        #expect(events[1].event == "b")
        #expect(events[1].data == "2")
    }

    @Test func parsesRetryDirective() {
        var parser = SSEParser()
        let events = parser.feed(Data("retry: 1000\nevent: a\ndata: 1\n\n".utf8))

        #expect(events.count == 1)
        #expect(events[0].retry == 1000)
    }
}

final class FakeTransport: SSETransport, @unchecked Sendable {
    var onEvent: (@Sendable (SSEEvent) -> Void)?
    var onDisconnect: (@Sendable (Error?) -> Void)?

    private let lock = NSLock()
    private var _connectCount = 0
    private var _cancelCount = 0
    private var _connectedURL: URL?
    private var _connectedHeaders: [String: String] = [:]

    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }
    var connectedURL: URL? { lock.lock(); defer { lock.unlock() }; return _connectedURL }
    var connectedHeaders: [String: String] { lock.lock(); defer { lock.unlock() }; return _connectedHeaders }

    func connect(url: URL, headers: [String: String]) {
        lock.lock()
        _connectCount += 1
        _connectedURL = url
        _connectedHeaders = headers
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        _cancelCount += 1
        lock.unlock()
    }

    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }

    func simulateDisconnect(_ error: Error?) {
        onDisconnect?(error)
    }
}

final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [[String: Any]] = []
    private var _disconnects: [[String]] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return _events.count }
    var last: [String: Any] { lock.lock(); defer { lock.unlock() }; return _events.last ?? [:] }
    var disconnectCount: Int { lock.lock(); defer { lock.unlock() }; return _disconnects.count }
    var lastDisconnect: [String] { lock.lock(); defer { lock.unlock() }; return _disconnects.last ?? [] }

    func record(_ event: [String: Any]) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    func recordDisconnect(_ active: [String]) {
        lock.lock()
        _disconnects.append(active)
        lock.unlock()
    }
}

final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [[String: Any]] = []
    private var _delayNanoseconds: UInt64 = 0

    var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }

    func setDelay(milliseconds: UInt64) {
        lock.lock()
        _delayNanoseconds = milliseconds * 1_000_000
        lock.unlock()
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let delay = withLock { () -> UInt64 in
            if let body = request.httpBody,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                _bodies.append(dict)
            } else {
                _bodies.append([:])
            }
            return _delayNanoseconds
        }

        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}

private func waitUntil(timeout: Double = 3, _ condition: @escaping @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

struct RealtimeServiceTests {
    private func makeClient() -> (PocketBase, FakeTransport, LockedBox) {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        let transport = FakeTransport()
        let box = LockedBox()
        client.realtime.makeTransport = { transport }
        client.realtime.onDisconnect = { active in
            box.recordDisconnect(active)
        }
        return (client, transport, box)
    }

    private func installFetchMock(on client: PocketBase) async {
        let fetchMock = FetchMock()
        await fetchMock.on(RequestMock(
            method: "POST",
            url: "http://127.0.0.1:8090/api/realtime",
            replyCode: 204
        ))
        client.beforeSend = { url, options in
            var updated = options
            updated.fetch = await fetchMock.customFetch()
            return (url, updated)
        }
    }

    @Test func subscribeConnectsAndReceivesEvents() async throws {
        let (client, transport, box) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { data in
                box.record(data)
            }
        }

        await waitUntil { transport.connectCount == 1 }
        #expect(transport.connectedURL?.absoluteString == "http://127.0.0.1:8090/api/realtime")

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        let unsubscribe = try await subscribeTask.value

        #expect(client.realtime.clientId == "client-1")
        #expect(client.realtime.isConnected)

        transport.emit(SSEEvent(event: "posts/*", data: "{\"action\":\"create\",\"n\":1}"))
        await waitUntil { box.count == 1 }

        #expect(box.count == 1)
        #expect(box.last["action"] as? String == "create")
        #expect(box.last["n"] as? Int == 1)

        try await unsubscribe()
        #expect(!client.realtime.isConnected)
    }

    @Test func unexpectedDisconnectTriggersReconnectAndOnDisconnect() async throws {
        let (client, transport, box) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }

        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value
        #expect(client.realtime.isConnected)

        transport.simulateDisconnect(ClientResponseError(message: "network drop"))

        await waitUntil { box.disconnectCount == 1 }
        #expect(box.lastDisconnect == ["posts/*"])

        // Backoff starts at 200ms; the service should reconnect on its own.
        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectCount == 2)

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))
        await waitUntil { client.realtime.clientId == "client-2" }
        #expect(client.realtime.isConnected)
    }

    @Test func connectFailurePropagatesToSubscriber() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }

        await waitUntil { transport.connectCount == 1 }
        transport.simulateDisconnect(ClientResponseError(message: "refused"))

        do {
            _ = try await subscribeTask.value
            #expect(Bool(false), "subscribe should have thrown")
        } catch let error as ClientResponseError {
            #expect(error.message.contains("refused"))
        }
    }

    private func installRecorder(on client: PocketBase, recorder: FetchRecorder) {
        client.beforeSend = { url, options in
            var updated = options
            updated.fetch = { request in
                try await recorder.fetch(request)
            }
            return (url, updated)
        }
    }

    @Test func concurrentSubmitsAreSerializedAndCoalesced() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        recorder.setDelay(milliseconds: 50)
        installRecorder(on: client, recorder: recorder)

        let first = Task {
            try await client.realtime.subscribe(topic: "posts/a") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "c1", data: "{}"))
        _ = try await first.value

        // Start two syncs concurrently while the poster is slow.
        async let second = client.realtime.subscribe(topic: "posts/b") { _ in }
        async let third = client.realtime.subscribe(topic: "posts/c") { _ in }
        _ = try await (second, third)

        await waitUntil { recorder.bodies.count >= 2 }

        // Every sync must build on the previous one: no stale or lost
        // subscription, and the final state must include all topics.
        var previous = Set<String>()
        for body in recorder.bodies {
            let subscriptions = Set(body["subscriptions"] as? [String] ?? [])
            #expect(subscriptions.isSuperset(of: previous))
            previous = subscriptions
        }
        #expect(previous == Set(["posts/a", "posts/b", "posts/c"]))
    }

    @Test func reconnectDelayHonorsServerRetryAsFloor() {
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: nil) == 200)
        #expect(RealtimeService.reconnectDelay(forAttempt: 1, serverRetryMilliseconds: nil) == 300)
        #expect(RealtimeService.reconnectDelay(forAttempt: 99, serverRetryMilliseconds: nil) == 2000)
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: 50) == 200)
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: 1000) == 1000)
        #expect(RealtimeService.reconnectDelay(forAttempt: 99, serverRetryMilliseconds: 5000) == 5000)
    }

    @Test func serverRetryDelaysReconnect() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "c1", data: "{}"))
        _ = try await subscribeTask.value

        // The server asks for a 1s reconnect delay.
        transport.emit(SSEEvent(event: "posts/*", data: "{}", retry: 1000))
        try await Task.sleep(nanoseconds: 30_000_000)

        transport.simulateDisconnect(ClientResponseError(message: "drop"))

        // Our default backoff would reconnect after ~200ms; the server asked
        // for 1000ms, so we must still be waiting at 400ms.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(transport.connectCount == 1)

        await waitUntil(timeout: 2.5) { transport.connectCount == 2 }
        #expect(transport.connectCount == 2)
    }

    @Test func unsubscribeBeforeConnectCancelsPendingConnect() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }

        // Unsubscribe while the handshake is still pending: the awaiting
        // subscribe resolves and the transport is cancelled.
        try await client.realtime.unsubscribe()
        _ = try await subscribeTask.value

        #expect(transport.cancelCount == 1)
        #expect(!client.realtime.isConnected)
    }
}
