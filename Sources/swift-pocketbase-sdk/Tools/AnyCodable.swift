import Foundation

public struct AnyCodable: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let value: AnySendable

    public enum AnySendable: Equatable, Hashable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }

    public var intValue: Int? {
        if case .int(let i) = value { return i }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = value { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = value { return b }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = value { return s }
        return nil
    }

    public var arrayValue: [AnyCodable]? {
        if case .array(let a) = value { return a }
        return nil
    }

    public var dictionaryValue: [String: AnyCodable]? {
        if case .dictionary(let d) = value { return d }
        return nil
    }

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
        case .array(let a):
            try container.encode(a)
        case .dictionary(let d):
            try container.encode(d)
        }
    }

    public var description: String {
        switch value {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array(let a): return "[\(a.map { $0.description }.joined(separator: ", "))]"
        case .dictionary(let d):
            let pairs = d.map { "\"\($0.key)\": \($0.value.description)" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
    }

    public var rawValue: Any? {
        switch value {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.rawValue }
        case .dictionary(let d): return d.mapValues { $0.rawValue }
        }
    }
}

extension AnyCodable: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self.init(nil) }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self.init(value) }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self.init(value) }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self.init(value) }
}

extension AnyCodable: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyCodable...) {
        self.value = .array(elements)
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyCodable)...) {
        var dict: [String: AnyCodable] = [:]
        for (k, v) in elements {
            dict[k] = v
        }
        self.value = .dictionary(dict)
    }
}
