# Changelog

All notable changes to `pocketbase` will be documented in this file.

## [0.2.0] - 2026-09-21

### Added

- Request cancellation: `requestKey`, `cancelRequest(_:)`, `cancelAllRequests(_:)` and same-key auto-cancellation (`SendOptions.autoCancel`).
- Interactive `authWithOAuth2` with a pluggable `urlCallback` (provider discovery, one-off `@oauth2` realtime channel, state validation, cancellation and cleanup).
- Overridable `CrudService.decode` hook, applied to every CRUD and auth response.
- `LogService.truncate`, `CollectionType` accessor and unknown collection/field key preservation through `import`.
- `SendOptions.FormValue.array` for mixed value/file multipart fields.
- `AsyncAuthStore.initialLoader`, injectable `LocalAuthStore` storage, `JWTUtils.getExpirationTimestamp`, and public `AutoRefresh.registerAutoRefresh`/`resetAutoRefresh`.
- Documentation and project infrastructure: DocC catalog with a `PublicAPI` article, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue/PR templates, CI (macOS tests + DocC gate, Android build/tests), CodeQL and Dependabot.

### Changed

- **Breaking:** JWT expiration checks fail closed — `JWTUtils.isTokenExpired` and `BaseAuthStore.isValid` require a well-formed three-segment JWT with a numeric (or numeric-string) `exp` claim in the future.
- **Breaking:** `importCollections` was renamed to `import`, and multipart `.json` values are sent under `@jsonPayload`.
- **Breaking:** `BaseAuthStore.clear()` no longer calls the overridable `save(_:_:)`; subclasses should override `clear()` or `triggerChange()`.
- **Breaking:** `RecordService.update` merges the stored auth record with the response instead of replacing it, preserving fields omitted by partial responses.
- Aligned the request pipeline with the reference SDK: hook error wrapping, option precedence, query/filter escaping and number formatting, and cancellation registration before `beforeSend`.
- Auth stores: `triggerChange()` hook, cookie trim preserving `id`/`email`, live `LocalAuthStore`, FIFO `AsyncAuthStore` queue, `AutoRefresh` lifetime and gating fixes.
- Realtime: reconnect and subscription-sync hardening, `onDisconnect(activeSubscriptions)` semantics, server `retry:` as a backoff floor, transport lifecycle fixes and a deterministic `options=` encoding.
- Batch/FormData: mixed value/file arrays, `+` file keys, deterministic `@jsonPayload` merge, nested-array handling and empty-array behavior.
- Services: `impersonate` honors `decode`, admin option precedence, typed `appleClientSecret` response, and safer `SubBatchService` queue lifetime.
- Documentation: compiling README examples, JS parity notes, Android persistence notes, and DocC topic-heading fixes.

### Removed

- Deprecated JS-compatibility aliases: `BaseAuthStore.model`, `isAdmin`, `isAuthRecord`; `PocketBase.admins`, `getFileUrl`; `FileService.getUrl`. Use `record`, `isSuperuser`, `collection("_superusers")` and `files.getURL` instead.

## [0.1.0] - 2026-09-14

### Initial Release

- Complete Swift 6 conversion from `pocketbase/js-sdk` (v0.28.1).
- Added `PocketBase` client with full concurrency (`async/await`) support.
- Added `BaseAuthStore`, `LocalAuthStore` (using `UserDefaults`), and `AsyncAuthStore`.
- Added `RecordService` with CRUD, Auth methods, OTP, OAuth2, Password Reset, Email Verification, Impersonation, and Realtime subscriptions.
- Added `CollectionService`, `FileService`, `RealtimeService`, `SettingsService`, `LogService`, `HealthService`, `BackupService`, `BatchService`, `CronService`, `SQLService`.
- Added type-safe `AnyCodable` for dynamic schema fields and expanded relations.
- Added unit test suite covering client, auth stores, utilities, services, and CRUD operations.
