import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import pocketbase

public struct RequestMock: Sendable {
    public var method: String?
    public var url: String?
    public var replyCode: Int
    public var replyBody: Data
    public var additionalMatcher: (@Sendable (URLRequest) -> Bool)?

    public init(
        method: String? = nil,
        url: String? = nil,
        replyCode: Int = 200,
        replyBody: Data = Data(),
        additionalMatcher: (@Sendable (URLRequest) -> Bool)? = nil
    ) {
        self.method = method
        self.url = url
        self.replyCode = replyCode
        self.replyBody = replyBody
        self.additionalMatcher = additionalMatcher
    }

    public init(
        method: String? = nil,
        url: String? = nil,
        replyCode: Int = 200,
        jsonBody: Any,
        additionalMatcher: (@Sendable (URLRequest) -> Bool)? = nil
    ) {
        let data = (try? JSONSerialization.data(withJSONObject: jsonBody)) ?? Data()
        self.init(method: method, url: url, replyCode: replyCode, replyBody: data, additionalMatcher: additionalMatcher)
    }
}

public actor FetchMock {
    private var mocks: [RequestMock] = []

    public init() {}

    public func on(_ mock: RequestMock) {
        mocks.append(mock)
    }

    public func clear() {
        mocks.removeAll()
    }

    public func customFetch() -> CustomFetch {
        return { [weak self] request in
            guard let self = self else {
                throw ClientResponseError(message: "FetchMock released")
            }

            let activeMocks = await self.getMocks()
            let reqUrl = request.url?.absoluteString ?? ""
            let reqMethod = request.httpMethod ?? "GET"

            for mock in activeMocks {
                if let mUrl = mock.url, mUrl != reqUrl {
                    continue
                }
                if let mMethod = mock.method, mMethod != reqMethod {
                    continue
                }
                if let matcher = mock.additionalMatcher, !matcher(request) {
                    continue
                }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: mock.replyCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!

                return (mock.replyBody, response)
            }

            throw ClientResponseError(url: reqUrl, status: 404, message: "Request not mocked: \(reqUrl) [\(reqMethod)]")
        }
    }

    private func getMocks() -> [RequestMock] {
        return mocks
    }
}

public func dummyJWT(payload: [String: Any] = [:]) -> String {
    let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    let payloadBase64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "\(header).\(payloadBase64).test"
}

/// A parsed part of a `multipart/form-data` request body.
public struct MultipartPart: Sendable {
    /// The form field name.
    public var name: String
    /// The reported filename, for file parts.
    public var filename: String?
    /// The part's `Content-Type`, for file parts.
    public var contentType: String?
    /// The decoded part payload.
    public var value: String
}

/// Parses the `multipart/form-data` body of the given request.
///
/// - Parameter request: The request whose `Content-Type` header and body are
///   parsed.
/// - Returns: The request's multipart parts in body order.
public func parseMultipartParts(of request: URLRequest) -> [MultipartPart] {
    let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
    guard let boundary = contentType.components(separatedBy: "boundary=").last, !boundary.isEmpty else {
        return []
    }

    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var parts: [MultipartPart] = []

    for chunk in body.components(separatedBy: "--" + boundary).dropFirst() {
        var text = chunk
        guard !text.hasPrefix("--") else { continue }
        if text.hasPrefix("\r\n") { text.removeFirst() }
        guard let separator = text.range(of: "\r\n\r\n") else { continue }

        let headerBlock = String(text[text.startIndex..<separator.lowerBound])
        var value = String(text[separator.upperBound...])
        if value.hasSuffix("\r\n") { value.removeLast() }

        var name: String?
        var filename: String?
        var partContentType: String?
        for line in headerBlock.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition") {
                name = quotedValue(marker: "name=", in: line)
                filename = quotedValue(marker: "filename=", in: line)
            } else if lower.hasPrefix("content-type:") {
                partContentType = line
                    .components(separatedBy: ":")
                    .dropFirst()
                    .joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        parts.append(MultipartPart(name: name ?? "", filename: filename, contentType: partContentType, value: value))
    }

    return parts
}

/// Returns the quoted value following `marker` in a header line.
private func quotedValue(marker: String, in line: String) -> String? {
    guard let range = line.range(of: marker) else { return nil }
    let remainder = line[range.upperBound...]
    guard remainder.hasPrefix("\"") else { return nil }
    return String(remainder.dropFirst().prefix { $0 != "\"" })
}
