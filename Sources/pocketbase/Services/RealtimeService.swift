import Foundation

public typealias UnsubscribeFunc = @Sendable () async throws -> Void
public typealias RealtimeCallback = @Sendable ([String: Any]) -> Void

open class RealtimeService: BaseService, @unchecked Sendable {
    public private(set) var clientId: String = ""
    public var onDisconnect: (@Sendable ([String]) -> Void)?

    /// Factory for the SSE transport. Internal so tests can inject a fake.
    var makeTransport: () -> SSETransport = { URLSessionSSETransport() }

    private let lock = NSRecursiveLock()
    private var subscriptions: [String: [UUID: RealtimeCallback]] = [:]
    private var lastSentSubscriptions: [String] = []
    private var transport: SSETransport?
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

    private let maxConnectTimeout: Double = 15
    static let predefinedReconnectIntervals: [Double] = [200, 300, 500, 1000, 1200, 1500, 2000]

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    /// Computes the reconnect delay. A server-provided SSE `retry:` value acts
    /// as a floor: we never reconnect sooner than the server asked for.
    static func reconnectDelay(forAttempt attempt: Int, serverRetryMilliseconds: Int?) -> Double {
        let index = min(max(attempt, 0), predefinedReconnectIntervals.count - 1)
        let base = predefinedReconnectIntervals[index]
        guard let retry = serverRetryMilliseconds else { return base }
        return max(base, Double(retry))
    }


    open var isConnected: Bool {
        return withLock {
            !clientId.isEmpty && isTransportActive && pendingConnects.isEmpty
        }
    }

    open func subscribe(
        topic: String,
        options: SendOptions? = nil,
        callback: @escaping RealtimeCallback
    ) async throws -> UnsubscribeFunc {
        guard !topic.isEmpty else {
            throw ClientResponseError(message: "topic must be set.")
        }

        var key = topic
        if let opt = options {
            let jsonDict: [String: AnyCodable] = [
                "query": AnyCodable(opt.query),
                "headers": AnyCodable(opt.headers)
            ]
            if let data = try? JSONEncoder().encode(jsonDict),
               let jsonStr = String(data: data, encoding: .utf8),
               let encodedOptions = jsonStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                key += (key.contains("?") ? "&" : "?") + "options=" + encodedOptions
            }
        }

        let topicKey = key
        let callbackId = UUID()
        let needsConnect = withLock { () -> Bool in
            if subscriptions[topicKey] == nil {
                subscriptions[topicKey] = [:]
            }
            subscriptions[topicKey]?[callbackId] = callback
            return clientId.isEmpty || !isTransportActive
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

    open func disconnect() {
        let (continuations, active, shouldNotify) = withLock {
            () -> ([CheckedContinuation<Void, Error>], [String], Bool) in
            let shouldNotify = !clientId.isEmpty
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
            clientId = ""
            lastSentSubscriptions = []

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (pending, active, shouldNotify)
        }

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
    public func handleMessage(event: String, id: String, data: String) {
        handle(event: SSEEvent(event: event, id: id, data: data))
    }

    // MARK: - Connection lifecycle

    private func ensureConnected() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let action = withLock { () -> Int in
                if !clientId.isEmpty && isTransportActive {
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

        let activeTransport = withLock { () -> SSETransport in
            transport?.cancel()
            reconnectTask?.cancel()
            reconnectTask = nil

            let newTransport = makeTransport()
            transport = newTransport
            isTransportActive = true
            return newTransport
        }

        activeTransport.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        activeTransport.onDisconnect = { [weak self] error in
            self?.handleTransportDisconnect(error)
        }

        let timeout = UInt64(maxConnectTimeout * 1_000_000_000)
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
            guard clientId.isEmpty, !isTransportActive else { return false }
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
                clientId = event.id
                lastSentSubscriptions = []
                reconnectAttempts = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
            }

            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.submitSubscriptions()
                } catch {
                    let continuations = self.withLock { () -> [CheckedContinuation<Void, Error>] in
                        self.clientId = ""
                        self.lastSentSubscriptions = []
                        let pending = self.pendingConnects
                        self.pendingConnects.removeAll()
                        return pending
                    }
                    for continuation in continuations {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                let continuations = self.withLock { () -> [CheckedContinuation<Void, Error>] in
                    let pending = self.pendingConnects
                    self.pendingConnects.removeAll()
                    return pending
                }
                for continuation in continuations {
                    continuation.resume()
                }

                self.dispatch(event: event.event, data: event.data)
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
        let (wasConnected, shouldReconnect, continuations) = withLock {
            () -> (Bool, Bool, [CheckedContinuation<Void, Error>]) in
            let wasConnected = !clientId.isEmpty
            let wasReconnecting = reconnectAttempts > 0

            isTransportActive = false
            transport = nil
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            clientId = ""
            lastSentSubscriptions = []

            if wasConnected || wasReconnecting {
                return (wasConnected, true, [])
            }

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (false, false, pending)
        }

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
        let (wasConnected, shouldReconnect, continuations) = withLock {
            () -> (Bool, Bool, [CheckedContinuation<Void, Error>]) in
            let wasConnected = !clientId.isEmpty
            let wasReconnecting = reconnectAttempts > 0

            transport?.cancel()
            transport = nil
            isTransportActive = false
            clientId = ""
            lastSentSubscriptions = []

            if wasConnected || wasReconnecting {
                return (wasConnected, true, [])
            }

            let pending = pendingConnects
            pendingConnects.removeAll()
            return (false, false, pending)
        }

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
                Task { await self.processPendingSubmits() }
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
            if clientId.isEmpty {
                return ("", [], true, false)
            }

            let keys = subscriptions
                .filter { !$0.value.isEmpty }
                .map { $0.key }
                .sorted()

            if keys.isEmpty {
                return (clientId, [], false, true)
            }

            if Set(keys) == Set(lastSentSubscriptions) {
                return (clientId, keys, true, false)
            }

            return (clientId, keys, false, false)
        }

        if shouldReturn {
            return
        }

        if shouldDisconnect {
            disconnect()
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
            withLock {
                lastSentSubscriptions = keys
            }
        } catch {
            if let err = error as? ClientResponseError, err.isAbort {
                return
            }
            throw error
        }
    }
}
