import Foundation

/// Helpers for decoding and inspecting JSON Web Token payloads.
///
/// The utilities read the token's payload segment without verifying its
/// signature. Use them only for client-side expiration and claim inspection.
public struct JWTUtils: Sendable {
    /// Returns JWT token's payload data without validating signature.
    public static func getTokenPayload(_ token: String) -> [String: AnyCodable] {
        guard !token.isEmpty else { return [:] }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return [:] }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64) else { return [:] }

        let decoder = JSONDecoder()
        if let payload = try? decoder.decode([String: AnyCodable].self, from: data) {
            return payload
        }
        return [:]
    }

    /// Checks whether a JWT token is expired or not.
    ///
    /// Matches the reference SDK's truth table:
    ///
    /// - A token with an empty payload (for example an invalid token string) is
    ///   considered expired.
    /// - A payload without `exp`, or with a falsy `exp` (`0`, `null`, `false`
    ///   or an empty string), is considered valid.
    /// - A numeric `exp` (including numeric strings) is valid when
    ///   `exp - expirationThreshold` is in the future.
    /// - Any other non-numeric `exp` value is considered expired.
    ///
    /// - Parameters:
    ///   - token: The JWT token to inspect.
    ///   - expirationThreshold: Seconds subtracted from `exp` before the
    ///     comparison. Defaults to `0`.
    /// - Returns: `true` when the token is expired or malformed.
    public static func isTokenExpired(_ token: String, expirationThreshold: Double = 0) -> Bool {
        let payload = getTokenPayload(token)
        if payload.isEmpty {
            return true
        }

        guard let expVal = payload["exp"] else {
            return false
        }

        // Falsy `exp` values are treated as "no expiration" by the reference SDK.
        if isFalsy(expVal) {
            return false
        }

        guard let exp = numericValue(expVal) else {
            // Non-numeric values produce `NaN` comparisons in the reference SDK.
            return true
        }

        return !(exp - expirationThreshold > Date().timeIntervalSince1970)
    }

    /// Returns whether the value is falsy in JavaScript (`0`, `null`, `false`
    /// or an empty string).
    private static func isFalsy(_ value: AnyCodable) -> Bool {
        switch value.value {
        case .null:
            return true
        case .int(let i):
            return i == 0
        case .double(let d):
            return d == 0
        case .bool(let b):
            return !b
        case .string(let s):
            return s.isEmpty
        case .date, .array, .dictionary:
            return false
        }
    }

    /// Returns the JavaScript numeric coercion of the value, or `nil` when it
    /// would produce `NaN`.
    private static func numericValue(_ value: AnyCodable) -> Double? {
        switch value.value {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d
        case .string(let s):
            return Double(s)
        case .bool(let b):
            return b ? 1 : 0
        case .null:
            return 0
        case .date, .array, .dictionary:
            return nil
        }
    }
}
