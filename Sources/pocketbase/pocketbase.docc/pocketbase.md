# ``pocketbase``

A modern, lightweight, fully typed Swift SDK for [PocketBase](https://pocketbase.io).

## Overview

`pocketbase` is an `async`/`await` client for the PocketBase REST and realtime APIs. It supports Apple platforms (iOS 15+, macOS 12+, tvOS 15+, watchOS 8+) and Android.

Create a client and use its services:

```swift
import pocketbase

let pb = PocketBase(baseURL: "https://example.com")

let posts: ListResult<RecordModel> = try await pb.collection("posts").getList(page: 1, perPage: 20)
print(posts.items.count)
```

The client exposes one service per PocketBase API group: ``PocketBase/collections``, ``PocketBase/files``, ``PocketBase/logs``, ``PocketBase/settings``, ``PocketBase/realtime``, ``PocketBase/health``, ``PocketBase/backups``, ``PocketBase/crons`` and ``PocketBase/sql``. Records are accessed through per-collection services returned by `collection(_:)`.

## Topics

### Essentials

- <doc:GettingStarted>
- ``PocketBase``
- ``SendOptions``
- ``ClientResponseError``

### Authentication

- <doc:Authentication>
- ``BaseAuthStore``
- ``LocalAuthStore``
- ``AsyncAuthStore``

### Records and collections

- ``RecordService``
- ``CrudService``
- ``CollectionService``
- ``RecordModel``
- ``CollectionModel``
- ``ListResult``

### Realtime

- <doc:Realtime>
- ``RealtimeService``
- ``RecordSubscription``

### Queries

- <doc:QueriesAndFiltering>
- ``AnyCodable``

### Batch operations

- ``BatchService``
- ``BatchRequest``
- ``BatchRequestResult``

### Files

- ``FileService``
- ``FileParam``
- ``MultipartFormData``

### Administration

- ``SettingsService``
- ``BackupService``
- ``LogService``
- ``CronService``
- ``HealthService``
- ``SQLService``

### Utilities

- ``JWTUtils``
- ``CookieUtils``
- ``AutoRefresh``
- ``CustomFetch``
