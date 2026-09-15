# Realtime

Subscribe to live record changes over Server-Sent Events.

## Subscribe

```swift
let unsubscribe = try await pb.collection("posts").subscribe(topic: "*") { (event: RecordSubscription<RecordModel>) in
    print(event.action)      // "create", "update" or "delete"
    print(event.record.id)
}
```

The topic is appended to the collection id. Use `*` for every record in the collection, or a record id for a single record.

## Unsubscribe

```swift
try await unsubscribe()

// or, by topic / collection:
try await pb.collection("posts").unsubscribe("*")
try await pb.collection("posts").unsubscribe()
```

When the last subscription is removed the SSE connection is closed automatically.

## Connection lifecycle

``RealtimeService`` connects lazily on the first ``RealtimeService/subscribe(topic:options:callback:)`` call, waits for the server's `PB_CONNECT` event, then POSTs the subscription list. On an unexpected disconnect it reconnects with backoff and resubmits the subscriptions. Server-directed `retry:` delays are honored.

React to disconnects with ``RealtimeService/onDisconnect``. The argument lists the active subscriptions: an empty array means the client unsubscribed, a non-empty array means the connection was interrupted:

```swift
pb.realtime.onDisconnect = { activeSubscriptions in
    print("disconnected; active:", activeSubscriptions)
}
```

Check the connection state with ``RealtimeService/isConnected`` and close it manually with ``RealtimeService/disconnect()``.

## Subscription options

`subscribe(topic:options:callback:)` accepts ``SendOptions``. The `query` and `headers` values are serialized into the subscription key so the server can apply per-subscription filters:

```swift
var options = SendOptions()
options.query["filter"] = AnyCodable("status = 'published'")

let unsubscribe = try await pb.collection("posts").subscribe(topic: "*", options: options) { (event: RecordSubscription<RecordModel>) in
    print(event.record.id)
}
```
