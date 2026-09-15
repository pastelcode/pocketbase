import Foundation

public struct ClientResponseError: Error, CustomStringConvertible, Equatable, Sendable {
    public var url: String
    public var status: Int
    public var response: [String: AnyCodable]
    public var isAbort: Bool
    public var originalErrorDescription: String?

    public var data: [String: AnyCodable] {
        return response
    }

    public var message: String

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

    public var description: String {
        return "ClientResponseError \(status): \(message) (URL: \(url))"
    }

    public static func == (lhs: ClientResponseError, rhs: ClientResponseError) -> Bool {
        return lhs.url == rhs.url &&
               lhs.status == rhs.status &&
               lhs.response == rhs.response &&
               lhs.isAbort == rhs.isAbort &&
               lhs.message == rhs.message
    }
}
