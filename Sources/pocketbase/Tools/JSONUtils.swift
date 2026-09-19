import Foundation

/// Formats a `Double` the way PocketBase expects it on the wire: plain
/// decimal notation built from the shortest round-trip digits.
///
/// Swift's `String(_:)` switches to scientific notation for values below
/// `1e-4` and from `1e16` upwards, and keeps a `.0` suffix on whole numbers.
/// PocketBase's filter parser does not support scientific notation, so the
/// exponent is expanded here instead (`1e-05` becomes `0.00001`) and the
/// trailing `.0` is dropped (`1.0` becomes `1`). This matches the JavaScript
/// and Dart SDKs for the common `1e-6 ... 1e21` range; outside of it the
/// output stays plain decimal, which the server always accepts.
///
/// - Parameter value: The value to format.
/// - Returns: The plain decimal representation, or `NaN`, `Infinity` or
///   `-Infinity` for the corresponding non-finite values.
func jsNumberString(_ value: Double) -> String {
    if value.isNaN {
        return "NaN"
    }
    if value.isInfinite {
        return value < 0 ? "-Infinity" : "Infinity"
    }
    if value == 0 {
        return "0"
    }

    let description = String(value)
    guard let exponentIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
        if description.hasSuffix(".0") {
            return String(description.dropLast(2))
        }
        return description
    }

    let mantissa = description[..<exponentIndex]
    let exponent = Int(description[description.index(after: exponentIndex)...]) ?? 0
    let isNegative = mantissa.hasPrefix("-")
    let digits = String(mantissa.filter { $0.isNumber })

    let integerLength: Int
    if let dotIndex = mantissa.firstIndex(of: ".") {
        integerLength = mantissa.distance(from: mantissa.startIndex, to: dotIndex) - (isNegative ? 1 : 0)
    } else {
        integerLength = digits.count
    }
    let decimalPosition = integerLength + exponent

    let body: String
    if decimalPosition <= 0 {
        body = "0." + String(repeating: "0", count: -decimalPosition) + digits
    } else if decimalPosition >= digits.count {
        body = digits + String(repeating: "0", count: decimalPosition - digits.count)
    } else {
        let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
        body = String(digits[..<split]) + "." + String(digits[split...])
    }

    return isNegative ? "-" + body : body
}

/// Escapes a string exactly like JavaScript's `JSON.stringify`, including the
/// surrounding double quotes.
///
/// `"`, `\` and the `\b`, `\f`, `\n`, `\r` and `\t` control characters use
/// their short escape forms, all other control characters become `\u00xx` and
/// everything else (including `/`) is kept as-is.
///
/// - Parameter value: The string to escape.
/// - Returns: The quoted, escaped JSON string literal.
func jsonEscapedString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        case "\u{08}":
            result += "\\b"
        case "\u{0C}":
            result += "\\f"
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\t":
            result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

/// Serializes an ``AnyCodable`` to JSON text using the same rules as the
/// JavaScript SDK: plain decimal numbers, `null` for non-finite doubles,
/// dates as ISO-8601 strings and object keys sorted for deterministic output.
///
/// - Parameter value: The value to serialize.
/// - Returns: The JSON text.
func jsonStringify(_ value: AnyCodable) -> String {
    switch value.value {
    case .null:
        return "null"
    case .bool(let bool):
        return bool ? "true" : "false"
    case .int(let int):
        return String(int)
    case .double(let double):
        return double.isFinite ? jsNumberString(double) : "null"
    case .string(let string):
        return jsonEscapedString(string)
    case .date(let date):
        return jsonEscapedString(date.pocketBaseISO8601)
    case .array(let array):
        return "[" + array.map(jsonStringify).joined(separator: ",") + "]"
    case .dictionary(let dictionary):
        let pairs = dictionary.keys.sorted().compactMap { key -> String? in
            guard let entry = dictionary[key] else { return nil }
            return jsonEscapedString(key) + ":" + jsonStringify(entry)
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }
}
