import Testing
import Foundation
@testable import swift_pocketbase_sdk

struct ClientResponseErrorTests {
    @Test func testConstructorObjectValue() {
        let err = ClientResponseError(
            url: "http://example.com",
            status: 400,
            response: ["message": AnyCodable("test message")],
            isAbort: true
        )

        #expect(err.url == "http://example.com")
        #expect(err.status == 400)
        #expect(err.response["message"]?.value.string == "test message")
        #expect(err.isAbort == true)
        #expect(err.message == "test message")
    }

    @Test func testConstructorDefaultFallback() {
        let err = ClientResponseError()

        #expect(err.url == "")
        #expect(err.status == 0)
        #expect(err.response.isEmpty)
        #expect(err.isAbort == false)
        #expect(err.message == "Something went wrong.")
    }

    @Test func testConstructorAbortError() {
        let err = ClientResponseError(isAbort: true)

        #expect(err.isAbort == true)
        #expect(err.message.contains("request was aborted"))
    }
}
