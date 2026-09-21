# PocketBase Swift SDK

[![CI](https://github.com/pastelcode/pocketbase/actions/workflows/ci.yml/badge.svg)](https://github.com/pastelcode/pocketbase/actions/workflows/ci.yml)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20Android-blue.svg)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.md)

A modern, lightweight, fully typed Swift SDK for [PocketBase](https://pocketbase.io). Built with Swift 6 concurrency (`async`/`await`) and `Sendable`-safe state management, targeting broad behavioral parity with the official PocketBase JavaScript SDK. Intentional differences are listed in [Parity Notes](#-parity-notes).

---

## 🌟 Features

- **Swift 6 & Concurrency**: Complete `async`/`await` support with a `Sendable`-safe architecture.
- **Cross-Platform Support**: Works on iOS (15+), macOS (12+), tvOS (15+), watchOS (8+), Android (via the Swift SDK for Android), and Swift server platforms (Vapor / Hummingbird).
- **Automatic Auth Persistence**: `LocalAuthStore` keeps the auth state in `UserDefaults` on Apple platforms. `UserDefaults` is not persistent on Android and Linux — back `AsyncAuthStore` with your own storage there, or with the Keychain on Apple platforms (recommended for production).
- **SSR & Cookie Support**: `loadFromCookie` and `exportToCookie` methods for Server-Side Rendering.
- **Type-Safe Dynamic Fields**: [`AnyCodable`](Sources/pocketbase/Tools/AnyCodable.swift) helper for type-safe handling of dynamic JSON schema fields and expanded relations.
- **Service Coverage**:
  - `RecordService` (CRUD, Password Auth, OAuth2, OTP, Password Reset, Email Verification, Email Change, Impersonation)
  - `CollectionService` (Schemas, Scaffolding, Import, Truncate, Dry-Run View Query)
  - `FileService` (URL generation, Token generation)
  - `RealtimeService` (Server-Sent Events realtime subscriptions)
  - `BatchService` (Transactional multi-request batch processing)
  - `SettingsService`, `LogService`, `HealthService`, `BackupService`, `CronService`, `SQLService`

---

## 📦 Installation

### Requirements

- **Swift 6.2 or later** (declared by `// swift-tools-version: 6.2` in `Package.swift`).
- Apple platforms: Xcode 16.4 or later; the minimum deployment targets are iOS 15, macOS 12, tvOS 15 and watchOS 8.
- Android: the [Swift SDK for Android](https://swift.org/documentation/articles/swift-sdk-for-android-getting-started.html) and Android NDK 27d or later. See [CONTRIBUTING.md](CONTRIBUTING.md#android) for the full setup and test procedure.

### Swift Package Manager (SPM)

#### In Xcode:
1. Go to **File > Add Package Dependencies...**
2. Enter the repository URL:
   ```text
   https://github.com/pastelcode/pocketbase.git
   ```
3. Set **Dependency Rule** to `Up to Next Major Version` from `0.1.0`.

#### In `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/pastelcode/pocketbase.git", from: "0.1.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "pocketbase", package: "pocketbase")
        ]
    )
]
```

---

## 🚀 Quick Start

### 1. Initialization

```swift
import pocketbase

// Initialize client
let pb = PocketBase(baseURL: "https://example.com")
```

### 2. User Authentication

```swift
// Authenticate with Username/Email & Password
do {
    let authData: RecordAuthResponse<RecordModel> = try await pb.collection("users").authWithPassword(
        usernameOrEmail: "test@example.com",
        password: "password123"
    )
    print("Authenticated user ID: \(authData.record.id)")
    print("User token: \(authData.token)")
} catch {
    print("Auth error: \(error)")
}

// Check logged in state (automatically persisted across app launches)
if pb.authStore.isValid {
    print("Current user: \(pb.authStore.record?.id ?? "")")
}

// Logout
pb.authStore.clear()
```

### 3. Record Operations (CRUD)

```swift
// Fetch paginated records
let result: ListResult<RecordModel> = try await pb.collection("posts").getList(page: 1, perPage: 20)
for post in result.items {
    print("Post ID: \(post.id), Title: \(post["title"]?.stringValue ?? "")")
}

// Fetch single record by ID
let post: RecordModel = try await pb.collection("posts").getOne(id: "RECORD_ID")

// Create a new record
let newPost: RecordModel = try await pb.collection("posts").create(
    bodyParams: .json([
        "title": AnyCodable("My First Post"),
        "content": AnyCodable("Hello World!"),
        "published": AnyCodable(true)
    ])
)

// Update an existing record
let updatedPost: RecordModel = try await pb.collection("posts").update(
    id: newPost.id,
    bodyParams: .json([
        "title": AnyCodable("Updated Title")
    ])
)

// Delete a record
try await pb.collection("posts").delete(id: newPost.id)
```

---

## 📱 SwiftUI Integration

```swift
import SwiftUI
import pocketbase

let pb = PocketBase(baseURL: "https://example.com")

struct PostListView: View {
    @State private var posts: [RecordModel] = []
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            List(posts, id: \.id) { post in
                VStack(alignment: .leading) {
                    Text(post["title"]?.stringValue ?? "Untitled")
                        .font(.headline)
                    Text(post["content"]?.stringValue ?? "")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Posts")
            .task {
                await loadPosts()
            }
        }
    }

    func loadPosts() async {
        isLoading = true
        do {
            let result: ListResult<RecordModel> = try await pb.collection("posts").getList(page: 1, perPage: 30)
            self.posts = result.items
        } catch {
            print("Error: \(error)")
        }
        isLoading = false
    }
}
```

---

## ⚡ Realtime Subscriptions

```swift
// Subscribe to all changes in a collection
let unsub = try await pb.collection("posts").subscribe(topic: "*") { (event: RecordSubscription<RecordModel>) in
    print("Action: \(event.action)") // "create", "update", "delete"
    print("Record ID: \(event.record.id)")
}

// Unsubscribe when done
try await unsub()
```

On an unexpected disconnect the client reconnects with a jittered backoff and resubmits the active topics. A server-directed SSE `retry:` delay acts as a floor and disables the jitter (the JS SDK ignores `retry:` for its custom reconnect).

Compared with the JS SDK, Swift uses `subscribe(topic:options:callback:)` and keeps `handleMessage(event:id:data:)` public for manual frame injection.

---

## 📦 Batch Operations

```swift
let batch = pb.createBatch()

batch.collection("posts").create(bodyParams: .json(["title": AnyCodable("Post 1")]))
batch.collection("posts").update(id: "RECORD_ID", bodyParams: .json(["title": AnyCodable("Updated")]))
batch.collection("posts").delete(id: "OTHER_ID")

let batchResults = try await batch.send()
```

---

## 🔁 Parity Notes

The SDK targets broad behavioral parity with the reference JavaScript SDK (v0.28.1). The following differences are intentional and documented:

- **Cancellation**: cancellation aborts the wrapping Swift `Task`. A `CustomFetch` closure is not handed an `AbortSignal`, so a closure that ignores task cancellation keeps running; the default `URLSession` transport is fully cancellable. Requests are registered for auto-cancellation before `beforeSend` runs, so a slow hook cannot invert same-key supersession.
- **Legacy options**: the JavaScript-only `$autoCancel` / `$cancelKey` options (and their query-parameter forms) are replaced by `SendOptions.autoCancel` and `SendOptions.requestKey`; `params` is replaced by `SendOptions.query`; and `signal` / `AbortSignal` is not exposed. Abort the wrapping task with `cancelRequest(_:)` / `cancelAllRequests()` instead.
- **Hooks**: `beforeSend` must return `{ url, options }`; the deprecated options-only return shape is not supported. Errors thrown by request hooks are wrapped as `ClientResponseError`.
- **JWT expiration**: `JWTUtils.isTokenExpired` and `BaseAuthStore.isValid` fail closed — a token is invalid unless it is a well-formed three-segment JWT with a numeric (or numeric-string) `exp` claim in the future. The JS SDK treats a missing or falsy `exp` as "never expires".
- **Cookies**: `CookieUtils` / `exportToCookie` throw a `CookieSerializeError` for invalid names or values instead of silently sanitizing them.
- **OAuth2**: the interactive `authWithOAuth2` flow requires a `urlCallback` so the SDK stays free of UI framework dependencies; the JS SDK opens a popup itself.
- **Realtime**: a server-directed SSE `retry:` value acts as a backoff floor and disables jitter (the JS SDK ignores `retry:` for its custom reconnect), and `subscribe` takes `options` before the callback. `handleMessage(event:id:data:)` stays public for manual frame injection.
- **FormData**: there is no automatic object-to-`FormData` conversion; use `.form` with `FileParam` for multipart bodies. The server-side string inference rules (`"true"`, numeric strings) are not applied by `convertFormDataToObject`, because there is no such helper — `.form` values keep their Swift types.
- **Collections**: the JS union types are flattened into a single `CollectionModel` with a `CollectionType` accessor; unknown collection/field keys are preserved through import.
- **Legacy signatures and aliases**: the deprecated positional overloads (for example `getFullList(batch, options)`) and the JS compatibility aliases (`model`, `isAdmin`, `isAuthRecord`, `admins`, `getFileUrl`, `getUrl`) are not ported; use `record`, `isSuperuser`, `collection("_superusers")` and `files.getURL` instead.

See the <doc:PublicAPI> article in the DocC documentation for the supported surface.

---

## 🖥️ Server-Side Rendering (Vapor / Swift Server)

Cookies are only used for the SSR handoff between a browser and your Swift server: `loadFromCookie` restores the auth state from the request's `Cookie` header, and `exportToCookie` produces the `Set-Cookie` value returned to the browser. Native iOS/Android clients don't need cookies — the token is sent as an `Authorization` header on every request, including realtime.

```swift
// Per-request PocketBase instance; keep the auth state in memory on the server.
let pb = PocketBase(baseURL: "https://example.com", authStore: BaseAuthStore())

// Restore the auth state from the request's "Cookie" header
// (in Vapor: req.headers.first(name: "Cookie")).
pb.authStore.loadFromCookie(cookieHeader)

// ...run server-side queries with the authenticated user context...

// Produce the Set-Cookie value for the response
// (in Vapor: res.headers.add(name: "Set-Cookie", value: setCookie)).
let setCookie = try pb.authStore.exportToCookie(
    options: CookieSerializeOptions(httpOnly: true, secure: true, sameSite: .strict)
)
```

---

## 📚 Documentation

API reference docs are generated with [DocC](https://www.swift.org/documentation/docc/) from the `///` comments in `Sources/pocketbase` and the articles in `Sources/pocketbase/pocketbase.docc`.

- **In Xcode:** open the package and choose **Product > Build Documentation**.
- **From the command line:**

  ```sh
  xcodebuild docbuild -scheme pocketbase -destination 'generic/platform=macOS'
  ```

  The generated `pocketbase.doccarchive` can be opened in Xcode or served with `docc preview`.

The catalog includes getting started, authentication, data models, realtime, queries/filtering and public API articles.

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup and the full macOS, iOS Simulator and Android test matrix. All tests run in CI on every push and pull request.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE.md).
