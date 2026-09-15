# Swift PocketBase SDK

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS-blue.svg)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.md)

A modern, light-weight, fully-typed Swift SDK for [PocketBase](https://pocketbase.io). Built with Swift 6 Concurrency (`async/await`), thread-safe state management, and 100% feature parity with the official PocketBase JavaScript SDK.

---

## 🌟 Features

- **Swift 6 & Concurrency**: Complete `async/await` async support with `Sendable` thread-safe architecture.
- **Cross-Platform Support**: Works on iOS (15+), macOS (12+), tvOS (15+), watchOS (8+), and Swift Server (Vapor / Hummingbird).
- **Automatic Auth Persistence**: Built-in `LocalAuthStore` using `UserDefaults` to persist authentication across app restarts.
- **SSR & Cookie Support**: `loadFromCookie` and `exportToCookie` methods for Server-Side Rendering.
- **Type-Safe Dynamic Fields**: [`AnyCodable`](Sources/pocketbase/Tools/AnyCodable.swift) helper for type-safe handling of dynamic JSON schema fields and expanded relations.
- **Full API Parity**:
  - `RecordService` (CRUD, Password Auth, OAuth2, OTP, Password Reset, Email Verification, Email Change, Impersonation)
  - `CollectionService` (Schemas, Scaffolding, Import, Truncate, Dry-Run View Query)
  - `FileService` (URL generation, Token generation)
  - `RealtimeService` (Server-Sent Events realtime subscriptions)
  - `BatchService` (Transactional multi-request batch processing)
  - `SettingsService`, `LogService`, `HealthService`, `BackupService`, `CronService`, `SQLService`

---

## 📦 Installation

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
    let authData = try await pb.collection("users").authWithPassword(
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
let result = try await pb.collection("posts").getList(page: 1, perPage: 20)
for post in result.items {
    print("Post ID: \(post.id), Title: \(post["title"]?.stringValue ?? "")")
}

// Fetch single record by ID
let post = try await pb.collection("posts").getOne(id: "RECORD_ID")

// Create a new record
let newPost = try await pb.collection("posts").create(
    bodyParams: .json([
        "title": AnyCodable("My First Post"),
        "content": AnyCodable("Hello World!"),
        "published": AnyCodable(true)
    ])
)

// Update an existing record
let updatedPost = try await pb.collection("posts").update(
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
            let result = try await pb.collection("posts").getList(page: 1, perPage: 30)
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
let unsub = try await pb.collection("posts").subscribe(topic: "*") { event in
    print("Action: \(event.action)") // "create", "update", "delete"
    print("Record ID: \(event.record.id)")
}

// Unsubscribe when done
try await unsub()
```

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

## 🖥️ Server-Side Rendering (Vapor / Swift Server)

```swift
// Per-request PocketBase instance
let pb = PocketBase(baseURL: "https://example.com", authStore: BaseAuthStore())

// Load auth from request Cookie header
if let cookieHeader = req.headers["Cookie"].first {
    pb.authStore.loadFromCookie(cookieHeader)
}

// Use PocketBase with authenticated user context...

// Export cookie to set on response header
let setCookieHeader = pb.authStore.exportToCookie(
    options: CookieSerializeOptions(httpOnly: true, secure: true, sameSite: "Strict")
)
res.headers.add(name: "Set-Cookie", value: setCookieHeader)
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

The catalog includes getting started, authentication, realtime and queries/filtering articles.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE.md).
