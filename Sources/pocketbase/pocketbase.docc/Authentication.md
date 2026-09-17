# Authentication

Authenticate users and manage persisted auth state.

## Sign in with email and password

```swift
let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithPassword(
    usernameOrEmail: "user@example.com",
    password: "secret"
)

print(auth.token)
print(auth.record.id)
```

On success the token and record are stored in ``PocketBase/authStore`` automatically. The `Authorization` header is then attached to every subsequent request.

## Auth state

```swift
if pb.authStore.isValid {
    print("Signed in as \(pb.authStore.record?.id ?? "")")
}

pb.authStore.clear()
```

`isValid` requires a well-formed three-segment JWT with a numeric, unexpired `exp` claim (see ``JWTUtils/isTokenExpired(_:expirationThreshold:)``). Tokens without an `exp` claim, or with a malformed one, are treated as invalid — a stricter, safer check than the JavaScript SDK's.

## Persistence

Three stores are available:

- ``BaseAuthStore`` — in-memory only. Good for servers and tests.
- ``LocalAuthStore`` — persists to `UserDefaults` and reads it on every access, so every instance backed by the same suite serves the latest persisted state. This is the default.
- ``AsyncAuthStore`` — persists through your own async `save`/`clear` closures, for example to the Keychain. Operations run in the order they are enqueued, and the optional `initial` payload or `initialLoader` closure seeds the store as the first queued operation.

> Important: `UserDefaults` is convenient but not encrypted, so it is only suitable for development. For production, use ``AsyncAuthStore`` backed by the Keychain (recommended) — or another secure store — so the token is not readable from a plain-text app container or backup.

```swift
let store = AsyncAuthStore(
    save: { payload in
        try await keychain.write(payload)
    },
    clear: {
        try await keychain.delete()
    },
    initialLoader: {
        try await keychain.read()
    }
)

let pb = PocketBase(baseURL: "https://example.com", authStore: store)
```

React to changes with ``BaseAuthStore/onChange(fireImmediately:callback:)``:

```swift
let unsubscribe = pb.authStore.onChange { token, record in
    print("token changed:", token.isEmpty ? "cleared" : "set")
}
```

The callback fires for changes made through the store instance. A custom store can emit change events for external updates by calling ``BaseAuthStore/triggerChange()``, which can also be overridden — call `super` to keep notifying the registered callbacks.

## Cookies and server-side rendering

Cookies are only used to hand the auth state between a browser and a Swift server (Vapor, Hummingbird). A per-request ``PocketBase`` instance restores the state from the request's `Cookie` header and returns the updated state in a `Set-Cookie` header:

```swift
let pb = PocketBase(baseURL: "https://example.com", authStore: BaseAuthStore())

if let cookieHeader = req.headers["Cookie"].first {
    pb.authStore.loadFromCookie(cookieHeader)
}

// ... perform server-side work with the authenticated context ...

let setCookie = try pb.authStore.exportToCookie()
res.headers.add(name: "Set-Cookie", value: setCookie)
```

Native clients do not need cookies: the token lives in ``PocketBase/authStore`` and is sent as an `Authorization` header on every request, including the realtime SSE connection. Use cookies only for the browser/server handoff, preferably with `httpOnly` and `secure` so the token stays out of reach of client-side JavaScript.

## OAuth2

### Interactive flow

When the app can open a browser or web view, ``RecordService/authWithOAuth2(provider:urlCallback:scopes:createData:options:)`` runs the whole flow:

```swift
let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithOAuth2(
    provider: "google",
    urlCallback: { url in
        await UIApplication.shared.open(URL(string: url)!)
    }
)
```

The SDK subscribes to a one-off `@oauth2` realtime channel, passes the provider authorization URL to `urlCallback`, and completes once the provider redirects to `https://yourdomain.com/api/oauth2-redirect`. Configure that URL in the provider dashboard. The SDK never opens a browser itself, so `urlCallback` is where each platform plugs in:

| Platform | Typical opener |
| --- | --- |
| SwiftUI | `openURL` from the environment |
| iOS / tvOS | `UIApplication.shared.open(_:)` |
| macOS | `NSWorkspace.shared.open(_:)` |
| Android | an `Intent` with `Intent.ACTION_VIEW` (for example Chrome Custom Tabs) |
| Linux / server | `xdg-open` or any registered URL handler |

Pass `scopes` to replace the provider's default scopes, and `createData` to add fields when the flow creates a new auth record. Cancelling the surrounding task aborts the flow, closes the realtime connection and throws a ``ClientResponseError`` with ``ClientResponseError/isAbort`` set.

### Manual code exchange

If you already have an authorization code, for example from a custom deep link, exchange it yourself with ``RecordService/authWithOAuth2Code(provider:code:codeVerifier:redirectURL:createData:options:)``:

```swift
let methods = try await pb.collection("users").listAuthMethods()

let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithOAuth2Code(
    provider: "google",
    code: "CODE",
    codeVerifier: "VERIFIER",
    redirectURL: "app://oauth2-redirect"
)
```

## OTP

```swift
let otp = try await pb.collection("users").requestOTP(email: "user@example.com")

let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithOTP(
    otpId: otp.otpId,
    password: "123456"
)
```

## Token auto-refresh

Set ``SendOptions/autoRefreshThreshold`` (in seconds) when authenticating a `_superusers` record to refresh the token before each request once it is close to expiring:

```swift
var options = SendOptions()
options.autoRefreshThreshold = 1800

let auth: RecordAuthResponse<RecordModel> = try await pb.collection("_superusers").authWithPassword(
    usernameOrEmail: "admin@example.com",
    password: "secret",
    options: options
)
```
