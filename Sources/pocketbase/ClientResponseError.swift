import Foundation

/// An error returned by the client for failed requests or client-side failures.
///
/// Failed HTTP requests (status code 400 or higher) carry the server response
/// in ``response``. A request cancelled by auto-cancellation has ``isAbort``
/// set to `true`.
public struct ClientResponseError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The URL of the failed request.
    public var url: String
    /// The HTTP status code, or `0` for client-side failures.
    public var status: Int
    /// The decoded error response returned by the server.
    public var response: [String: AnyCodable]
    /// Whether the request was aborted, typically by auto-cancellation.
    public var isAbort: Bool
    /// The localized description of the underlying error, if any.
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
    ///   - isAbort: Whether the request was aborted. Defaults to `false`.
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
        self.isAbort = isAbort
        self.originalErrorDescription = originalError?.localizedDescription

        if let msg = message, !msg.isEmpty {
            self.message = msg
        } else if let respMsg = response["message"]?.value.string, !respMsg.isEmpty {
            self.message = respMsg
        } else if isAbort {
            self.message = "The request was aborted (most likely autocancelled; you can find more info in https://github.com/pocketbase/js-sdk#auto-cancellation)."
        } else if originalError?.localizedDescription.contains("ECONNREFUSED ::1") == true {
            self.message = "Failed to connect to the PocketBase server. Try changing the SDK URL from localhost to 127.0.0.1 (https://github.com/pocketbase/js-sdk/issues/21)."
        } else {
            self.message = "Something went wrong."
        }
    }

    /// A textual representation including the status code, message, and URL.
    public var description: String {
        return "ClientResponseError \(status): \(message) (URL: \(url))"
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
