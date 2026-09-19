import Testing
import Foundation
@testable import pocketbase

struct JSONUtilsTests {
    @Test func numberFormattingUsesPlainDecimalNotation() {
        #expect(jsNumberString(0) == "0")
        #expect(jsNumberString(-0.0) == "0")
        #expect(jsNumberString(1.0) == "1")
        #expect(jsNumberString(-1.0) == "-1")
        #expect(jsNumberString(123.45) == "123.45")
        #expect(jsNumberString(-123.45) == "-123.45")
        #expect(jsNumberString(0.1 + 0.2) == "0.30000000000000004")
    }

    @Test func numberFormattingExpandsScientificNotation() {
        #expect(jsNumberString(0.0001) == "0.0001")
        #expect(jsNumberString(1e-6) == "0.000001")
        #expect(jsNumberString(1e-7) == "0.0000001")
        #expect(jsNumberString(1.5e-7) == "0.00000015")
        #expect(jsNumberString(1e15) == "1000000000000000")
        #expect(jsNumberString(1e16) == "10000000000000000")
        #expect(jsNumberString(1e20) == "100000000000000000000")
        #expect(jsNumberString(1e21) == "1000000000000000000000")
        #expect(jsNumberString(-1e16) == "-10000000000000000")
    }

    @Test func numberFormattingHandlesNonFiniteValues() {
        #expect(jsNumberString(Double.nan) == "NaN")
        #expect(jsNumberString(Double.infinity) == "Infinity")
        #expect(jsNumberString(-Double.infinity) == "-Infinity")
    }

    @Test func stringEscapingMatchesJSONStringify() {
        #expect(jsonEscapedString("plain") == "\"plain\"")
        #expect(jsonEscapedString("a'b") == "\"a'b\"")
        #expect(jsonEscapedString("a\"b") == "\"a\\\"b\"")
        #expect(jsonEscapedString("a\\b") == "\"a\\\\b\"")
        #expect(jsonEscapedString("a\nb") == "\"a\\nb\"")
        #expect(jsonEscapedString("a\tb\rc") == "\"a\\tb\\rc\"")
        #expect(jsonEscapedString("\u{08}\u{0C}") == "\"\\b\\f\"")
        #expect(jsonEscapedString("\u{01}") == "\"\\u0001\"")
        #expect(jsonEscapedString("a/b") == "\"a/b\"")
        #expect(jsonEscapedString("café") == "\"café\"")
    }

    @Test func jsonStringifyEncodesValuesLikeJavaScript() {
        #expect(jsonStringify(AnyCodable(nil)) == "null")
        #expect(jsonStringify(AnyCodable(true)) == "true")
        #expect(jsonStringify(AnyCodable(false)) == "false")
        #expect(jsonStringify(AnyCodable(123)) == "123")
        #expect(jsonStringify(AnyCodable(1.0)) == "1")
        #expect(jsonStringify(AnyCodable(1e-6)) == "0.000001")
        #expect(jsonStringify(AnyCodable(Double.nan)) == "null")
        #expect(jsonStringify(AnyCodable("a\"b/c")) == "\"a\\\"b/c\"")
        #expect(jsonStringify(AnyCodable([1, "a"] as [Any])) == "[1,\"a\"]")
        #expect(jsonStringify(AnyCodable(["b": 1, "a": 2])) == "{\"a\":2,\"b\":1}")
        #expect(jsonStringify(AnyCodable(Date(timeIntervalSince1970: 0))) == "\"1970-01-01T00:00:00.000Z\"")
    }
}
