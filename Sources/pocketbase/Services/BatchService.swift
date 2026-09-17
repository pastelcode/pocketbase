import Foundation

/// Errors thrown when a queued batch request cannot be serialized.
public enum BatchServiceError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The request at `index` has a body that cannot be embedded in a batch
    /// payload.
    ///
    /// Batch requests are serialized as JSON objects plus multipart file
    /// fields, so only `.json`, object `.rawJson` and `.form` bodies are
    /// supported.
    case unsupportedBody(index: Int, reason: String)

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case .unsupportedBody(let index, let reason):
            return "batch request at index \(index) has an unsupported body: \(reason)"
        }
    }
}

/// A queued request together with the reason its body cannot be serialized,
/// when applicable.
private struct QueuedBatchRequest {
    let request: BatchRequest
    let unsupportedBodyReason: String?
}

/// Groups multiple record operations into a single `/api/batch` request.
///
/// Create an instance with ``PocketBase/createBatch()``, queue requests through
/// ``BatchService/collection(_:)``, then submit them with ``BatchService/send(options:)``.
///
/// ```swift
/// let batch = pocketbase.createBatch()
/// batch.collection("posts").create(bodyParams: .json(["title": "Hello"]))
/// batch.collection("posts").update(id: "RECORD_ID", bodyParams: .json(["title": "Updated"]))
/// let results = try await batch.send()
/// ```
///
/// Bodies queued as `.form` may mix regular values and files under one field
/// through ``SendOptions/FormValue/array(_:)``. Regular values are sent in the
/// JSON payload while files become multipart fields; when a field carries both,
/// the files are appended under a `+`-suffixed key (for example
/// `attachments+`) so the server appends instead of replacing, matching the
/// JavaScript SDK.
open class BatchService: BaseService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var requests: [QueuedBatchRequest] = []
    private var subs: [String: SubBatchService] = [:]

    /// Returns the sub-batch service for a collection, creating it on first use.
    ///
    /// Repeated calls with the same identifier return the same instance.
    ///
    /// - Parameter collectionIdOrName: The collection identifier or name.
    /// - Returns: The sub-batch service targeting the collection.
    open func collection(_ collectionIdOrName: String) -> SubBatchService {
        lock.lock()
        defer { lock.unlock() }

        if let existing = subs[collectionIdOrName] {
            return existing
        }

        let sub = SubBatchService(batchService: self, collectionIdOrName: collectionIdOrName)
        subs[collectionIdOrName] = sub
        return sub
    }

    fileprivate func appendRequest(_ req: QueuedBatchRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(req)
    }

    private func getRequests() -> [QueuedBatchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Sends all queued requests as a single batch.
    ///
    /// The queued requests are serialized into a multipart payload and posted
    /// to `/api/batch`. The queue is **not** cleared by this call: calling
    /// `send()` again replays the same requests, matching the JavaScript SDK.
    ///
    /// Every queued body must be `.json`, a `.rawJson` object or `.form`.
    /// Other body kinds fail before any request is sent.
    ///
    /// - Parameter options: Additional send options. The `POST` method and the
    ///   multipart body are applied unless the caller already set them.
    /// - Returns: One result per queued request, in queue order.
    /// - Throws: A ``BatchServiceError`` when a queued body cannot be
    ///   serialized, or a ``ClientResponseError`` when the request fails.
    open func send(options: SendOptions? = nil) async throws -> [BatchRequestResult] {
        let queued = getRequests()

        for (index, item) in queued.enumerated() {
            if let reason = item.unsupportedBodyReason {
                throw BatchServiceError.unsupportedBody(index: index, reason: reason)
            }
        }

        var jsonData: [[String: AnyCodable]] = []
        var formFields: [String: SendOptions.FormValue] = [:]

        for (index, item) in queued.enumerated() {
            let req = item.request

            var itemDict: [String: AnyCodable] = [
                "method": AnyCodable(req.method),
                "url": AnyCodable(req.url)
            ]
            if let headers = req.headers {
                itemDict["headers"] = AnyCodable(headers)
            }
            // The reference SDK always includes the body key, even when empty.
            itemDict["body"] = AnyCodable(req.json ?? [:])
            jsonData.append(itemDict)

            if let files = req.files {
                for (key, fileList) in files {
                    let formKey = "requests.\(index).\(key)"
                    formFields[formKey] = .files(fileList)
                }
            }
        }

        let payloadDict: [String: AnyCodable] = ["requests": AnyCodable(jsonData)]
        formFields["@jsonPayload"] = .json(AnyCodable(payloadDict))

        let multipart = MultipartFormData(fields: formFields)

        var opt = options ?? SendOptions()
        opt.applyDefaultMethod("POST")
        if opt.body == nil {
            opt.body = .data(multipart.bodyData)
            if !hasHeader(opt.headers, name: "Content-Type") {
                opt.headers["Content-Type"] = multipart.contentTypeHeader
            }
        }

        return try await client.send(path: "/api/batch", options: opt)
    }

    /// Case-insensitive header presence check.
    private func hasHeader(_ headers: [String: String], name: String) -> Bool {
        headers.keys.contains { $0.lowercased() == name.lowercased() }
    }
}

/// Queues record operations for one collection into a parent ``BatchService``.
///
/// Obtain an instance through ``BatchService/collection(_:)``. Every method uses a
/// fixed HTTP method (`PUT` for ``upsert(bodyParams:options:)``, `POST` for
/// ``create(bodyParams:options:)``, `PATCH` for ``update(id:bodyParams:options:)``,
/// and `DELETE` for ``delete(id:options:)``). The request body is taken from
/// `bodyParams` unless the caller already set `options.body`, which takes precedence.
///
/// The body must be `.json`, a `.rawJson` object or `.form`; other body kinds
/// are rejected by ``BatchService/send(options:)`` with
/// ``BatchServiceError/unsupportedBody(index:reason:)``.
open class SubBatchService: @unchecked Sendable {
    private unowned let batchService: BatchService
    /// The collection identifier or name targeted by this sub-batch service.
    public let collectionIdOrName: String

    /// Creates a sub-batch service bound to one collection.
    ///
    /// Prefer ``BatchService/collection(_:)`` over creating instances directly.
    ///
    /// - Parameter batchService: The parent batch service that receives queued requests.
    /// - Parameter collectionIdOrName: The collection identifier or name.
    public init(batchService: BatchService, collectionIdOrName: String) {
        self.batchService = batchService
        self.collectionIdOrName = collectionIdOrName
    }

    /// Queues an upsert (`PUT`) request for the collection.
    ///
    /// The body is taken from `bodyParams` unless the caller already set `options.body`.
    ///
    /// - Parameter bodyParams: The record fields to submit. Ignored when
    ///   `options.body` is set. Must be `.json`, a `.rawJson` object or `.form`.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func upsert(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "PUT",
            url: "/api/collections/\(collectionIdOrName.encodeURIComponent())/records",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

    /// Queues a create (`POST`) request for the collection.
    ///
    /// The body is taken from `bodyParams` unless the caller already set `options.body`.
    ///
    /// - Parameter bodyParams: The record fields to submit. Ignored when
    ///   `options.body` is set. Must be `.json`, a `.rawJson` object or `.form`.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func create(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "POST",
            url: "/api/collections/\(collectionIdOrName.encodeURIComponent())/records",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

    /// Queues an update (`PATCH`) request for a record.
    ///
    /// The body is taken from `bodyParams` unless the caller already set `options.body`.
    ///
    /// - Parameter id: The record identifier.
    /// - Parameter bodyParams: The record fields to submit. Ignored when
    ///   `options.body` is set. Must be `.json`, a `.rawJson` object or `.form`.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func update(id: String, bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let encodedId = id.encodeURIComponent()
        let req = prepareRequest(
            method: "PATCH",
            url: "/api/collections/\(collectionIdOrName.encodeURIComponent())/records/\(encodedId)",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

    /// Queues a delete (`DELETE`) request for a record.
    ///
    /// - Parameter id: The record identifier.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func delete(id: String, options: SendOptions? = nil) {
        let encodedId = id.encodeURIComponent()
        let req = prepareRequest(
            method: "DELETE",
            url: "/api/collections/\(collectionIdOrName.encodeURIComponent())/records/\(encodedId)",
            bodyParams: nil,
            options: options
        )
        batchService.appendRequest(req)
    }

    private func prepareRequest(
        method: String,
        url: String,
        bodyParams: SendOptions.AnySendableBody?,
        options: SendOptions?
    ) -> QueuedBatchRequest {
        var opt = options ?? SendOptions()
        opt.applyShorthandQuery()

        var finalUrl = url
        if !opt.query.isEmpty {
            let qStr = serializeQueryParams(opt.query)
            if !qStr.isEmpty {
                finalUrl += (finalUrl.contains("?") ? "&" : "?") + qStr
            }
        }

        var jsonBody: [String: AnyCodable] = [:]
        var filesBody: [String: [FileParam]] = [:]
        var unsupportedBodyReason: String?

        let bodyToExtract = opt.body ?? bodyParams
        if let body = bodyToExtract {
            switch body {
            case .json(let dict):
                jsonBody = dict
            case .rawJson(let anyCodable):
                if case .dictionary(let dict) = anyCodable.value {
                    jsonBody = dict
                } else {
                    unsupportedBodyReason = "rawJson must wrap a JSON object; use .json or .form instead"
                }
            case .form(let formDict):
                for (key, value) in formDict {
                    appendFormValue(value, key: key, jsonBody: &jsonBody, filesBody: &filesBody)
                }
            case .data:
                unsupportedBodyReason = "raw data bodies are not supported; use .json or .form instead"
            }
        }

        return QueuedBatchRequest(
            request: BatchRequest(
                method: method,
                url: finalUrl,
                json: jsonBody,
                files: filesBody.isEmpty ? nil : filesBody,
                headers: opt.headers.isEmpty ? nil : opt.headers
            ),
            unsupportedBodyReason: unsupportedBodyReason
        )
    }

    /// Maps one form value into the JSON body and file fields of a batch request.
    ///
    /// Regular values are embedded in the JSON payload; files become multipart
    /// fields. When one field carries both, the files are appended under a
    /// `+`-suffixed key so the server appends instead of replacing, mirroring
    /// the JavaScript SDK.
    private func appendFormValue(
        _ value: SendOptions.FormValue,
        key: String,
        jsonBody: inout [String: AnyCodable],
        filesBody: inout [String: [FileParam]]
    ) {
        switch value {
        case .string(let s):
            jsonBody[key] = AnyCodable(s)
        case .json(let j):
            jsonBody[key] = j
        case .file(let f):
            filesBody[key, default: []].append(f)
        case .files(let fs):
            filesBody[key, default: []].append(contentsOf: fs)
        case .array(let values):
            var regulars: [AnyCodable] = []
            var foundFiles: [FileParam] = []
            splitFormValues(values, regulars: &regulars, files: &foundFiles)

            if !foundFiles.isEmpty && regulars.isEmpty {
                filesBody[key, default: []].append(contentsOf: foundFiles)
            } else {
                jsonBody[key] = AnyCodable(regulars)
                if !foundFiles.isEmpty {
                    let fileKey = (key.hasPrefix("+") || key.hasSuffix("+")) ? key : key + "+"
                    filesBody[fileKey, default: []].append(contentsOf: foundFiles)
                }
            }
        }
    }

    /// Partitions form values into regular JSON values and files, flattening
    /// nested arrays like the reference SDK's batch serializer.
    private func splitFormValues(
        _ values: [SendOptions.FormValue],
        regulars: inout [AnyCodable],
        files: inout [FileParam]
    ) {
        for value in values {
            switch value {
            case .string(let s):
                regulars.append(AnyCodable(s))
            case .json(let j):
                regulars.append(j)
            case .file(let f):
                files.append(f)
            case .files(let fs):
                files.append(contentsOf: fs)
            case .array(let nested):
                splitFormValues(nested, regulars: &regulars, files: &files)
            }
        }
    }
}
