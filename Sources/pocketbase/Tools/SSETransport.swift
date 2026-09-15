import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport abstraction for the realtime SSE stream.
///
/// Kept internal so the service can be unit-tested with a fake implementation
/// and the transport can be swapped per platform without touching the state
/// machine.
protocol SSETransport: AnyObject, Sendable {
    /// Called for every frame parsed from the stream.
    var onEvent: (@Sendable (SSEEvent) -> Void)? { get set }
    /// Called once when the stream ends or fails.
    var onDisconnect: (@Sendable (Error?) -> Void)? { get set }

    /// Opens the SSE connection to the given URL.
    ///
    /// - Parameter url: The stream endpoint.
    /// - Parameter headers: Additional request headers, such as `Authorization`.
    func connect(url: URL, headers: [String: String])
    /// Closes the connection and suppresses any further disconnect callbacks.
    func cancel()
}

/// `URLSession`-backed SSE transport built on `URLSessionDataDelegate`.
///
/// A dedicated session with a delegate is required: `URLSession.shared` has no
/// delegate, so any bytes sent to it (such as an SSE stream) are discarded.
final class URLSessionSSETransport: NSObject, SSETransport, URLSessionDataDelegate, @unchecked Sendable {
    /// Called for every frame parsed from the stream.
    var onEvent: (@Sendable (SSEEvent) -> Void)?
    /// Called once when the stream ends or fails.
    var onDisconnect: (@Sendable (Error?) -> Void)?

    private let lock = NSRecursiveLock()
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var parser = SSEParser()
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private var didReportDisconnect = false

    /// Creates a transport backed by an ephemeral `URLSession`.
    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // SSE is long-lived; only fail an idle connection when the peer is
        // genuinely dead.
        configuration.timeoutIntervalForRequest = 60 * 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        self.configuration = configuration
        super.init()
    }

    deinit {
        session?.invalidateAndCancel()
    }

    /// Opens the SSE connection to the given URL.
    ///
    /// Sends `Accept: text/event-stream` and applies the extra headers.
    ///
    /// - Parameter url: The stream endpoint.
    /// - Parameter headers: Additional request headers.
    func connect(url: URL, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        lock.lock()
        isCancelled = false
        didReportDisconnect = false
        parser = SSEParser()
        if session == nil {
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }
        let session = session!
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()

        task.resume()
    }

    /// Closes the connection and suppresses any further disconnect callbacks.
    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    /// Validates the HTTP response before allowing the stream to continue.
    ///
    /// Non-HTTP or non-2xx responses cancel the task and report a disconnect.
    ///
    /// - Parameter session: The session that received the response.
    /// - Parameter dataTask: The task that received the response.
    /// - Parameter response: The received response.
    /// - Parameter completionHandler: Receives the disposition for the response.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            reportDisconnect(ClientResponseError(message: "Invalid realtime response."))
            completionHandler(.cancel)
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            reportDisconnect(ClientResponseError(
                url: http.url?.absoluteString ?? "",
                status: http.statusCode,
                message: "Realtime connection failed with status \(http.statusCode)."
            ))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    /// Feeds received bytes to the parser and forwards completed frames.
    ///
    /// - Parameter session: The session that received the data.
    /// - Parameter dataTask: The task that received the data.
    /// - Parameter data: The newly received bytes.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let events = parser.feed(data)
        let handler = onEvent
        lock.unlock()

        for event in events {
            handler?(event)
        }
    }

    /// Reports the stream end or failure to ``onDisconnect``.
    ///
    /// - Parameter session: The session that completed the task.
    /// - Parameter task: The completed task.
    /// - Parameter error: The failure, or `nil` for a clean end of stream.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        reportDisconnect(error)
    }

    /// Delivers the disconnect callback at most once per connection.
    ///
    /// - Parameter error: The failure, or `nil` for a clean end of stream.
    private func reportDisconnect(_ error: Error?) {
        lock.lock()
        if isCancelled || didReportDisconnect {
            lock.unlock()
            return
        }
        didReportDisconnect = true
        let handler = onDisconnect
        lock.unlock()

        handler?(error)
    }
}
