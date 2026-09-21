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
    private let lock = NSLock()
    private var _onEvent: (@Sendable (SSEEvent) -> Void)?
    private var _onDisconnect: (@Sendable (Error?) -> Void)?

    var onEvent: (@Sendable (SSEEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEvent }
        set { lock.lock(); defer { lock.unlock() }; _onEvent = newValue }
    }

    var onDisconnect: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onDisconnect }
        set { lock.lock(); defer { lock.unlock() }; _onDisconnect = newValue }
    }

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

final class SequencedTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [FakeTransport]
    private var index = 0

    init(_ transports: [FakeTransport]) {
        self.transports = transports
    }

    var issued: [FakeTransport] {
        lock.lock()
        defer { lock.unlock() }
        return Array(transports.prefix(index))
    }

    func next() -> FakeTransport {
        lock.lock()
        defer { lock.unlock() }
        let transport = transports[min(index, transports.count - 1)]
        index += 1
        return transport
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

final class ToggleFetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _failPosts = false

    var failPosts: Bool {
        get { withLock { _failPosts } }
        set { withLock { _failPosts = newValue } }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let shouldFail = withLock { _failPosts }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: shouldFail ? 500 : 204,
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
    private func makeClient(authStore: BaseAuthStore? = nil) -> (PocketBase, FakeTransport, LockedBox) {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090", authStore: authStore)
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
        #expect(box.disconnectCount == 1)
        #expect(box.lastDisconnect == ["posts/*"])

        // Backoff starts at 200ms; the service should reconnect on its own.
        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectCount == 2)

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))
        await waitUntil { client.realtime.clientId == "client-2" }
        #expect(client.realtime.isConnected)
    }

    @Test func staleTransportCallbacksAreIgnored() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        await installFetchMock(on: client)

        let transport1 = FakeTransport()
        let transport2 = FakeTransport()
        let factory = SequencedTransportFactory([transport1, transport2])
        client.realtime.makeTransport = { factory.next() }

        let eventBox = LockedBox()
        let disconnectBox = LockedBox()
        client.realtime.onDisconnect = { active in
            disconnectBox.recordDisconnect(active)
        }

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { data in
                eventBox.record(data)
            }
        }

        await waitUntil { transport1.connectCount == 1 }
        transport1.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        let unsubscribe = try await subscribeTask.value
        #expect(client.realtime.isConnected)

        transport1.simulateDisconnect(ClientResponseError(message: "drop"))
        await waitUntil(timeout: 3) { transport2.connectCount == 1 }
        transport2.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))
        await waitUntil { client.realtime.clientId == "client-2" && client.realtime.isConnected }
        #expect(client.realtime.clientId == "client-2")
        #expect(client.realtime.isConnected)

        let disconnectsBeforeStale = disconnectBox.disconnectCount

        transport1.emit(SSEEvent(event: "posts/*", data: "{\"stale\":true}"))
        transport1.simulateDisconnect(ClientResponseError(message: "stale drop"))

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(eventBox.count == 0)
        #expect(client.realtime.clientId == "client-2")
        #expect(client.realtime.isConnected)
        #expect(disconnectBox.disconnectCount == disconnectsBeforeStale)

        _ = unsubscribe
    }

    @Test func lateEventFromCancelledTransportIsIgnored() async throws {
        let client = PocketBase(baseURL: "http://127.0.0.1:8090")
        await installFetchMock(on: client)

        let transport1 = FakeTransport()
        let transport2 = FakeTransport()
        let factory = SequencedTransportFactory([transport1, transport2])
        client.realtime.makeTransport = { factory.next() }

        let eventBox = LockedBox()

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { data in
                eventBox.record(data)
            }
        }

        await waitUntil { transport1.connectCount == 1 }
        transport1.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value

        transport1.simulateDisconnect(ClientResponseError(message: "drop"))
        await waitUntil(timeout: 3) { transport2.connectCount == 1 }
        transport2.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))
        await waitUntil { client.realtime.clientId == "client-2" }

        transport1.emit(SSEEvent(event: "posts/*", data: "{\"late\":true}"))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(eventBox.count == 0)
        #expect(client.realtime.clientId == "client-2")
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

    @Test func pendingConnectsResolveOnlyAfterSubscriptionPostCompletes() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        recorder.setDelay(milliseconds: 150)
        installRecorder(on: client, recorder: recorder)

        let first = Task { () -> Int in
            _ = try await client.realtime.subscribe(topic: "posts/a") { _ in }
            return recorder.bodies.count
        }
        let second = Task { () -> Int in
            _ = try await client.realtime.subscribe(topic: "posts/b") { _ in }
            return recorder.bodies.count
        }

        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        let firstCount = try await first.value
        let secondCount = try await second.value

        // Neither subscriber may be resumed before the handshake POST that
        // carries its subscription has been recorded.
        #expect(firstCount >= 1)
        #expect(secondCount >= 1)
        #expect(recorder.bodies.count >= 1)

        var previous = Set<String>()
        for body in recorder.bodies {
            let subscriptions = Set(body["subscriptions"] as? [String] ?? [])
            #expect(subscriptions.isSuperset(of: previous))
            previous = subscriptions
        }
        #expect(previous == Set(["posts/a", "posts/b"]))
    }

    @Test func subscriptionAddedDuringHandshakeSubmitIsResubmittedBeforeResolve() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        recorder.setDelay(milliseconds: 150)
        installRecorder(on: client, recorder: recorder)

        let first = Task {
            try await client.realtime.subscribe(topic: "posts/a") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        // Wait until the handshake's first POST is in flight, then register a
        // topic that was absent from that POST's snapshot.
        await waitUntil { recorder.bodies.count == 1 }
        let second = Task {
            try await client.realtime.subscribe(topic: "posts/b") { _ in }
        }

        _ = try await first.value
        _ = try await second.value
        await waitUntil { recorder.bodies.count >= 2 }

        #expect(recorder.bodies.count >= 2)

        let containsSecondTopic = recorder.bodies.contains { body in
            let subscriptions = body["subscriptions"] as? [String] ?? []
            return subscriptions.contains("posts/b")
        }
        #expect(containsSecondTopic)

        let final = Set(recorder.bodies.last?["subscriptions"] as? [String] ?? [])
        #expect(final == Set(["posts/a", "posts/b"]))
    }

    @Test func inFlightPostDoesNotSuppressResubmitAfterReconnect() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        recorder.setDelay(milliseconds: 500)
        installRecorder(on: client, recorder: recorder)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/a") { _ in }
        }

        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        // Wait until the first subscription POST is actually in flight.
        await waitUntil { recorder.bodies.count == 1 }

        // Drop the transport while the first POST is still running.
        transport.simulateDisconnect(ClientResponseError(message: "drop"))

        // Backoff starts at 200ms, so the reconnect happens while the 500ms
        // POST is still in flight and the resubmit is queued behind it.
        await waitUntil(timeout: 3) { transport.connectCount == 2 }

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))

        await waitUntil(timeout: 3) { recorder.bodies.count >= 2 }
        #expect(recorder.bodies.count == 2)

        let second = recorder.bodies[1]
        #expect(second["clientId"] as? String == "client-2")
        #expect((second["subscriptions"] as? [String])?.contains("posts/a") == true)

        _ = try await subscribeTask.value
    }

    @Test func disconnectAbortsInFlightSubscriptionPost() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        recorder.setDelay(milliseconds: 300)
        installRecorder(on: client, recorder: recorder)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/a") { _ in }
        }

        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        // Wait until the subscription POST is in flight before aborting it.
        await waitUntil { recorder.bodies.count == 1 }

        client.realtime.disconnect()

        // The aborted POST is swallowed: subscribe resolves without throwing.
        _ = try await subscribeTask.value
        #expect(!client.realtime.isConnected)

        // No reconnect happens, so no second stray POST may appear.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(recorder.bodies.count == 1)
    }

    @Test func clientIdReadsAreSafeUnderConcurrentLifecycle() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)
        client.realtime.maxConnectTimeout = 0.5

        let iterations = 400
        let readerCount = 4
        let churnCount = 2

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<readerCount {
                group.addTask {
                    for _ in 0..<iterations {
                        _ = client.realtime.clientId
                        _ = client.realtime.isConnected
                    }
                }
            }

            group.addTask {
                for index in 0..<(iterations * 4) {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-\(index)", data: "{}"))
                }
            }

            for index in 0..<churnCount {
                group.addTask {
                    for _ in 0..<iterations {
                        let unsubscribe = try? await client.realtime.subscribe(topic: "posts/\(index)") { _ in }
                        try? await client.realtime.unsubscribe("posts/\(index)")
                        _ = unsubscribe
                    }
                }
            }

            for _ in 0..<churnCount {
                group.addTask {
                    for _ in 0..<iterations {
                        client.realtime.disconnect()
                    }
                }
            }
        }

        let finalClientId: String = client.realtime.clientId
        if client.realtime.isConnected {
            #expect(!finalClientId.isEmpty)
        }

        try? await client.realtime.unsubscribe()
        client.realtime.disconnect()
        #expect(client.realtime.clientId.isEmpty)
        #expect(!client.realtime.isConnected)
    }

    @Test func reconnectDelayHonorsServerRetryAsFloor() {
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: nil) == 200)
        #expect(RealtimeService.reconnectDelay(forAttempt: 1, serverRetryMilliseconds: nil) == 300)
        #expect(RealtimeService.reconnectDelay(forAttempt: 99, serverRetryMilliseconds: nil) == 2000)
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: 50) == 200)
        #expect(RealtimeService.reconnectDelay(forAttempt: 0, serverRetryMilliseconds: 1000) == 1000)
        #expect(RealtimeService.reconnectDelay(forAttempt: 99, serverRetryMilliseconds: 5000) == 5000)
    }

    @Test func reconnectDelayFollowsTheReferenceBackoffTable() {
        let expected: [Double] = [200, 300, 500, 1000, 1200, 1500, 2000]
        #expect(RealtimeService.predefinedReconnectIntervals == expected)

        for (attempt, delay) in expected.enumerated() {
            #expect(RealtimeService.reconnectDelay(forAttempt: attempt, serverRetryMilliseconds: nil) == delay)
            // A server retry below the base delay never shortens it.
            #expect(RealtimeService.reconnectDelay(forAttempt: attempt, serverRetryMilliseconds: Int(delay) - 1) == delay)
            // A server retry above the base delay always wins.
            #expect(RealtimeService.reconnectDelay(forAttempt: attempt, serverRetryMilliseconds: Int(delay) + 1) == delay + 1)
        }

        // Attempts beyond the table keep using the last interval.
        for attempt in expected.count..<(expected.count + 5) {
            #expect(RealtimeService.reconnectDelay(forAttempt: attempt, serverRetryMilliseconds: nil) == 2000)
        }
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

    @Test func removingLastSubscriptionFiresOnDisconnectWithEmptyTopics() async throws {
        let (client, transport, box) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        let unsubscribe = try await subscribeTask.value
        #expect(box.disconnectCount == 0)

        try await unsubscribe()

        await waitUntil { box.disconnectCount == 1 }
        #expect(box.disconnectCount == 1)
        #expect(box.lastDisconnect == [])
        #expect(!client.realtime.isConnected)
    }

    @Test func connectTimeoutRejectsWhenNeverConnected() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)
        client.realtime.maxConnectTimeout = 0.15

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }

        do {
            _ = try await subscribeTask.value
            #expect(Bool(false), "subscribe should have thrown")
        } catch let error as ClientResponseError {
            #expect(error.message.contains("timed out"))
        }
    }

    @Test func connectTimeoutDuringReconnectSchedulesAnotherAttempt() async throws {
        let (client, transport, box) = makeClient()
        await installFetchMock(on: client)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value

        client.realtime.maxConnectTimeout = 0.15
        transport.simulateDisconnect(ClientResponseError(message: "drop"))

        await waitUntil { box.disconnectCount == 1 }
        #expect(box.disconnectCount == 1)

        // The first background reconnect attempt.
        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectCount == 2)

        // No PB_CONNECT arrives, so the connect timeout must schedule another
        // attempt without notifying onDisconnect a second time.
        await waitUntil(timeout: 3) { transport.connectCount >= 3 }
        #expect(transport.connectCount >= 3)
        #expect(box.disconnectCount == 1)
    }

    private func installToggleFetch(on client: PocketBase, stub: ToggleFetchStub) {
        client.beforeSend = { url, options in
            var updated = options
            updated.fetch = { request in
                try await stub.fetch(request)
            }
            return (url, updated)
        }
    }

    @Test func resubmitFailureOnInitialConnectRejectsSubscribersWithoutReconnect() async throws {
        let (client, transport, _) = makeClient()
        let stub = ToggleFetchStub()
        stub.failPosts = true
        installToggleFetch(on: client, stub: stub)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }

        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))

        do {
            _ = try await subscribeTask.value
            #expect(Bool(false), "subscribe should have thrown")
        } catch let error as ClientResponseError {
            #expect(error.status == 500)
        }

        #expect(!client.realtime.isConnected)

        // An initial resubmit failure must not trigger a background reconnect.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(transport.connectCount == 1)
    }

    @Test func resubmitFailureDuringReconnectSchedulesAnotherAttempt() async throws {
        let (client, transport, box) = makeClient()
        let stub = ToggleFetchStub()
        installToggleFetch(on: client, stub: stub)

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value
        #expect(client.realtime.isConnected)

        stub.failPosts = true

        transport.simulateDisconnect(ClientResponseError(message: "drop"))
        await waitUntil { box.disconnectCount == 1 }
        #expect(box.disconnectCount == 1)

        // The first background reconnect attempt (200ms backoff).
        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectCount == 2)

        // The resubmit for this handshake fails, so reconnectAttempts must
        // remain > 0 and schedule another background attempt.
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-2", data: "{}"))

        await waitUntil(timeout: 3) { transport.connectCount >= 3 }
        #expect(transport.connectCount >= 3)
        #expect(!client.realtime.isConnected)
        #expect(box.disconnectCount == 1)
    }

    @Test func authorizationHeaderUsesCurrentTokenAcrossReconnect() async throws {
        let (client, transport, _) = makeClient(authStore: BaseAuthStore())
        await installFetchMock(on: client)
        client.authStore.save(token: "token-1")

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        #expect(transport.connectedHeaders["Authorization"] == "token-1")

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value

        client.authStore.save(token: "token-2")
        transport.simulateDisconnect(ClientResponseError(message: "drop"))

        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectedHeaders["Authorization"] == "token-2")
    }

    @Test func authorizationHeaderOmittedAfterAuthClear() async throws {
        let (client, transport, _) = makeClient(authStore: BaseAuthStore())
        await installFetchMock(on: client)
        client.authStore.save(token: "token-1")

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        #expect(transport.connectedHeaders["Authorization"] == "token-1")

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value

        client.authStore.clear()
        transport.simulateDisconnect(ClientResponseError(message: "drop"))

        await waitUntil(timeout: 3) { transport.connectCount == 2 }
        #expect(transport.connectedHeaders["Authorization"] == nil)
    }

    @Test func pbConnectTopicReceivesHandshakeEvent() async throws {
        let (client, transport, _) = makeClient()
        await installFetchMock(on: client)
        let connectBox = LockedBox()

        let connectTask = Task {
            try await client.realtime.subscribe(topic: "PB_CONNECT") { data in
                connectBox.record(data)
            }
        }
        await waitUntil { transport.connectCount == 1 }

        let postsTask = Task {
            try await client.realtime.subscribe(topic: "posts/*") { _ in }
        }

        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{\"hello\":\"world\"}"))

        _ = try await postsTask.value
        _ = try await connectTask.value

        await waitUntil { connectBox.count == 1 }
        #expect(connectBox.count == 1)
        #expect(connectBox.last["hello"] as? String == "world")
    }

    @Test func subscribeOptionsFoldShorthandsIntoQuery() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        installRecorder(on: client, recorder: recorder)

        let options = SendOptions(
            query: ["perPage": 30],
            filter: "status = 'published'",
            sort: "-created"
        )

        let subscribeTask = Task {
            try await client.realtime.subscribe(topic: "posts/a", options: options) { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await subscribeTask.value
        await waitUntil { recorder.bodies.count == 1 }

        let keys = recorder.bodies[0]["subscriptions"] as? [String] ?? []
        #expect(keys.count == 1)
        let decoded = optionsJSON(from: keys.first ?? "")
        let query = decoded?["query"] as? [String: Any]
        #expect(query?["filter"] as? String == "status = 'published'")
        #expect(query?["sort"] as? String == "-created")
        #expect((query?["perPage"] as? NSNumber)?.intValue == 30)
        #expect(decoded?["headers"] == nil)
    }

    @Test func subscribeOptionsEncodingIsDeterministicAndConditional() async throws {
        let (client, transport, _) = makeClient()
        let recorder = FetchRecorder()
        installRecorder(on: client, recorder: recorder)

        let noHeaders = SendOptions(
            query: ["page": 1],
            filter: "f"
        )
        let withHeaders = SendOptions(
            headers: ["X-Token": "abc"],
            query: ["page": 1],
            filter: "f"
        )

        let first = Task {
            try await client.realtime.subscribe(topic: "posts/a", options: noHeaders) { _ in }
        }
        await waitUntil { transport.connectCount == 1 }
        transport.emit(SSEEvent(event: "PB_CONNECT", id: "client-1", data: "{}"))
        _ = try await first.value
        await waitUntil { recorder.bodies.count == 1 }

        // Identical topic plus identical options must hash to the same key,
        // so the server sync is skipped instead of carrying two subscriptions.
        let second = Task {
            try await client.realtime.subscribe(topic: "posts/a", options: noHeaders) { _ in }
        }
        _ = try await second.value
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(recorder.bodies.count == 1)

        let firstKey = (recorder.bodies[0]["subscriptions"] as? [String] ?? []).first ?? ""
        #expect(optionsJSON(from: firstKey)?["headers"] == nil)

        let third = Task {
            try await client.realtime.subscribe(topic: "posts/b", options: withHeaders) { _ in }
        }
        _ = try await third.value
        await waitUntil { recorder.bodies.count == 2 }

        let keys = recorder.bodies[1]["subscriptions"] as? [String] ?? []
        let withHeadersKey = keys.first { $0.hasPrefix("posts/b") } ?? ""
        let decoded = optionsJSON(from: withHeadersKey)
        let headers = decoded?["headers"] as? [String: Any]
        #expect(headers?["X-Token"] as? String == "abc")
    }

    private func optionsJSON(from topicKey: String) -> [String: Any]? {
        guard let range = topicKey.range(of: "options=") else { return nil }
        let encoded = String(topicKey[range.upperBound...])
        guard let decoded = encoded.removingPercentEncoding,
              let data = decoded.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

final class WeakTransportBox: @unchecked Sendable {
    weak var value: URLSessionSSETransport?
}

struct URLSessionSSETransportTests {
    @Test func transportReleasesSessionOnCancel() async throws {
        let weakBox = WeakTransportBox()

        do {
            let transport = URLSessionSSETransport()
            weakBox.value = transport

            transport.connect(url: URL(string: "http://127.0.0.1:1/")!, headers: [:])
            transport.cancel()

            #expect(transport.hasActiveSession == false)
        }

        await waitUntil(timeout: 2) { weakBox.value == nil }
        #expect(weakBox.value == nil)
    }

    @Test func transportReleasesSessionAfterStreamCompletes() async throws {
        let weakBox = WeakTransportBox()
        let disconnectBox = LockedBox()

        do {
            let transport = URLSessionSSETransport()
            weakBox.value = transport
            transport.onDisconnect = { _ in
                disconnectBox.record([:])
            }

            transport.connect(url: URL(string: "http://127.0.0.1:1/")!, headers: [:])

            await waitUntil(timeout: 3) {
                disconnectBox.count == 1 || weakBox.value?.hasActiveSession == false
            }
            #expect(weakBox.value?.hasActiveSession == false)
        }

        await waitUntil(timeout: 2) { weakBox.value == nil }
        #expect(weakBox.value == nil)
    }
}
