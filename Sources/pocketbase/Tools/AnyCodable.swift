import Foundation

/// A type-erased, JSON-compatible value.
///
/// `AnyCodable` wraps supported values in ``AnyCodable/AnySendable`` and adds
/// `Codable`, `Equatable`, `Hashable`, and literal conformances so arbitrary
/// values can flow through ``SendOptions`` query parameters and bodies.
///
/// ```swift
/// let options = SendOptions(query: [
///     "page": 1,
///     "active": true,
///     "tags": ["a", "b"],
/// ])
/// ```
public struct AnyCodable: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The wrapped value.
    public let value: AnySendable

    /// The possible values an ``AnyCodable`` can hold.
    public enum AnySendable: Equatable, Hashable, Sendable {
        /// A JSON `null`.
        case null
        /// A boolean.
        case bool(Bool)
        /// An integer.
        case int(Int)
        /// A floating-point number.
        case double(Double)
        /// A string.
        case string(String)
        /// A date.
        ///
        /// Dates encode as ISO-8601 (`YYYY-MM-DDTHH:MM:SS.sssZ`) in JSON and
        /// as `YYYY-MM-DD HH:MM:SS.sssZ` (space separator, UTC) in query
        /// strings.
        case date(Date)
        /// An ordered list of values.
        case array([AnyCodable])
        /// A keyed collection of values.
        case dictionary([String: AnyCodable])
    }

    /// The wrapped value as an `Int`, or `nil` for another type.
    public var intValue: Int? {
        if case .int(let i) = value { return i }
        return nil
    }

    /// The wrapped value as a `Double`, or `nil` for another type.
    public var doubleValue: Double? {
        if case .double(let d) = value { return d }
        return nil
    }

    /// The wrapped value as a `Bool`, or `nil` for another type.
    public var boolValue: Bool? {
        if case .bool(let b) = value { return b }
        return nil
    }

    /// The wrapped value as a `String`, or `nil` for another type.
    public var stringValue: String? {
        if case .string(let s) = value { return s }
        return nil
    }

    /// The wrapped value as an array, or `nil` for another type.
    public var arrayValue: [AnyCodable]? {
        if case .array(let a) = value { return a }
        return nil
    }

    /// The wrapped value as a dictionary, or `nil` for another type.
    public var dictionaryValue: [String: AnyCodable]? {
        if case .dictionary(let d) = value { return d }
        return nil
    }

    /// Creates a value from an arbitrary input.
    ///
    /// Supported inputs are `AnyCodable`, `Bool`, `Int`, `Double`, `String`,
    /// `Date`, `[Any]`, and `[String: Any]`. Any other `Encodable` value is
    /// encoded and decoded back into a JSON-compatible representation, `nil`
    /// maps to `.null`, and unsupported values fall back to their
    /// `String(describing:)` text.
    ///
    /// - Parameter value: The value to wrap.
    public init(_ value: Any?) {
        guard let value = value else {
            self.value = .null
            return
        }

        if let anyCodable = value as? AnyCodable {
            self = anyCodable
        } else if let boolVal = value as? Bool {
            self.value = .bool(boolVal)
        } else if let intVal = value as? Int {
            self.value = .int(intVal)
        } else if let doubleVal = value as? Double {
            self.value = .double(doubleVal)
        } else if let stringVal = value as? String {
            self.value = .string(stringVal)
        } else if let dateVal = value as? Date {
            self.value = .date(dateVal)
        } else if let arrayVal = value as? [Any] {
            self.value = .array(arrayVal.map { AnyCodable($0) })
        } else if let dictVal = value as? [String: Any] {
            self.value = .dictionary(dictVal.mapValues { AnyCodable($0) })
        } else if let encodable = value as? Encodable,
                  let data = try? JSONEncoder().encode(encodable),
                  let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            self = decoded
        } else {
            self.value = .string(String(describing: value))
        }
    }

    /// Decodes a JSON-compatible value from the given decoder.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorruptedError` when the value is not a
    ///   supported JSON type.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self.value = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self.value = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self.value = .string(stringVal)
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            self.value = .array(arrayVal)
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            self.value = .dictionary(dictVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }

    /// Encodes the wrapped value into the given encoder.
    ///
    /// Dates are encoded as ISO-8601 strings.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: Rethrows errors from the underlying single-value container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .date(let d):
            try container.encode(d.pocketBaseISO8601)
        case .array(let a):
            try container.encode(a)
        case .dictionary(let d):
            try container.encode(d)
        }
    }

    /// A human-readable, JSON-like representation of the wrapped value.
    public var description: String {
        switch value {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .date(let d): return d.pocketBaseISO8601
        case .array(let a): return "[\(a.map { $0.description }.joined(separator: ", "))]"
        case .dictionary(let d):
            let pairs = d.map { "\"\($0.key)\": \($0.value.description)" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
    }

    /// The wrapped value converted back to a Swift `Any?`.
    ///
    /// Arrays and dictionaries are converted recursively. `null` maps to `nil`.
    public var rawValue: Any? {
        switch value {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .date(let d): return d
        case .array(let a): return a.map { $0.rawValue }
        case .dictionary(let d): return d.mapValues { $0.rawValue }
        }
    }
}

/// Allows `nil` to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByNilLiteral {
    /// Creates a `.null` value.
    public init(nilLiteral: ()) { self.init(nil) }
}

/// Allows boolean literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByBooleanLiteral {
    /// Creates a `.bool` value.
    public init(booleanLiteral value: Bool) { self.init(value) }
}

/// Allows integer literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByIntegerLiteral {
    /// Creates an `.int` value.
    public init(integerLiteral value: Int) { self.init(value) }
}

/// Allows floating-point literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByFloatLiteral {
    /// Creates a `.double` value.
    public init(floatLiteral value: Double) { self.init(value) }
}

/// Allows string literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByStringLiteral {
    /// Creates a `.string` value.
    public init(stringLiteral value: String) { self.init(value) }
}

/// Allows array literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByArrayLiteral {
    /// Creates an `.array` value from the given elements.
    public init(arrayLiteral elements: AnyCodable...) {
        self.value = .array(elements)
    }
}

/// Allows dictionary literals to be used where an ``AnyCodable`` is expected.
extension AnyCodable: ExpressibleByDictionaryLiteral {
    /// Creates a `.dictionary` value from the given key-value pairs.
    public init(dictionaryLiteral elements: (String, AnyCodable)...) {
        var dict: [String: AnyCodable] = [:]
        for (k, v) in elements {
            dict[k] = v
        }
        self.value = .dictionary(dict)
    }
}

extension Date {
    /// ISO-8601 timestamp matching JavaScript's `Date.toISOString()`
    /// (UTC, millisecond precision, `Z` suffix).
    ///
    /// Query string serialization replaces the `T` separator with a space,
    /// producing `YYYY-MM-DD HH:MM:SS.sssZ`.
    var pocketBaseISO8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: self)
    }
}
