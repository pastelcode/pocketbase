# Changelog

All notable changes to `pocketbase` will be documented in this file.

## [0.1.0] - 2026-07-31

### Initial Release
- Complete Swift 6 conversion from `pocketbase/js-sdk` (v0.25+).
- Added `PocketBase` client with full concurrency (`async/await`) support.
- Added `BaseAuthStore`, `LocalAuthStore` (using `UserDefaults`), and `AsyncAuthStore`.
- Added `RecordService` with CRUD, Auth methods, OTP, OAuth2, Password Reset, Email Verification, Impersonation, and Realtime subscriptions.
- Added `CollectionService`, `FileService`, `RealtimeService`, `SettingsService`, `LogService`, `HealthService`, `BackupService`, `BatchService`, `CronService`, `SQLService`.
- Added type-safe `AnyCodable` for dynamic schema fields and expanded relations.
- Added unit test suite covering client, auth stores, utilities, services, and CRUD operations.
