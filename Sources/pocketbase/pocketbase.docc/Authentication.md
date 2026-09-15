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
