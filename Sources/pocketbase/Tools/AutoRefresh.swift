import Foundation

public struct AutoRefresh: Sendable {
    public static func resetAutoRefresh(_ client: PocketBase) {
        client.resetAutoRefreshHook()
    }

    public static func registerAutoRefresh(
        _ client: PocketBase,
        threshold: Double,
        refreshFunc: @escaping @Sendable () async throws -> Void,
        reauthenticateFunc: @escaping @Sendable () async throws -> Void
    ) {
        resetAutoRefresh(client)

        let oldBeforeSend = client.beforeSend
        let oldRecord = client.authStore.record

        let unsubStore = client.authStore.onChange { newToken, model in
            if newToken.isEmpty ||
                model?.id != oldRecord?.id ||
                ((model?.collectionId != nil || oldRecord?.collectionId != nil) &&
                    model?.collectionId != oldRecord?.collectionId) {
                resetAutoRefresh(client)
            }
        }

        client.setAutoRefreshResetHandler {
            unsubStore()
            client.beforeSend = oldBeforeSend
        }

        client.beforeSend = { url, sendOptions in
            let oldToken = client.authStore.token

            if sendOptions.autoRefresh == true {
                if let old = oldBeforeSend {
                    return try await old(url, sendOptions)
                }
                return (url, sendOptions)
            }

            var isValid = client.authStore.isValid
            if isValid && JWTUtils.isTokenExpired(client.authStore.token, expirationThreshold: threshold) {
                do {
                    try await refreshFunc()
                } catch {
                    isValid = false
                }
            }

            if !isValid {
                try await reauthenticateFunc()
            }

            var options = sendOptions
            for (key, val) in options.headers {
                if key.lowercased() == "authorization" && val == oldToken && !client.authStore.token.isEmpty {
                    options.headers[key] = client.authStore.token
                    break
                }
            }

            if let old = oldBeforeSend {
                return try await old(url, options)
            }
            return (url, options)
        }
    }
}
