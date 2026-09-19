import Foundation

/// Helpers for decoding and inspecting JSON Web Token payloads.
///
/// The utilities read the token's payload segment without verifying its
/// signature. Use them only for client-side expiration and claim inspection.
public struct JWTUtils: Sendable {
    /// Returns JWT token's payload data without validating signature.
    ///
    /// - Note: Base64url `-`/`_` characters are accepted. This is more
    ///   permissive than the JavaScript SDK, whose `atob`-based decoder throws
    ///   on them and returns an empty payload instead.
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
    /// The check fails closed. A token is considered expired when:
    ///
    /// - it is not a well-formed three-segment JWT,
    /// - its payload is empty, or
    /// - its `exp` claim is missing or non-numeric.
    ///
    /// A numeric `exp` (including numeric strings) is valid while
    /// `exp - expirationThreshold` is in the future.
    ///
    /// - Note: This is stricter than the JavaScript SDK, which treats a missing
    ///   or falsy `exp` as "never expires". Failing closed is safer because the
    ///   token signature is not verified. ``BaseAuthStore/isValid`` applies the
    ///   same rules.
    ///
    /// - Parameters:
    ///   - token: The JWT token to inspect.
    ///   - expirationThreshold: Seconds subtracted from `exp` before the
    ///     comparison. Defaults to `0`.
    /// - Returns: `true` when the token is expired or malformed.
    public static func isTokenExpired(_ token: String, expirationThreshold: Double = 0) -> Bool {
        guard let expiration = getExpirationTimestamp(token) else {
            return true
        }
        return !(expiration - expirationThreshold > Date().timeIntervalSince1970)
    }

    /// Returns the token's `exp` claim as a Unix timestamp.
    ///
    /// The token must be a well-formed three-segment JWT and the claim must be
    /// a number (or a numeric string). A missing or non-numeric `exp` returns
    /// `nil` instead of being treated as "never expires".
    ///
    /// Used by ``isTokenExpired(_:expirationThreshold:)`` and
    /// ``BaseAuthStore/isValid``.
    ///
    /// - Parameter token: The JWT token to inspect.
    /// - Returns: The expiration timestamp in seconds, or `nil` when it is not
    ///   available.
    public static func getExpirationTimestamp(_ token: String) -> Double? {
        guard token.components(separatedBy: ".").count == 3 else {
            return nil
        }

        let payload = getTokenPayload(token)
        guard let expValue = payload["exp"] else {
            return nil
        }

        switch expValue.value {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d
        case .string(let s):
            return Double(s)
        default:
            return nil
        }
    }
}
