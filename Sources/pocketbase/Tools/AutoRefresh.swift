import Foundation

/// Registers and removes automatic token refresh hooks on a ``PocketBase`` client.
public struct AutoRefresh: Sendable {
    /// Removes the auto-refresh hook previously registered on `client`.
    ///
    /// - Parameter client: The client whose hook should be removed.
    public static func resetAutoRefresh(_ client: PocketBase) {
        client.resetAutoRefreshHook()
    }

    /// Installs a hook that refreshes or re-authenticates before requests.
    ///
    /// The hook runs before every request whose options do not bypass it via
    /// ``SendOptions/autoRefresh`` or a truthy `query["autoRefresh"]` value. If
    /// the stored token is valid but expires within `threshold` seconds,
    /// `refreshFunc` is invoked; if the token is invalid or the refresh fails,
    /// `reauthenticateFunc` is invoked. Any previously registered hook is
    /// removed first, and the hook resets itself when the auth store is cleared
    /// or switches record.
    ///
    /// ```swift
    /// AutoRefresh.registerAutoRefresh(
    ///     pb,
    ///     threshold: 60,
    ///     refreshFunc: {
    ///         let _: RecordAuthResponse<RecordModel> = try await pb.collection("users").authRefresh()
    ///     },
    ///     reauthenticateFunc: {
    ///         let _: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithPassword(
    ///             usernameOrEmail: "user@example.com",
    ///             password: "secret"
    ///         )
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - client: The client to attach the hook to.
    ///   - threshold: The refresh threshold in seconds. A valid token that
    ///     expires within this window is refreshed.
    ///   - refreshFunc: Asynchronously refreshes the auth token. Errors are
    ///     treated as a failed refresh and trigger reauthentication.
    ///   - reauthenticateFunc: Asynchronously re-authenticates the user.
    ///     Errors propagate to the pending request.
    public static func registerAutoRefresh(
        _ client: PocketBase,
        threshold: Double,
        refreshFunc: @escaping @Sendable () async throws -> Void,
        reauthenticateFunc: @escaping @Sendable () async throws -> Void
    ) {
        resetAutoRefresh(client)

        let oldBeforeSend = client.beforeSend
        let oldRecord = client.authStore.record

        // The client and store references are weak so that registering the
        // hooks does not keep a released client (and its services) alive.
        let unsubStore = client.authStore.onChange { [weak client] newToken, model in
            let newCollection = model?.collectionId ?? ""
            let oldCollection = oldRecord?.collectionId ?? ""
            let shouldReset = newToken.isEmpty ||
                model?.id != oldRecord?.id ||
                ((!newCollection.isEmpty || !oldCollection.isEmpty) && newCollection != oldCollection)

            guard shouldReset, let client = client else { return }
            resetAutoRefresh(client)
        }

        client.setAutoRefreshResetHandler { [weak client] in
            unsubStore()
            client?.beforeSend = oldBeforeSend
        }

        client.beforeSend = { [weak client] url, sendOptions in
            guard let client = client else {
                return (url, sendOptions)
            }

            let oldToken = client.authStore.token

            let bypassesAutoRefresh = sendOptions.autoRefresh == true ||
                sendOptions.query["autoRefresh"]?.boolValue == true
            if bypassesAutoRefresh {
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
