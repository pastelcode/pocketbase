import Foundation

/// A closure that removes a single realtime subscription when invoked.
public typealias UnsubscribeFunc = @Sendable () async throws -> Void
/// A closure invoked with the decoded JSON payload of a realtime event.
public typealias RealtimeCallback = @Sendable ([String: Any]) -> Void

/// Realtime events service built on Server-Sent Events.
///
/// The service connects to `/api/realtime`, waits for the server's
/// `PB_CONNECT` handshake to obtain a client id, then syncs the active topic
/// subscriptions over `POST /api/realtime`. If the stream drops, it
/// reconnects using a predefined backoff (200ms up to 2s); jitter is applied
/// only to this client-defined backoff, while a server-provided SSE `retry:`
/// value acts as a floor and disables jitter. Active subscriptions are
/// resubmitted automatically after every reconnect.
///
/// - Note: Honoring `retry:` for the custom reconnect intentionally goes
///   beyond the JS SDK, which ignores it.
///
/// ```swift
/// let unsubscribe = try await client.realtime.subscribe(topic: "posts/*") { event in
///     print(event)
/// }
/// try await unsubscribe()
/// ```
open class RealtimeService: BaseService, @unchecked Sendable {
    /// The client id assigned by the server during the `PB_CONNECT` handshake.
    ///
    /// Empty while disconnected or before the handshake completes.
    public var clientId: String {
        withLock { _clientId }
    }
    /// Called when an established connection drops.
    ///
    /// The argument contains the topics that were active at the time.
    public var onDisconnect: (@Sendable ([String]) -> Void)?

    /// Factory for the SSE transport. Internal so tests can inject a fake.
    var makeTransport: () -> SSETransport = { URLSessionSSETransport() }

    private let lock = NSRecursiveLock()
    private var _clientId: String = ""
    private var subscriptions: [String: [UUID: RealtimeCallback]] = [:]
    private var lastSentSubscriptions: [String] = []
    private var transport: SSETransport?
    private var transportGeneration = 0
    private var isTransportActive = false
    private var pendingConnects: [CheckedContinuation<Void, Error>] = []
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var serverRetryInterval: Int?

    /// Serializes subscription sync requests and coalesces concurrent callers,
    /// mirroring the JS SDK's `pendingSubmits` queue.
    private var pendingSubmits: [CheckedContinuation<Void, Error>] = []
    private var isProcessingSubmits = false

    var maxConnectTimeout: Double = 15
    static let predefinedReconnectIntervals: [Double] = [200, 300, 500, 1000, 1200, 1500, 2000]

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    private func isCurrentTransport(_ candidate: SSETransport, generation: Int) -> Bool {
        withLock { transport === candidate && transportGeneration == generation }
    }

    /// Aborts the in-flight subscription POST belonging to `clientId`.
    ///
    /// Must be called after releasing `lock`: `PocketBase.cancelRequest` takes
    /// the client's own lock and the service lock is not re-entrant across it.
    private func cancelSubscriptionRequest(for clientId: String) {
        guard !clientId.isEmpty else { return }
        client.cancelRequest("realtime_\(clientId)")
    }

    /// Computes the reconnect delay. A server-provided SSE `retry:` value acts
    /// as a floor: we never reconnect sooner than the server asked for.
    ///
    /// Attempts beyond the predefined list are capped at the last interval.
    ///
    /// - Parameter attempt: The zero-based reconnect attempt number.
    /// - Parameter serverRetryMilliseconds: The server-suggested delay in
    ///   milliseconds, if any.
    /// - Returns: The reconnect delay in milliseconds.
    static func reconnectDelay(forAttempt attempt: Int, serverRetryMilliseconds: Int?) -> Double {
        let index = min(max(attempt, 0), predefinedReconnectIntervals.count - 1)
        let base = predefinedReconnectIntervals[index]
        guard let retry = serverRetryMilliseconds else { return base }
        return max(base, Double(retry))
    }


    /// Whether the transport is connected and the `PB_CONNECT` handshake completed.
    open var isConnected: Bool {
        return withLock {
            !_clientId.isEmpty && isTransportActive && pendingConnects.isEmpty
        }
    }

    /// Subscribes to a realtime topic.
    ///
    /// The topic can be an exact topic (for example `posts/abc123`), a
    /// wildcard topic (for example `posts/*`), or the special `PB_CONNECT`
    /// topic. When `options` are supplied, their typed shorthands, query, and
    /// headers are serialized into the topic key so subscriptions with
    /// different options remain independent.
    ///
    /// ```swift
    /// let unsubscribe = try await client.realtime.subscribe(topic: "posts/*") { event in
    ///     print(event["action"] ?? "")
    /// }
    /// ```
    ///
    /// - Parameter topic: The topic to listen to.
    /// - Parameter options: Extra query parameters, headers, and typed
    ///   shorthands (folded into `query`) for the subscription.
    /// - Parameter callback: Invoked with the JSON payload of every matching event.
    /// - Returns: A closure that removes this subscription when invoked.
    /// - Throws: ``ClientResponseError`` when the topic is empty or the
    ///   connection and subscription sync fail.
    open func subscribe(
        topic: String,
        options: SendOptions? = nil,
        callback: @escaping RealtimeCallback
    ) async throws -> UnsubscribeFunc {
        guard !topic.isEmpty else {
            throw ClientResponseError(message: "topic must be set.")
        }

        var key = topic
        if var opt = options {
            opt.applyShorthandQuery()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            var jsonStr = "{}"
            if let data = try? encoder.encode(opt.query) {
                let query = String(data: data, encoding: .utf8) ?? "{}"
                jsonStr = "{\"query\":\(query)"
                if !opt.headers.isEmpty, let headersData = try? encoder.encode(opt.headers) {
                    let headers = String(data: headersData, encoding: .utf8) ?? "{}"
                    jsonStr += ",\"headers\":\(headers)"
                }
                jsonStr += "}"
            }

            key += (key.contains("?") ? "&" : "?") + "options=" + jsonStr.encodeURIComponent()
        }

        let topicKey = key
        let callbackId = UUID()
        let needsConnect = withLock { () -> Bool in
            if subscriptions[topicKey] == nil {
                subscriptions[topicKey] = [:]
            }
            subscriptions[topicKey]?[callbackId] = callback
            return _clientId.isEmpty || !isTransportActive
        }

        if needsConnect {
            try await ensureConnected()
        } else {
            try await submitSubscriptions()
        }

        return { [weak self] in
            guard let self = self else { return }
            try await self.unsubscribeByCallbackId(key: topicKey, callbackId: callbackId)
        }
    }

    private func hasActiveSubscriptions() -> Bool {
        return withLock {
            subscriptions.contains { !$0.value.isEmpty }
        }
    }

    private func hasUnsentSubscriptions() -> Bool {
        withLock {
            let current = Set(subscriptions.filter { !$0.value.isEmpty }.map { $0.key })
            return current != Set(lastSentSubscriptions)
        }
    }

    /// Removes subscriptions matching a topic.
    ///
    /// Passing `nil` removes all subscriptions; otherwise every topic whose
    /// key equals `topic` or starts with `topic` plus a `?` is removed. When
    /// no subscriptions remain, the connection is closed.
    ///
    /// - Parameter topic: The topic to unsubscribe from, or `nil` for all topics.
    open func unsubscribe(_ topic: String? = nil) async throws {
        withLock {
            if let topic = topic {
                let matchingKeys = subscriptions.keys.filter { ($0 + "?").hasPrefix(topic.contains("?") ? topic : topic + "?") }
                for k in matchingKeys {
                    subscriptions.removeValue(forKey: k)
                }
            } else {
                subscriptions.removeAll()
            }
        }

        if !hasActiveSubscriptions() {
            disconnect()
            return
        }

        try await submitSubscriptions()
    }

    /// Removes all subscriptions whose topic starts with the given prefix.
    ///
    /// When no subscriptions remain, the connection is closed.
    ///
    /// - Parameter keyPrefix: The topic prefix to match.
    open func unsubscribeByPrefix(_ keyPrefix: String) async throws {
        withLock {
            let matchingKeys = subscriptions.keys.filter { ($0 + "?").hasPrefix(keyPrefix) }
            for k in matchingKeys {
                subscriptions.removeValue(forKey: k)
            }
        }

        if !hasActiveSubscriptions() {
            disconnect()
            return
        }

        try await submitSubscriptions()
    }

    /// Closes the realtime connection.
    ///
    /// Pending connects are resumed without throwing. When a connection was
    /// previously established, `onDisconnect` is invoked with the active
    /// topics. Registered subscriptions are kept.
    open func disconnect() {
        let (outgoingClientId, continuations, active, shouldNotify) = withLock {
            () -> (String, [CheckedContinuation<Void, Error>], [String], Bool) in
            let outgoingClientId = _clientId
            let shouldNotify = !_clientId.isEmpty
            let active = Array(subscriptions.keys)

            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempts = 0
            serverRetryInterval = nil
            transport?.cancel()
            transport = nil
            isTransportActive = false
            _clientId = ""
            lastSentSubscriptions = []

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (outgoingClientId, pending, active, shouldNotify)
        }

        cancelSubscriptionRequest(for: outgoingClientId)

        // Resume pending connects without throwing, matching the JS SDK: an
        // unsubscribe before the initial connect should not surface an error.
        for continuation in continuations {
            continuation.resume()
        }

        if shouldNotify {
            onDisconnect?(active)
        }
    }

    /// Handles a raw SSE frame. Kept public for backwards compatibility and
    /// manual injection; the transport calls the same path internally.
    ///
    /// - Parameter event: The SSE event type.
    /// - Parameter id: The SSE event id.
    /// - Parameter data: The raw SSE data payload.
    public func handleMessage(event: String, id: String, data: String) {
        handle(event: SSEEvent(event: event, id: id, data: data))
    }

    // MARK: - Connection lifecycle

    private func ensureConnected() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let action = withLock { () -> Int in
                if !_clientId.isEmpty && isTransportActive && pendingConnects.isEmpty {
                    return 0 // already connected
                }
                pendingConnects.append(continuation)
                return pendingConnects.count == 1 ? 1 : 2 // 1 = start, 2 = wait
            }

            switch action {
            case 0:
                continuation.resume()
            case 1:
                startTransport()
            default:
                break
            }
        }
    }

    private func startTransport() {
        let urlString = client.buildURL(path: "/api/realtime")
        guard let url = URL(string: urlString) else {
            failPendingConnects(ClientResponseError(url: urlString, status: 0, message: "Invalid realtime URL"))
            return
        }

        var headers: [String: String] = [:]
        if !client.authStore.token.isEmpty {
            headers["Authorization"] = client.authStore.token
        }
        if !client.lang.isEmpty {
            headers["Accept-Language"] = client.lang
        }

        let (activeTransport, generation) = withLock { () -> (SSETransport, Int) in
            transport?.cancel()
            reconnectTask?.cancel()
            reconnectTask = nil

            let newTransport = makeTransport()
            transport = newTransport
            isTransportActive = true
            transportGeneration += 1
            return (newTransport, transportGeneration)
        }

        activeTransport.onEvent = { [weak self] event in
            guard let self = self, self.isCurrentTransport(activeTransport, generation: generation) else { return }
            self.handle(event: event)
        }
        activeTransport.onDisconnect = { [weak self] error in
            guard let self = self, self.isCurrentTransport(activeTransport, generation: generation) else { return }
            self.handleTransportDisconnect(error)
        }

        let timeout = UInt64((maxConnectTimeout * 1_000_000_000).rounded())
        withLock {
            connectTimeoutTask?.cancel()
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                self?.handleConnectTimeout()
            }
        }

        activeTransport.connect(url: url, headers: headers)
    }

    private func reconnectIfNeeded() {
        let shouldStart = withLock { () -> Bool in
            guard _clientId.isEmpty, !isTransportActive else { return false }
            return subscriptions.contains { !$0.value.isEmpty }
        }
        if shouldStart {
            startTransport()
        }
    }

    private func scheduleReconnect() {
        let (interval, jitter) = withLock { () -> (Double, Double) in
            let serverRetry = serverRetryInterval
            let delay = Self.reconnectDelay(forAttempt: reconnectAttempts, serverRetryMilliseconds: serverRetry)
            reconnectAttempts += 1

            // Add +/-20% jitter to our own backoff to avoid a thundering herd,
            // but honor an explicit server-directed retry delay as-is.
            let factor = serverRetry == nil ? Double.random(in: 0.8...1.2) : 1.0
            return (delay, factor)
        }
        let nanoseconds = UInt64(interval * jitter * 1_000_000)

        withLock {
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.reconnectIfNeeded()
            }
        }
    }

    private func handle(event: SSEEvent) {
        if let retry = event.retry {
            withLock {
                serverRetryInterval = retry
            }
        }

        if event.event == "PB_CONNECT" {
            withLock {
                _clientId = event.id
                lastSentSubscriptions = []
                reconnectTask?.cancel()
                reconnectTask = nil
            }

            // Retain the owning client for the lifetime of this task: `client`
            // is an unowned reference and the task may outlive the caller that
            // holds the client.
            let client = self.client
            Task { [weak self] in
                guard let self = self else { return }
                _ = client

                do {
                    try await self.submitSubscriptions()

                    var maxResubmit = 3
                    while self.hasUnsentSubscriptions() && maxResubmit > 0 {
                        maxResubmit -= 1
                        try await self.submitSubscriptions()
                    }
                } catch {
                    self.connectErrorHandler(error)
                    return
                }

                let continuations = self.withLock { () -> [CheckedContinuation<Void, Error>] in
                    self.reconnectAttempts = 0
                    self.connectTimeoutTask?.cancel()
                    self.connectTimeoutTask = nil
                    let pending = self.pendingConnects
                    self.pendingConnects.removeAll()
                    return pending
                }
                for continuation in continuations {
                    continuation.resume()
                }

                self.dispatch(event: event.event, data: event.data)

                if self.hasUnsentSubscriptions() {
                    try? await self.submitSubscriptions()
                }
            }
            return
        }

        dispatch(event: event.event, data: event.data)
    }

    private func dispatch(event: String, data: String) {
        let callbacks = withLock { () -> [RealtimeCallback] in
            guard let listeners = subscriptions[event] else { return [] }
            return Array(listeners.values)
        }
        guard !callbacks.isEmpty else { return }

        var payload: [String: Any] = [:]
        if let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
            payload = object
        }

        for callback in callbacks {
            callback(payload)
        }
    }

    private func handleTransportDisconnect(_ error: Error?) {
        let (outgoingClientId, wasConnected, shouldReconnect, continuations) = withLock {
            () -> (String, Bool, Bool, [CheckedContinuation<Void, Error>]) in
            let outgoingClientId = _clientId
            let wasConnected = !_clientId.isEmpty
            let wasReconnecting = reconnectAttempts > 0

            isTransportActive = false
            transport = nil
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            _clientId = ""
            lastSentSubscriptions = []

            if wasConnected || wasReconnecting {
                return (outgoingClientId, wasConnected, true, [])
            }

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (outgoingClientId, false, false, pending)
        }

        cancelSubscriptionRequest(for: outgoingClientId)

        if shouldReconnect {
            if wasConnected {
                notifyDisconnect()
            }
            scheduleReconnect()
        } else {
            let failure = error ?? ClientResponseError(message: "Failed to establish realtime connection.")
            for continuation in continuations {
                continuation.resume(throwing: failure)
            }
        }
    }

    private func handleConnectTimeout() {
        let (outgoingClientId, wasConnected, shouldReconnect, continuations) = withLock {
            () -> (String, Bool, Bool, [CheckedContinuation<Void, Error>]) in
            let outgoingClientId = _clientId
            let wasConnected = !_clientId.isEmpty
            let wasReconnecting = reconnectAttempts > 0

            transport?.cancel()
            transport = nil
            isTransportActive = false
            _clientId = ""
            lastSentSubscriptions = []

            if wasConnected || wasReconnecting {
                return (outgoingClientId, wasConnected, true, [])
            }

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (outgoingClientId, false, false, pending)
        }

        cancelSubscriptionRequest(for: outgoingClientId)

        if shouldReconnect {
            if wasConnected {
                notifyDisconnect()
            }
            scheduleReconnect()
        } else {
            let error = ClientResponseError(message: "Realtime connection timed out.")
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Handles a failed connect attempt or post-`PB_CONNECT` submission.
    ///
    /// Rejects pending connects when no reconnect was in progress; otherwise
    /// leaves them pending and schedules another background reconnect.
    private func connectErrorHandler(_ error: Error?) {
        let (outgoingClientId, shouldReject, continuations) = withLock {
            () -> (String, Bool, [CheckedContinuation<Void, Error>]) in
            let outgoing = _clientId
            let wasReconnecting = reconnectAttempts > 0

            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            transport?.cancel()
            transport = nil
            isTransportActive = false
            _clientId = ""
            lastSentSubscriptions = []

            if !wasReconnecting {
                let pending = pendingConnects
                pendingConnects.removeAll()
                return (outgoing, true, pending)
            }
            return (outgoing, false, [])
        }

        cancelSubscriptionRequest(for: outgoingClientId)

        if shouldReject {
            let failure = error ?? ClientResponseError(message: "Failed to establish realtime connection.")
            for continuation in continuations {
                continuation.resume(throwing: failure)
            }
        } else {
            scheduleReconnect()
        }
    }

    private func failPendingConnects(_ error: Error) {
        let continuations = withLock { () -> [CheckedContinuation<Void, Error>] in
            isTransportActive = false
            let pending = pendingConnects
            pendingConnects.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func notifyDisconnect() {
        guard let handler = onDisconnect else { return }
        let active = withLock { Array(subscriptions.keys) }
        handler(active)
    }

    // MARK: - Subscription sync

    private func unsubscribeByCallbackId(key: String, callbackId: UUID) async throws {
        withLock {
            subscriptions[key]?.removeValue(forKey: callbackId)
            if subscriptions[key]?.isEmpty == true {
                subscriptions.removeValue(forKey: key)
            }
        }

        if !hasActiveSubscriptions() {
            disconnect()
            return
        }

        try await submitSubscriptions()
    }

    /// Queues a subscription sync and coalesces concurrent callers into a
    /// single serialized run, mirroring the JS SDK's `pendingSubmits` queue.
    /// A caller only resumes once a sync that observed its state completed.
    private func submitSubscriptions() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shouldStart = withLock { () -> Bool in
                pendingSubmits.append(continuation)
                if isProcessingSubmits {
                    return false
                }
                isProcessingSubmits = true
                return true
            }

            if shouldStart {
                // Retain the owning client for the lifetime of the processing
                // task: `client` is an unowned reference and the task may
                // outlive the caller that holds the client.
                let client = self.client
                Task {
                    _ = client
                    await self.processPendingSubmits()
                }
            }
        }
    }

    private func processPendingSubmits() async {
        while true {
            let continuations = withLock { () -> [CheckedContinuation<Void, Error>] in
                let pending = pendingSubmits
                pendingSubmits.removeAll()
                return pending
            }

            if continuations.isEmpty {
                // Re-check under lock so a submit that arrived while we were
                // deciding to stop is not lost.
                let shouldStop = withLock { () -> Bool in
                    if pendingSubmits.isEmpty {
                        isProcessingSubmits = false
                        return true
                    }
                    return false
                }
                if shouldStop {
                    return
                }
                continue
            }

            do {
                try await performSubmit()
                for continuation in continuations {
                    continuation.resume()
                }
            } catch {
                for continuation in continuations {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performSubmit() async throws {
        let (currentClientId, keys, shouldReturn, shouldDisconnect) = withLock {
            () -> (String, [String], Bool, Bool) in
            if _clientId.isEmpty {
                return ("", [], true, false)
            }

            let keys = subscriptions
                .filter { !$0.value.isEmpty }
                .map { $0.key }
                .sorted()

            if keys.isEmpty {
                return (_clientId, [], false, true)
            }

            if Set(keys) == Set(lastSentSubscriptions) {
                return (_clientId, keys, true, false)
            }

            // Optimistic write, mirroring the JS SDK: record the intended
            // subscriptions before the POST so a resubmit queued behind this
            // one is not suppressed if the connection has moved on meanwhile.
            lastSentSubscriptions = keys
            return (_clientId, keys, false, false)
        }

        if shouldReturn {
            return
        }

        if shouldDisconnect {
            disconnect()
            return
        }

        // The connection may have moved on while this submit waited in the
        // queue (for example across a reconnect); never POST for a stale id.
        let isStale = withLock {
            _clientId != currentClientId || !isTransportActive
        }
        if isStale {
            return
        }

        var options = SendOptions()
        options.method = "POST"
        options.body = .json([
            "clientId": AnyCodable(currentClientId),
            "subscriptions": AnyCodable(keys)
        ])
        options.requestKey = "realtime_\(currentClientId)"

        do {
            let _: Data = try await client.sendRaw(path: "/api/realtime", options: options)
        } catch {
            if let err = error as? ClientResponseError, err.isAbort {
                return
            }
            throw error
        }
    }
}
