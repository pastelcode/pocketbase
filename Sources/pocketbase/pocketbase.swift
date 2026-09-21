//
// The `pocketbase` module.
//
// Entry points:
//
// - `PocketBase` (also exposed as `Client`): the HTTP client. Create one per
//   server and reuse it; it is `Sendable` and safe to share.
// - `PocketBase.collection(_:)` returns a `RecordService<RecordModel>`;
//   `PocketBase.collection(_:)` with an explicit model type returns a typed
//   `RecordService<M>`.
// - One service per PocketBase API group: `collections`, `files`, `logs`,
//   `settings`, `realtime`, `health`, `backups`, `crons`, `sql`.
// - Auth state lives in `PocketBase.authStore` (`LocalAuthStore` by default;
//   pass `BaseAuthStore` or `AsyncAuthStore` to the initializer to override).
// - Shared helpers: `SendOptions`, `AnyCodable`, `JWTUtils`, `CookieUtils`,
//   `AutoRefresh`, `CustomFetch`.
//
// The documentation lives in the DocC catalog at
// `Sources/pocketbase/pocketbase.docc`; start with the ``PublicAPI`` article
// and the README parity notes for the intentional differences from the
// JavaScript SDK.
//
