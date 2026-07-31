import Testing
import Foundation
@testable import swift_pocketbase_sdk

struct CookieTests {
    @Test func testCookieParse() {
        let empty = CookieUtils.cookieParse("")
        #expect(empty.isEmpty)

        let parsed = CookieUtils.cookieParse("foo=bar; abc=12@3")
        #expect(parsed["foo"] == "bar")
        #expect(parsed["abc"] == "12@3")
    }

    @Test func testCookieSerialize() {
        let empty = CookieUtils.cookieSerialize(name: "test_cookie", val: "")
        #expect(empty == "test_cookie=")

        let simple = CookieUtils.cookieSerialize(name: "test_cookie", val: "abc")
        #expect(simple == "test_cookie=abc")

        let options = CookieSerializeOptions(
            maxAge: 123,
            domain: "test.com",
            path: "/abc/",
            expires: Date(timeIntervalSince1970: 1640995200), // 2022-01-01 00:00:00 GMT
            httpOnly: true,
            secure: true,
            priority: "low",
            sameSite: "lax"
        )
        let full = CookieUtils.cookieSerialize(name: "test_cookie", val: "abc", options: options)
        #expect(full.contains("test_cookie=abc"))
        #expect(full.contains("Max-Age=123"))
        #expect(full.contains("Domain=test.com"))
        #expect(full.contains("Path=/abc/"))
        #expect(full.contains("HttpOnly"))
        #expect(full.contains("Secure"))
        #expect(full.contains("Priority=Low"))
        #expect(full.contains("SameSite=Lax"))
    }
}
