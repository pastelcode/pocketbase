import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error returned by the client for failed requests or client-side failures.
///
/// Failed HTTP requests (status code 400 or higher) carry the server response
/// in ``response``. Client-side failures (transport, encoding, decoding or
/// hooks) leave ``status`` at `0` and expose the underlying error through
/// ``originalError``. A request cancelled by auto-cancellation has ``isAbort``
/// set to `true`.
public struct ClientResponseError: Error, CustomStringConvertible, Equatable, @unchecked Sendable {
    /// The URL of the failed request.
    public var url: String
    /// The HTTP status code, or `0` for client-side failures.
    public var status: Int
    /// The decoded error response returned by the server.
    public var response: [String: AnyCodable]
    /// Whether the request was aborted, typically by auto-cancellation.
    ///
    /// Cancellation errors (`CancellationError`, `URLError.cancelled`) set this
    /// automatically, so callers can rely on it without tracking cancellation
    /// themselves.
    public var isAbort: Bool
    /// The underlying error for transport, encoding, decoding or hook failures.
    ///
    /// `nil` when the server reported the failure through an HTTP error status.
    public var originalError: (any Error)?
    /// The localized description of ``originalError``, if any.
    public var originalErrorDescription: String?

    /// An alias for ``response``.
    public var data: [String: AnyCodable] {
        return response
    }

    /// A human-readable error message.
    ///
    /// Derived from the server's `message` field, an abort-specific message, or
    /// a generic fallback when neither is available.
    public var message: String

    /// Creates a response error.
    ///
    /// - Parameters:
    ///   - url: The URL of the failed request. Defaults to `""`.
    ///   - status: The HTTP status code. Defaults to `0`.
    ///   - response: The decoded server response. Defaults to an empty dictionary.
    ///   - isAbort: Whether the request was aborted. Also inferred from
    ///     `originalError`. Defaults to `false`.
    ///   - originalError: The underlying error, if any. Defaults to `nil`.
    ///   - message: An explicit message that overrides the derived one.
    ///     Defaults to `nil`.
    public init(
        url: String = "",
        status: Int = 0,
        response: [String: AnyCodable] = [:],
        isAbort: Bool = false,
        originalError: Error? = nil,
        message: String? = nil
    ) {
        self.url = url
        self.status = status
        self.response = response
        self.originalError = originalError
        self.originalErrorDescription = originalError?.localizedDescription

        let resolvedIsAbort = isAbort || Self.isAbortError(originalError)
        self.isAbort = resolvedIsAbort

        if let msg = message, !msg.isEmpty {
            self.message = msg
        } else if let respMsg = response["message"]?.value.string, !respMsg.isEmpty {
            self.message = respMsg
        } else if resolvedIsAbort {
            self.message = "The request was aborted (most likely autocancelled; you can find more info in https://github.com/pocketbase/js-sdk#auto-cancellation)."
        } else if originalError?.localizedDescription.contains("ECONNREFUSED ::1") == true {
            self.message = "Failed to connect to the PocketBase server. Try changing the SDK URL from localhost to 127.0.0.1 (https://github.com/pocketbase/js-sdk/issues/21)."
        } else {
            self.message = "Something went wrong."
        }
    }

    /// Creates a normalized error from an arbitrary thrown error, mirroring the
    /// reference SDK's `ClientResponseError` constructor.
    ///
    /// When `error` is already a ``ClientResponseError``, its ``url``,
    /// ``status``, ``response``, ``isAbort`` and ``originalError`` are preserved
    /// and ``message`` is re-derived from the existing response. Any other error
    /// becomes the ``originalError`` of a client-side error (`status: 0`).
    ///
    /// This is used to normalize failures thrown inside the ``PocketBase/beforeSend``
    /// and ``PocketBase/afterSend`` hooks.
    ///
    /// - Parameters:
    ///   - error: The error to normalize.
    ///   - url: The URL associated with the failure. Ignored when `error` is a
    ///     ``ClientResponseError``. Defaults to `""`.
    public init(wrapping error: Error, url: String = "") {
        if let existing = error as? ClientResponseError {
            self.init(
                url: existing.url,
                status: existing.status,
                response: existing.response,
                isAbort: existing.isAbort,
                originalError: existing.originalError
            )
        } else {
            self.init(url: url, originalError: error)
        }
    }

    /// A textual representation including the status code, message, and URL.
    public var description: String {
        return "ClientResponseError \(status): \(message) (URL: \(url))"
    }

    /// Returns whether the given error represents an aborted request.
    ///
    /// Recognizes Swift task cancellation, `URLError.cancelled`, and errors
    /// whose localized description is `"Aborted"`, matching the reference SDK's
    /// abort detection.
    ///
    /// - Parameter error: The error to inspect, or `nil`.
    /// - Returns: `true` when the error represents an abort.
    public static func isAbortError(_ error: Error?) -> Bool {
        guard let error = error else {
            return false
        }
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.localizedDescription == "Aborted" {
            return true
        }
        return false
    }

    /// Returns a Boolean value indicating whether two errors are equal.
    ///
    /// - Parameters:
    ///   - lhs: The first error to compare.
    ///   - rhs: The second error to compare.
    /// - Returns: `true` if the two errors are equal.
    public static func == (lhs: ClientResponseError, rhs: ClientResponseError) -> Bool {
        return lhs.url == rhs.url &&
               lhs.status == rhs.status &&
               lhs.response == rhs.response &&
               lhs.isAbort == rhs.isAbort &&
               lhs.message == rhs.message
    }
}
