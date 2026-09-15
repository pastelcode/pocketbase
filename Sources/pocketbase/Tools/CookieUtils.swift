import Foundation

/// Attributes applied when serializing a cookie.
public struct CookieSerializeOptions: Sendable {
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
    /// The cookie priority (`"low"`, `"medium"`, or `"high"`).
    public var priority: String? // "low", "medium", "high"
    /// The SameSite policy: `"lax"`, `"strict"`, `"none"`, or `"true"` (which maps to `Strict`).
    public var sameSite: String? // "lax", "strict", "none", or "true" -> "Strict"

    /// Creates a set of cookie attributes.
    ///
    /// - Parameters:
    ///   - maxAge: The cookie lifetime in seconds.
    ///   - domain: The cookie domain.
    ///   - path: The cookie path.
    ///   - expires: The absolute expiration date.
    ///   - httpOnly: Whether the browser should only expose the cookie over HTTP.
    ///   - secure: Whether the cookie should only be sent over HTTPS.
    ///   - priority: The cookie priority (`"low"`, `"medium"`, or `"high"`).
    ///   - sameSite: The SameSite policy: `"lax"`, `"strict"`, `"none"`, or
    ///     `"true"` (which maps to `Strict`).
    public init(
        maxAge: Double? = nil,
        domain: String? = nil,
        path: String? = nil,
        expires: Date? = nil,
        httpOnly: Bool? = nil,
        secure: Bool? = nil,
        priority: String? = nil,
        sameSite: String? = nil
    ) {
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

/// Helpers for parsing and serializing HTTP cookies.
public struct CookieUtils: Sendable {
    /// Parses a `Cookie` header string.
    ///
    /// Only the first occurrence of each cookie name is kept and surrounding
    /// double quotes are removed from values.
    ///
    /// - Parameter str: The raw `Cookie` header string.
    /// - Returns: A dictionary of percent-decoded cookie values keyed by name.
    public static func cookieParse(_ str: String) -> [String: String] {
        var result: [String: String] = [:]
        guard !str.isEmpty else { return result }

        let pairs = str.components(separatedBy: ";")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var val = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }

            if result[key] == nil {
                let decoded = val.removingPercentEncoding ?? val
                result[key] = decoded
            }
        }

        return result
    }

    /// Serializes a name/value pair into a `Set-Cookie` header value.
    ///
    /// The value is percent-encoded and the provided attributes are appended.
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - val: The cookie value.
    ///   - options: The attributes to append. Defaults to `nil`.
    /// - Returns: The serialized cookie string.
    public static func cookieSerialize(name: String, val: String, options: CookieSerializeOptions? = nil) -> String {
        let encodedVal = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
        var result = "\(name)=\(encodedVal)"

        guard let opt = options else { return result }

        if let maxAge = opt.maxAge {
            result += "; Max-Age=\(Int(floor(maxAge)))"
        }

        if let domain = opt.domain {
            result += "; Domain=\(domain)"
        }

        if let path = opt.path {
            result += "; Path=\(path)"
        }

        if let expires = opt.expires {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            result += "; Expires=\(formatter.string(from: expires))"
        }

        if opt.httpOnly == true {
            result += "; HttpOnly"
        }

        if opt.secure == true {
            result += "; Secure"
        }

        if let priority = opt.priority?.lowercased() {
            switch priority {
            case "low": result += "; Priority=Low"
            case "medium": result += "; Priority=Medium"
            case "high": result += "; Priority=High"
            default: break
            }
        }

        if let sameSite = opt.sameSite?.lowercased() {
            switch sameSite {
            case "true", "strict": result += "; SameSite=Strict"
            case "lax": result += "; SameSite=Lax"
            case "none": result += "; SameSite=None"
            default: break
            }
        }

        return result
    }
}
