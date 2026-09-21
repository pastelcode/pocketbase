# Public API

An overview of the supported surface of the `pocketbase` module: entry points, extension hooks and the symbols that are intentionally internal.

## Overview

Everything declared `public` in the `pocketbase` module is supported for consumers. The transport internals (`SSEParser`, `SSETransport`, `CancellationHandle`) are not public and may change at any time.

## Client entry points

Create one client per PocketBase server and reuse it:

```swift
import pocketbase

let pb = PocketBase(baseURL: "https://example.com")
```

- ``PocketBase`` is the client; ``Client`` is a compatibility alias.
- ``PocketBase/authStore`` holds the authentication state.
- The service properties are ``PocketBase/collections``, ``PocketBase/files``, ``PocketBase/logs``, ``PocketBase/settings``, ``PocketBase/realtime``, ``PocketBase/health``, ``PocketBase/backups``, ``PocketBase/crons`` and ``PocketBase/sql``.
- `collection(_:)` returns a `RecordService<RecordModel>`; the generic overload returns a `RecordService<M>` for a custom model type. Both overloads cache the service by collection name and model type.

## Records and services

- `RecordService<M>` covers CRUD, the auth flows and realtime subscriptions for one collection.
- `CrudService<M>` is the base class for custom collection services. Subclasses override `baseCrudPath` and may override the `decode` hook, which is applied to every CRUD response (list items, `getOne`, `create`, `update`, and auth records).
- `CollectionService` manages schemas (`getList`, `getOne`, `create`, `update`, `delete`, `import`, `truncate`, `getScaffolds`).
- `FileService` builds file URLs and file tokens.
- `BatchService` and `SubBatchService` build transactional batches.

CRUD and auth methods are generic (`getList<T>`, `getOne<T>`, `authWithPassword<T>`, …), so give the compiler a type to infer, for example `let posts: ListResult<RecordModel> = try await pb.collection("posts").getList()`.

## Requests and options

``SendOptions`` carries everything a request needs: `method`, `query`, `headers`, `body`, the typed query shorthands (`filter`, `sort`, `expand`, `fields`, `skipTotal`), `requestKey`, `autoCancel`, `batch`, and the superuser `autoRefresh` / `autoRefreshThreshold`.

Precedence rules:

- Explicitly set fields win over defaults; defaults only fill in missing values.
- Typed shorthands win over an equivalent entry in `query`.
- `options.body` wins over `bodyParams`.

The client exposes two hooks: ``PocketBase/beforeSend`` (returns a possibly modified `(url, options)` pair) and ``PocketBase/afterSend`` (transforms raw response data before error mapping). Errors thrown by either hook surface as ``ClientResponseError``.

Cancellation is per request key: pass `requestKey` in `SendOptions`, or use `cancelRequest(_:)` / `cancelAllRequests(_:keepRealtime:)` on the client. Same-key requests supersede each other unless `autoCancel` is `false`.

## Authentication

``BaseAuthStore`` holds the token and record and notifies subscribers through `onChange`; `save` and `clear` route through the overridable `triggerChange()`. ``LocalAuthStore`` is the default and persists to `UserDefaults` on Apple platforms. ``AsyncAuthStore`` wraps asynchronous storage (for example the Keychain) and accepts an `initialLoader` for asynchronous seeding.

Auth cookies are handled by `loadFromCookie(_:)` and `exportToCookie(options:)`; the latter throws ``CookieSerializeError`` for invalid names or values. ``AutoRefresh`` registers `autoRefreshThreshold`-based token refresh for superuser auth.

Advanced helpers: ``JWTUtils`` (token payload and expiration) and ``CookieUtils`` (serialization with ``CookieSerializeOptions`` / ``CookieParseOptions`` and ``CookieSameSite``).

## Realtime

``RealtimeService`` manages one SSE connection and exposes `subscribe(topic:options:callback:)` / `unsubscribe(_:)`, returning an `UnsubscribeFunc`. `RecordService.subscribe(topic:options:callback:)` prefixes the collection to the topic; note that `options` precede the callback, unlike the JS SDK. `handleMessage(event:id:data:)` stays public so callers can inject raw frames manually (used by tests and platform integrations).

## Errors

Pipeline failures are reported as ``ClientResponseError`` (status, response, `isAbort`, `originalError`, `url`, `data`). ``BatchServiceError`` reports invalid batch bodies, and ``CookieSerializeError`` invalid cookies.

## Extension points

- ``PocketBase/beforeSend`` and ``PocketBase/afterSend`` for request/response interception.
- ``CustomFetch`` to replace the `URLSession` transport.
- The `decode` hook on `CrudService` to customize model materialization.
- Subclassing `BaseAuthStore` (`triggerChange`) or `CrudService` (`baseCrudPath`, `decode`).
- `AsyncAuthStore` with custom save/clear closures for Keychain or database persistence.

## Thread safety

The client and services are `Sendable` and safe to share across tasks. Hooks and realtime callbacks are `@Sendable` and may run off the main actor. Mutating public state (for example ``BaseAuthStore`` fields or `beforeSend`) is synchronized; reads that render UI should still happen on the main actor by convention.

## Stability

The package is pre-1.0: minor releases may contain source-breaking changes. The README documents the intentional differences from the JavaScript SDK; documentation is the source of truth for behavior.
