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

``RealtimeService`` connects lazily on the first ``RealtimeService/subscribe(topic:options:callback:)`` call, waits for the server's `PB_CONNECT` event, then POSTs the subscription list. On an unexpected disconnect it reconnects with a jittered backoff. A server-directed `retry:` delay acts as a floor and disables the jitter for that reconnect; this intentionally goes beyond the JS SDK, which ignores `retry:` for its custom reconnect.

React to disconnects with ``RealtimeService/onDisconnect``. The argument lists the active subscriptions: an empty array means the client unsubscribed, a non-empty array means the connection was interrupted:

```swift
pb.realtime.onDisconnect = { activeSubscriptions in
    print("disconnected; active:", activeSubscriptions)
}
```

Check the connection state with ``RealtimeService/isConnected`` and close it manually with ``RealtimeService/disconnect()``.

## Subscription options

`subscribe(topic:options:callback:)` accepts ``SendOptions``. The typed shorthands (`filter`, `sort`, `expand`, `fields`, `skipTotal`) are folded into `query`, and the resulting `query`/`headers` are serialized into the subscription key so the server can apply per-subscription filters:

```swift
var options = SendOptions()
options.query["filter"] = AnyCodable("status = 'published'")

let unsubscribe = try await pb.collection("posts").subscribe(topic: "*", options: options) { (event: RecordSubscription<RecordModel>) in
    print(event.record.id)
}
```

## Differences from the JS SDK

``RealtimeService`` follows the reference SDK's connection state machine, with a few intentional deviations:

- **`subscribe` parameter order.** Swift uses `subscribe(topic:options:callback:)` (options before the callback) for consistency with the rest of the package API; the JS SDK takes `(topic, callback, options)`.
- **Server `retry:` is honored.** A server-directed SSE `retry:` delay acts as a floor for the reconnect backoff and disables jitter. The JS SDK's custom reconnect ignores `retry:`.
- **`handleMessage(event:id:data:)` is public.** It lets callers or tests feed raw SSE frames when the transport is supplied externally; it is not part of the JS parity surface.
- **Per-subscription `Authorization`.** The `URLSession` transport sends the current auth-store token as an `Authorization` header and refreshes it on every reconnect; the browser `EventSource` cannot set request headers.

A subscription's `subscribe(topic:options:callback:)` call resolves only after the server's `PB_CONNECT` handshake and the subscription `POST /api/realtime` complete.
