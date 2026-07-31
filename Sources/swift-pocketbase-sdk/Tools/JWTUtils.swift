import Foundation

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
    /// Tokens without `exp` payload key are considered valid.
    /// Tokens with empty payload (e.g. invalid token strings) are considered expired.
    public static func isTokenExpired(_ token: String, expirationThreshold: Double = 0) -> Bool {
        let payload = getTokenPayload(token)
        if payload.isEmpty {
            return true
        }

        if let expVal = payload["exp"] {
            let expDouble: Double?
            switch expVal.value {
            case .int(let i): expDouble = Double(i)
            case .double(let d): expDouble = d
            default: expDouble = nil
            }

            if let exp = expDouble {
                let now = Date().timeIntervalSince1970
                if exp - expirationThreshold > now {
                    return false
                }
                return true
            }
        }

        return false
    }
}
