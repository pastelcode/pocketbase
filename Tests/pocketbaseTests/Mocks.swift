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
