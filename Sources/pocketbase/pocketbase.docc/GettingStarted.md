# Getting started

Install the package, create a client and make your first requests.

## Installation

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pastelcode/pocketbase.git", from: "0.1.0")
]
```

Or in Xcode, choose **File > Add Package Dependencies…** and enter the repository URL.

## Create a client

```swift
import pocketbase

let pb = PocketBase(baseURL: "https://example.com")
```

For server-side rendering, pass a memory-only store so nothing is persisted:

```swift
let pb = PocketBase(baseURL: "https://example.com", authStore: BaseAuthStore())
```

## Fetch records

```swift
let result: ListResult<RecordModel> = try await pb.collection("posts").getList(page: 1, perPage: 20)

for post in result.items {
    print(post.id, post["title"]?.stringValue ?? "")
}
```

Fetch every record (paginated internally):

```swift
let all: [RecordModel] = try await pb.collection("posts").getFullList()
```

## Create, update and delete

```swift
let created: RecordModel = try await pb.collection("posts").create(
    bodyParams: .json([
        "title": AnyCodable("Hello"),
        "published": AnyCodable(true)
    ])
)

let updated: RecordModel = try await pb.collection("posts").update(
    id: created.id,
    bodyParams: .json(["title": AnyCodable("Updated")])
)

let deleted: Bool = try await pb.collection("posts").delete(id: created.id)
```

## Handle errors

Every failure in the request pipeline is reported as a ``ClientResponseError``:

```swift
do {
    let _: RecordModel = try await pb.collection("posts").getOne(id: "missing")
} catch let error as ClientResponseError {
    print(error.status)          // e.g. 404
    print(error.message)
    print(error.isAbort)         // true when the request was cancelled
    print(error.response)        // decoded server response payload
}
```

## Next steps

- <doc:Authentication>
- <doc:QueriesAndFiltering>
- <doc:Realtime>
