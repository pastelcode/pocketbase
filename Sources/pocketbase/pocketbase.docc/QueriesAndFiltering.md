# Queries and filtering

Build filters, paginate results and understand how request options are resolved.

## Filter expressions

Use ``PocketBase/filter(_:params:)`` to build a filter with placeholders. Parameter values are escaped for you:

```swift
let filter = pb.filter("title ~ {:title} && created > {:date}", params: [
    "title": "swift",
    "date": Date()
])

var options = SendOptions()
options.filter = filter

let result: ListResult<RecordModel> = try await pb.collection("posts").getList(options: options)
```

## Typed shorthands

``SendOptions`` exposes shorthands for the most common query parameters: ``SendOptions/filter``, ``SendOptions/sort``, ``SendOptions/expand``, ``SendOptions/fields`` and ``SendOptions/skipTotal``. They are merged into the query string and take precedence over a value already present in ``SendOptions/query``.

```swift
var options = SendOptions()
options.filter = "published = true"
options.sort = "-created"
options.expand = "author"
options.fields = "id,title,author"
options.skipTotal = true

let result: ListResult<RecordModel> = try await pb.collection("posts").getList(page: 1, perPage: 50, options: options)
```

Anything else can be passed through ``SendOptions/query``:

```swift
var options = SendOptions()
options.query["custom"] = AnyCodable("value")
```

## Pagination

`getList(page:perPage:options:)` returns a ``ListResult`` with `page`, `perPage`, `totalItems`, `totalPages` and `items`. Caller-provided `page`/`perPage` query values override the method parameters.

`getFullList(options:)` walks every page and returns a single array. The page size defaults to 1000 and can be changed with ``SendOptions/batch`` (client-side only, never sent to the server):

```swift
var options = SendOptions()
options.batch = 500
options.filter = "published = true"

let all: [RecordModel] = try await pb.collection("posts").getFullList(options: options)
```

`getFirstListItem(filter:options:)` returns the first match or throws a 404 ``ClientResponseError``.

## Option resolution

Request options are resolved in this order (later values win):

1. Service defaults (for example `GET` for `getList`, `POST` for `create`).
2. Values provided in ``SendOptions`` — `method` is optional; when set it overrides the default.
3. Typed shorthands, which override the same key in ``SendOptions/query``.

## Cancellation

Requests are auto-cancelled by default: two in-flight requests with the same key cancel the earlier one. The key is ``SendOptions/requestKey``, or the HTTP method plus path when unset. Disable globally with ``PocketBase/autoCancellation(_:)`` or per request with ``SendOptions/autoCancel``:

```swift
pb.autoCancellation(false)

var options = SendOptions()
options.autoCancel = false    // only this request
```

A cancelled request fails with ``ClientResponseError`` where ``ClientResponseError/isAbort`` is `true`.

The request is registered before ``PocketBase/beforeSend`` runs, matching the reference SDK. A slow or suspended hook therefore neither delays superseding a same-key request nor prevents ``PocketBase/cancelRequest(_:)`` from interrupting a request whose hook is still running. The key is resolved from the options as the caller passed them; a hook that rewrites ``SendOptions/requestKey`` or ``SendOptions/method`` does not change where the request was registered.

### Custom fetch and cancellation limits

Cancellation cancels the wrapping Swift `Task`, and only that. A ``CustomFetch`` closure is not handed an `AbortSignal`, so a closure that ignores task cancellation keeps running after ``PocketBase/cancelRequest(_:)`` or a same-key supersession. Cooperate by checking `Task.isCancelled` or using cancellation-aware APIs such as `URLSession`, which the default transport relies on.

### Legacy options

The reference JavaScript SDK's legacy options are intentionally not exposed. Use the Swift equivalents instead:

| JavaScript SDK | Swift SDK |
| --- | --- |
| `$autoCancel: false` (option or query parameter) | ``SendOptions/autoCancel`` = `false` |
| `$cancelKey` (option or query parameter) | ``SendOptions/requestKey`` |
| `params` | ``SendOptions/query`` |
| `signal` / `AbortSignal` | none — cancellation is expressed with `Task` cancellation and ``PocketBase/cancelRequest(_:)`` / ``PocketBase/cancelAllRequests()`` |

