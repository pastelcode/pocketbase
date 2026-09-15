import Testing
import Foundation
@testable import pocketbase

struct CookieTests {
    // MARK: - Parsing

    @Test func testCookieParseEmpty() {
        #expect(CookieUtils.cookieParse("").isEmpty)
    }

    @Test func testCookieParseBasic() {
        let parsed = CookieUtils.cookieParse("foo=bar; abc=12@3")
        #expect(parsed["foo"] == "bar")
        #expect(parsed["abc"] == "12@3")
    }

    @Test func testCookieParseKeepsFirstOccurrence() {
        let parsed = CookieUtils.cookieParse("foo=1; foo=2")
        #expect(parsed["foo"] == "1")
    }

    @Test func testCookieParseStripsSurroundingQuotes() {
        let parsed = CookieUtils.cookieParse("foo=\"bar\"")
        #expect(parsed["foo"] == "bar")
    }

    @Test func testCookieParsePercentDecodes() {
        let parsed = CookieUtils.cookieParse("foo=a%26b%3Dc%2Bd%3Be")
        #expect(parsed["foo"] == "a&b=c+d;e")
    }

    @Test func testCookieParseCustomDecode() {
        let options = CookieParseOptions(decode: { $0.replacingOccurrences(of: "+", with: " ") })
        let parsed = CookieUtils.cookieParse("foo=a+b", options: options)
        #expect(parsed["foo"] == "a b")
    }

    @Test func testCookieParseDecodeFailureFallsBackToRawValue() {
        let options = CookieParseOptions(decode: { _ in throw CookieSerializeError.invalidValue })
        let parsed = CookieUtils.cookieParse("foo=raw", options: options)
        #expect(parsed["foo"] == "raw")
    }

    @Test func testCookieParseSkipsPairWithoutEquals() {
        let parsed = CookieUtils.cookieParse("novalue; foo=bar")
        #expect(parsed["foo"] == "bar")
        #expect(parsed["novalue"] == nil)
    }

    // MARK: - Serialization

    @Test func testCookieSerializeBasic() throws {
        #expect(try CookieUtils.cookieSerialize(name: "test_cookie", val: "") == "test_cookie=")
        #expect(try CookieUtils.cookieSerialize(name: "test_cookie", val: "abc") == "test_cookie=abc")
    }

    @Test func testCookieSerializeEncodesReservedCharacters() throws {
        let cookie = try CookieUtils.cookieSerialize(name: "pb_auth", val: "a&b=c+d;e")
        #expect(cookie == "pb_auth=a%26b%3Dc%2Bd%3Be")
    }

    @Test func testCookieSerializeOptions() throws {
        let options = CookieSerializeOptions(
            maxAge: 123,
            domain: "test.com",
            path: "/abc/",
            expires: Date(timeIntervalSince1970: 1640995200), // 2022-01-01 00:00:00 GMT
            httpOnly: true,
            secure: true,
            priority: "low",
            sameSite: .lax
        )
        let full = try CookieUtils.cookieSerialize(name: "test_cookie", val: "abc", options: options)
        #expect(full.contains("test_cookie=abc"))
        #expect(full.contains("Max-Age=123"))
        #expect(full.contains("Domain=test.com"))
        #expect(full.contains("Path=/abc/"))
        #expect(full.contains("Expires=Sat, 01 Jan 2022 00:00:00 GMT"))
        #expect(full.contains("HttpOnly"))
        #expect(full.contains("Secure"))
        #expect(full.contains("Priority=Low"))
        #expect(full.contains("SameSite=Lax"))
    }

    @Test func testCookieSerializeSameSiteVariants() throws {
        func cookie(_ sameSite: CookieSameSite) throws -> String {
            try CookieUtils.cookieSerialize(
                name: "c",
                val: "v",
                options: CookieSerializeOptions(sameSite: sameSite)
            )
        }

        #expect(try cookie(.strict).contains("SameSite=Strict"))
        #expect(try cookie(CookieSameSite(true)).contains("SameSite=Strict"))
        #expect(try cookie(CookieSameSite(false)) == "c=v")
        #expect(try cookie(.lax).contains("SameSite=Lax"))
        #expect(try cookie(.none).contains("SameSite=None"))
        #expect(try cookie(.unspecified) == "c=v")
    }

    @Test func testCookieSerializeCustomEncoder() throws {
        let options = CookieSerializeOptions(encode: { $0.uppercased() })
        #expect(try CookieUtils.cookieSerialize(name: "c", val: "abc", options: options) == "c=ABC")
    }

    @Test func testCookieSerializeRejectsInvalidName() {
        #expect(throws: CookieSerializeError.invalidName) {
            try CookieUtils.cookieSerialize(name: "", val: "v")
        }
        #expect(throws: CookieSerializeError.invalidName) {
            try CookieUtils.cookieSerialize(name: "bad\nname", val: "v")
        }
    }

    @Test func testCookieSerializeRejectsInvalidValue() {
        // Encoding happens before validation, so a value must encode to valid
        // field-content; a custom encoder can produce invalid characters.
        let options = CookieSerializeOptions(encode: { _ in "bad\nvalue" })
        #expect(throws: CookieSerializeError.invalidValue) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: options)
        }
    }

    @Test func testCookieSerializeRejectsInvalidMaxAge() {
        #expect(throws: CookieSerializeError.invalidMaxAge) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: CookieSerializeOptions(maxAge: .infinity))
        }
        #expect(throws: CookieSerializeError.invalidMaxAge) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: CookieSerializeOptions(maxAge: .nan))
        }
    }

    @Test func testCookieSerializeRejectsInvalidAttributes() {
        #expect(throws: CookieSerializeError.invalidPriority) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: CookieSerializeOptions(priority: "urgent"))
        }
        #expect(throws: CookieSerializeError.invalidDomain) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: CookieSerializeOptions(domain: "bad\ndomain"))
        }
        #expect(throws: CookieSerializeError.invalidPath) {
            try CookieUtils.cookieSerialize(name: "c", val: "v", options: CookieSerializeOptions(path: "bad\npath"))
        }
    }
}
