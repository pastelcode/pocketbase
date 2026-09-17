import Foundation

/// Errors thrown when serializing an invalid cookie.
public enum CookieSerializeError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The cookie name is empty or contains characters outside the RFC 7230
    /// `field-content` range.
    case invalidName
    /// The encoded cookie value contains characters outside the RFC 7230
    /// `field-content` range.
    case invalidValue
    /// `maxAge` is `NaN` or infinite.
    case invalidMaxAge
    /// The cookie domain is invalid.
    case invalidDomain
    /// The cookie path is invalid.
    case invalidPath
    /// The expiration date is invalid.
    case invalidExpires
    /// The priority is not `low`, `medium` or `high`.
    case invalidPriority
    /// The SameSite policy is invalid.
    case invalidSameSite

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case .invalidName: return "argument name is invalid"
        case .invalidValue: return "argument val is invalid"
        case .invalidMaxAge: return "option maxAge is invalid"
        case .invalidDomain: return "option domain is invalid"
        case .invalidPath: return "option path is invalid"
        case .invalidExpires: return "option expires is invalid"
        case .invalidPriority: return "option priority is invalid"
        case .invalidSameSite: return "option sameSite is invalid"
        }
    }
}

/// The `SameSite` attribute of a cookie.
public enum CookieSameSite: Sendable, Equatable {
    /// The `SameSite` attribute is omitted.
    case unspecified
    /// `SameSite=Strict`.
    case strict
    /// `SameSite=Lax`.
    case lax
    /// `SameSite=None`.
    case none
}

extension CookieSameSite {
    /// Creates a policy from the reference SDK's boolean form: `true` behaves
    /// like ``strict`` and `false` omits the attribute.
    ///
    /// - Parameter flag: The boolean `SameSite` value.
    public init(_ flag: Bool) {
        self = flag ? .strict : .unspecified
    }
}

/// Attributes applied when serializing a cookie.
public struct CookieSerializeOptions: Sendable {
    /// Custom encoder applied to the cookie value.
    ///
    /// Defaults to percent-encoding (JavaScript's `encodeURIComponent`) when `nil`.
    public var encode: (@Sendable (String) -> String)?
    /// The cookie lifetime in seconds.
    public var maxAge: Double?
    /// The cookie domain.
    public var domain: String?
    /// The cookie path.
    public var path: String?
    /// The absolute expiration date.
    public var expires: Date?
    /// Whether the browser should only expose the cookie over HTTP.
    public var httpOnly: Bool?
    /// Whether the cookie should only be sent over HTTPS.
    public var secure: Bool?
    /// The cookie priority (`"low"`, `"medium"` or `"high"`).
    public var priority: String?
    /// The `SameSite` policy. Defaults to ``CookieSameSite/unspecified``.
    public var sameSite: CookieSameSite

    /// Creates a set of cookie attributes.
    ///
    /// - Parameters:
    ///   - encode: Custom value encoder. Defaults to `nil` (percent-encoding).
    ///   - maxAge: The cookie lifetime in seconds.
    ///   - domain: The cookie domain.
    ///   - path: The cookie path.
    ///   - expires: The absolute expiration date.
    ///   - httpOnly: Whether the browser should only expose the cookie over HTTP.
    ///   - secure: Whether the cookie should only be sent over HTTPS.
    ///   - priority: The cookie priority (`"low"`, `"medium"` or `"high"`).
    ///   - sameSite: The `SameSite` policy.
    public init(
        encode: (@Sendable (String) -> String)? = nil,
        maxAge: Double? = nil,
        domain: String? = nil,
        path: String? = nil,
        expires: Date? = nil,
        httpOnly: Bool? = nil,
        secure: Bool? = nil,
        priority: String? = nil,
        sameSite: CookieSameSite = .unspecified
    ) {
        self.encode = encode
        self.maxAge = maxAge
        self.domain = domain
        self.path = path
        self.expires = expires
        self.httpOnly = httpOnly
        self.secure = secure
        self.priority = priority
        self.sameSite = sameSite
    }
}

/// Attributes applied when parsing a cookie header.
public struct CookieParseOptions: Sendable {
    /// Custom decoder applied to cookie values.
    ///
    /// Defaults to percent-decoding when `nil`. A throwing decoder falls back to
    /// the raw value, matching the reference SDK.
    public var decode: (@Sendable (String) throws -> String)?

    /// Creates a set of cookie parsing options.
    ///
    /// - Parameter decode: Custom value decoder. Defaults to `nil`.
    public init(decode: (@Sendable (String) throws -> String)? = nil) {
        self.decode = decode
    }
}

/// Helpers for parsing and serializing HTTP cookies.
public struct CookieUtils: Sendable {
    /// Parses a `Cookie` header string.
    ///
    /// Matches the reference SDK: only the first occurrence of each cookie name
    /// is kept, surrounding double quotes are stripped, and values are
    /// percent-decoded unless a custom decoder is provided.
    ///
    /// - Parameters:
    ///   - str: The raw `Cookie` header string.
    ///   - options: Optional parsing options.
    /// - Returns: A dictionary of decoded cookie values keyed by name.
    public static func cookieParse(_ str: String, options: CookieParseOptions? = nil) -> [String: String] {
        var result: [String: String] = [:]
        guard !str.isEmpty else { return result }

        let characters = Array(str)
        var index = 0

        while index < characters.count {
            guard let eqIdx = characters[index...].firstIndex(of: "=") else {
                break
            }

            let endIdx = characters[index...].firstIndex(of: ";") ?? characters.count
            if endIdx < eqIdx {
                // Backtrack on a prior semicolon: it belongs to the previous pair.
                if let prior = characters[..<eqIdx].lastIndex(of: ";") {
                    index = prior + 1
                } else {
                    index = endIdx + 1
                }
                continue
            }

            let key = String(characters[index..<eqIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if result[key] == nil {
                var val = String(characters[(eqIdx + 1)..<endIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if val.hasPrefix("\"") {
                    val = String(val.dropFirst().dropLast())
                }

                if let decode = options?.decode {
                    result[key] = (try? decode(val)) ?? val
                } else {
                    result[key] = val.contains("%") ? (val.removingPercentEncoding ?? val) : val
                }
            }

            index = endIdx + 1
        }

        return result
    }

    /// Serializes a name/value pair into a `Set-Cookie` header value.
    ///
    /// The value is percent-encoded by default and the provided attributes are
    /// appended. Invalid names, values and attributes throw a
    /// ``CookieSerializeError`` instead of being silently ignored.
    ///
    /// ```swift
    /// let cookie = try CookieUtils.cookieSerialize(
    ///     name: "pb_auth",
    ///     val: payload,
    ///     options: CookieSerializeOptions(httpOnly: true, secure: true, sameSite: .strict)
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - val: The cookie value.
    ///   - options: The attributes to append. Defaults to `nil`.
    /// - Returns: The serialized cookie string.
    /// - Throws: A ``CookieSerializeError`` when the name, value or an
    ///   attribute is invalid.
    public static func cookieSerialize(
        name: String,
        val: String,
        options: CookieSerializeOptions? = nil
    ) throws -> String {
        let opt = options ?? CookieSerializeOptions()
        let encode = opt.encode ?? { (value: String) in value.encodeURIComponent() }

        guard isValidFieldContent(name) else {
            throw CookieSerializeError.invalidName
        }

        let value = encode(val)
        if !value.isEmpty && !isValidFieldContent(value) {
            throw CookieSerializeError.invalidValue
        }

        var result = "\(name)=\(value)"

        if let maxAge = opt.maxAge {
            guard maxAge.isFinite else {
                throw CookieSerializeError.invalidMaxAge
            }
            let floored = floor(maxAge)
            guard floored >= Double(Int64.min), floored <= Double(Int64.max) else {
                throw CookieSerializeError.invalidMaxAge
            }
            result += "; Max-Age=\(Int64(floored))"
        }

        if let domain = opt.domain, !domain.isEmpty {
            guard isValidFieldContent(domain) else {
                throw CookieSerializeError.invalidDomain
            }
            result += "; Domain=\(domain)"
        }

        if let path = opt.path, !path.isEmpty {
            guard isValidFieldContent(path) else {
                throw CookieSerializeError.invalidPath
            }
            result += "; Path=\(path)"
        }

        if let expires = opt.expires {
            guard expires.timeIntervalSince1970.isFinite else {
                throw CookieSerializeError.invalidExpires
            }
            result += "; Expires=\(httpDateString(expires))"
        }

        if opt.httpOnly == true {
            result += "; HttpOnly"
        }

        if opt.secure == true {
            result += "; Secure"
        }

        if let priority = opt.priority, !priority.isEmpty {
            switch priority.lowercased() {
            case "low": result += "; Priority=Low"
            case "medium": result += "; Priority=Medium"
            case "high": result += "; Priority=High"
            default: throw CookieSerializeError.invalidPriority
            }
        }

        switch opt.sameSite {
        case .unspecified: break
        case .strict: result += "; SameSite=Strict"
        case .lax: result += "; SameSite=Lax"
        case .none: result += "; SameSite=None"
        }

        return result
    }

    /// Returns whether the value matches the RFC 7230 `field-content` range
    /// (`HTAB`, printable ASCII and `obs-text`), matching the reference regex.
    private static func isValidFieldContent(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return code == 0x09 || (0x20...0x7E).contains(code) || (0x80...0xFF).contains(code)
        }
    }

    /// Formats a date like JavaScript's `Date.toUTCString()`.
    private static func httpDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
