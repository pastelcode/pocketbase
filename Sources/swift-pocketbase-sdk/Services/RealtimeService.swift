import Foundation

public typealias UnsubscribeFunc = @Sendable () async throws -> Void
public typealias RealtimeCallback = @Sendable ([String: Any]) -> Void

open class RealtimeService: BaseService, @unchecked Sendable {
    public private(set) var clientId: String = ""
    public var onDisconnect: (@Sendable ([String]) -> Void)?

    private let lock = NSRecursiveLock()
    private var subscriptions: [String: [UUID: RealtimeCallback]] = [:]
    private var lastSentSubscriptions: [String] = []
    private var sseTask: URLSessionDataTask? = nil

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    open var isConnected: Bool {
        return withLock {
            !clientId.isEmpty && sseTask != nil
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
        let connected = withLock { () -> Bool in
            if subscriptions[topicKey] == nil {
                subscriptions[topicKey] = [:]
            }
            subscriptions[topicKey]?[callbackId] = callback
            return !clientId.isEmpty
        }

        if !connected {
            try await connect()
        } else {
            try await submitSubscriptions()
        }

        return { [weak self] in
            guard let self = self else { return }
            try await self.unsubscribeByCallbackId(key: topicKey, callbackId: callbackId)
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

        try await submitSubscriptions()
    }

    open func unsubscribeByPrefix(_ keyPrefix: String) async throws {
        withLock {
            let matchingKeys = subscriptions.keys.filter { ($0 + "?").hasPrefix(keyPrefix) }
            for k in matchingKeys {
                subscriptions.removeValue(forKey: k)
            }
        }

        try await submitSubscriptions()
    }

    private func unsubscribeByCallbackId(key: String, callbackId: UUID) async throws {
        withLock {
            subscriptions[key]?.removeValue(forKey: callbackId)
            if subscriptions[key]?.isEmpty == true {
                subscriptions.removeValue(forKey: key)
            }
        }

        try await submitSubscriptions()
    }

    private func submitSubscriptions() async throws {
        let (cId, nonKeys, shouldReturn, shouldDisconnect) = withLock { () -> (String, [String], Bool, Bool) in
            if clientId.isEmpty {
                return ("", [], true, false)
            }
            let keys = subscriptions.filter { !$0.value.isEmpty }.map { $0.key }
            if keys.isEmpty {
                return (clientId, [], false, true)
            }
            if Set(keys) == Set(lastSentSubscriptions) {
                return (clientId, keys, true, false)
            }
            lastSentSubscriptions = keys
            return (clientId, keys, false, false)
        }

        if shouldReturn {
            return
        }

        if shouldDisconnect {
            disconnect()
            return
        }

        var opt = SendOptions()
        opt.method = "POST"
        opt.body = .json([
            "clientId": AnyCodable(cId),
            "subscriptions": AnyCodable(nonKeys)
        ])
        opt.requestKey = "realtime_\(cId)"

        do {
            let _: Data = try await client.sendRaw(path: "/api/realtime", options: opt)
        } catch {
            if let err = error as? ClientResponseError, err.isAbort {
                return
            }
            throw error
        }
    }

    private func connect() async throws {
        let urlString = withLock { () -> String in
            disconnectInternal(fromReconnect: false)
            return client.buildURL(path: "/api/realtime")
        }

        guard let url = URL(string: urlString) else {
            throw ClientResponseError(message: "Invalid realtime URL")
        }

        let task = URLSession.shared.dataTask(with: url)
        withLock {
            self.sseTask = task
        }

        task.resume()
    }

    public func disconnect() {
        withLock {
            disconnectInternal(fromReconnect: false)
        }
    }

    private func disconnectInternal(fromReconnect: Bool) {
        if !clientId.isEmpty, let onDisconnect = onDisconnect {
            let active = Array(subscriptions.keys)
            onDisconnect(active)
        }

        sseTask?.cancel()
        sseTask = nil
        clientId = ""
        lastSentSubscriptions = []
    }

    public func handleMessage(event: String, id: String, data: String) {
        if event == "PB_CONNECT" {
            withLock {
                self.clientId = id
            }
            Task {
                try? await self.submitSubscriptions()
            }
            return
        }

        let callbacks = withLock { () -> [RealtimeCallback] in
            guard let dict = subscriptions[event] else { return [] }
            return Array(dict.values)
        }

        var dict: [String: Any] = [:]
        if let dataObject = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
            dict = dataObject
        }

        for cb in callbacks {
            cb(dict)
        }
    }
}
