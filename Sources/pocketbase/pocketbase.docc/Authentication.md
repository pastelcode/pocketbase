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

`isValid` combines a non-empty token with a non-expired `exp` claim (see ``JWTUtils``).

## Persistence

Three stores are available:

- ``BaseAuthStore`` — in-memory only. Good for servers and tests.
- ``LocalAuthStore`` — persists to `UserDefaults`. This is the default.
- ``AsyncAuthStore`` — persists through your own async `save`/`clear` closures, for example to the Keychain. Operations run in the order they are enqueued.

> Important: `UserDefaults` is convenient but not encrypted, so it is only suitable for development. For production, use ``AsyncAuthStore`` backed by the Keychain (recommended) — or another secure store — so the token is not readable from a plain-text app container or backup.

```swift
let store = AsyncAuthStore(
    save: { payload in
        try await keychain.write(payload)
    },
    clear: {
        try await keychain.delete()
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

## OAuth2 and OTP

```swift
let methods = try await pb.collection("users").listAuthMethods()

let auth: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithOAuth2Code(
    provider: "google",
    code: "CODE",
    codeVerifier: "VERIFIER",
    redirectURL: "app://oauth2-redirect"
)
```

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
