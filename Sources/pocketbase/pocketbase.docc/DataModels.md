# Data models and multipart encoding

How the SDK models server responses and encodes form bodies, and where it
intentionally differs from the JavaScript reference.

## RecordModel and dynamic fields

`RecordModel` exposes the system fields (`id`, `collectionId`,
`collectionName`, `created`, `updated`, `expand`) as typed properties. Every
other collection field is stored in ``RecordModel/rawFields`` and can be read
and written through the subscript:

```swift
let record = try await pb.collection("posts").getOne("RECORD_ID")

print(record.id)
print(record["title"]?.stringValue ?? "")

var draft = record
draft["draft"] = true
```

Unknown keys survive a JSON round-trip, so decoding and re-encoding a record
does not drop fields that this SDK version does not know.

## CollectionModel

The reference SDK models collections as a union of
`BaseCollectionModel`, `ViewCollectionModel` and `AuthCollectionModel`.
Swift's `Codable` has no structural unions and `CollectionService` returns
`CollectionModel` values directly, so this SDK keeps one flattened model
instead of three.

Switch on ``CollectionModel/collectionType`` to handle each kind. The
kind-specific properties are optional and `nil` for the other kinds:

```swift
let collection = try await pb.collections.get("posts")

switch collection.collectionType {
case .auth:
    print(collection.oauth2?.providers.count ?? 0)
case .view:
    print(collection.viewQuery ?? "")
case .base, nil:
    break
}
```

`collectionType` is `nil` for a type this SDK version does not know, while
``CollectionModel/type`` always keeps the raw string returned by the server.
This keeps decoding forward compatible.

## ListResult defaults

``ListResult`` provides local defaults (`page` 1, `perPage` 30, zeroed totals
and an empty `items` array) for convenience when you construct one yourself.
Values decoded from a response always keep the server values, matching the
reference SDK, which has no defaults.

## SQLResult rows

``SQLResult/rows`` is `[[String?]]`, like the reference SDK's
`Array<Array<string | null>>`. The server scans every cell into a nullable
string regardless of the underlying column type, so numbers and dates arrive
as their string representations.

## Multipart encoding

Set ``SendOptions/body-swift.property`` to
``SendOptions/AnySendableBody/form(_:)`` to submit a
`multipart/form-data` request. Each field maps to the wire as follows:

| `SendOptions.FormValue` | Multipart body | Batch body |
|---|---|---|
| `.string(_:)` | One plain text part under the field name | String value in the JSON body |
| `.json(_:)` | `{"<field>": <value>}` under the reserved `@jsonPayload` field | Value under the field name |
| `.jsonPayload(_:)` | The value under `@jsonPayload`, unwrapped | Merged into the JSON body |
| `.file(_:)`, `.files(_:)` | One part per file under the field name | `files` entries |
| `.array(_:)` | One part per element under the field name | Regular values into JSON, files under a `+`-suffixed key |

### JSON values and `@jsonPayload`

The JavaScript SDK converts a body with file values through
`convertToFormDataIfNeeded`. Object values are appended as
`form.append("@jsonPayload", JSON.stringify({ field: value }))` so the server
merges them without applying its implicit string normalization. Multipart
bodies built by this SDK do the same: `.json(_:)` values become `@jsonPayload`
parts, and the server merges them into the request data.

`.jsonPayload(_:)` is the lower-level case for payloads that already have the
shape `@jsonPayload` expects; ``BatchService`` uses it to transport the whole
batch as a single JSON part.

### String inference

Plain multipart fields are typeless on the wire, so the server applies its own
inference rules when parsing them (`"true"` becomes `true`, numeric strings
become numbers, and so on). The client does not pre-normalize values:
``SendOptions/FormValue/string(_:)`` is sent exactly as written. Use
``SendOptions/FormValue/json(_:)`` when a value must not go through the
inference, for example a numeric string such as a phone number.

The JavaScript SDK additionally applies the server inference to strings when a
`FormData` instance is handed to a batch sub-service, because it round-trips
the form back into a JSON body. The Swift batch encoder keeps the type you
declare: `.string("42")` stays `"42"` in the batch JSON body, while
`.json(AnyCodable(42))` sends the number. Batch requests built from plain
objects in JavaScript behave the same way.

### Escaping

Part names and filenames are escaped the way browser `FormData`
implementations do it: carriage returns, line feeds and double quotes become
`%0D`, `%0A` and `%22`.
