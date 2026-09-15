import Foundation

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
open class BatchService: BaseService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var requests: [BatchRequest] = []
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

    func appendRequest(_ req: BatchRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(req)
    }

    private func getRequests() -> [BatchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Sends all queued requests as a single batch.
    ///
    /// The queued requests are serialized into a multipart payload and posted to
    /// `/api/batch`. The queue is not cleared by this call.
    ///
    /// - Parameter options: Additional send options. The `POST` method and multipart body are applied by default.
    /// - Returns: One result per queued request, in queue order.
    /// - Throws: A ``ClientResponseError`` when the request fails.
    open func send(options: SendOptions? = nil) async throws -> [BatchRequestResult] {
        let reqs = getRequests()

        var jsonData: [[String: AnyCodable]] = []
        var formFields: [String: SendOptions.FormValue] = [:]

        for (index, req) in reqs.enumerated() {
            var itemDict: [String: AnyCodable] = [
                "method": AnyCodable(req.method),
                "url": AnyCodable(req.url)
            ]
            if let headers = req.headers {
                itemDict["headers"] = AnyCodable(headers)
            }
            if let body = req.json {
                itemDict["body"] = AnyCodable(body)
            }
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
        opt.method = "POST"
        opt.body = .data(multipart.bodyData)
        opt.headers["Content-Type"] = multipart.contentTypeHeader

        return try await client.send(path: "/api/batch", options: opt)
    }
}

/// Queues record operations for one collection into a parent ``BatchService``.
///
/// Obtain an instance through ``BatchService/collection(_:)``. Every method uses a
/// fixed HTTP method (`PUT` for ``upsert(bodyParams:options:)``, `POST` for
/// ``create(bodyParams:options:)``, `PATCH` for ``update(id:bodyParams:options:)``,
/// and `DELETE` for ``delete(id:options:)``). The request body is taken from
/// `bodyParams` unless the caller already set `options.body`, which takes precedence.
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
    /// - Parameter bodyParams: The record fields to submit. Ignored when `options.body` is set.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func upsert(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "PUT",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

    /// Queues a create (`POST`) request for the collection.
    ///
    /// The body is taken from `bodyParams` unless the caller already set `options.body`.
    ///
    /// - Parameter bodyParams: The record fields to submit. Ignored when `options.body` is set.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func create(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "POST",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records",
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
    /// - Parameter bodyParams: The record fields to submit. Ignored when `options.body` is set.
    /// - Parameter options: Additional send options, including query parameters or headers.
    open func update(id: String, bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let req = prepareRequest(
            method: "PATCH",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records/\(encodedId)",
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
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let req = prepareRequest(
            method: "DELETE",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records/\(encodedId)",
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
    ) -> BatchRequest {
        let opt = options ?? SendOptions()
        var finalUrl = url

        if !opt.query.isEmpty {
            let qStr = serializeQueryParams(opt.query)
            if !qStr.isEmpty {
                finalUrl += (finalUrl.contains("?") ? "&" : "?") + qStr
            }
        }

        var jsonBody: [String: AnyCodable] = [:]
        var filesBody: [String: [FileParam]] = [:]

        let bodyToExtract = bodyParams ?? opt.body
        if let body = bodyToExtract {
            switch body {
            case .json(let dict):
                jsonBody = dict
            case .rawJson(let anyCodable):
                if case .dictionary(let dict) = anyCodable.value {
                    jsonBody = dict
                }
            case .form(let formDict):
                for (k, v) in formDict {
                    switch v {
                    case .string(let s):
                        jsonBody[k] = AnyCodable(s)
                    case .json(let j):
                        jsonBody[k] = j
                    case .file(let f):
                        filesBody[k] = [f]
                    case .files(let fs):
                        filesBody[k] = fs
                    }
                }
            default:
                break
            }
        }

        return BatchRequest(
            method: method,
            url: finalUrl,
            json: jsonBody.isEmpty ? nil : jsonBody,
            files: filesBody.isEmpty ? nil : filesBody,
            headers: opt.headers.isEmpty ? nil : opt.headers
        )
    }
}
