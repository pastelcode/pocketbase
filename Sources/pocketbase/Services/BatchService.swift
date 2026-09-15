import Foundation

open class BatchService: BaseService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var requests: [BatchRequest] = []
    private var subs: [String: SubBatchService] = [:]

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

open class SubBatchService: @unchecked Sendable {
    private unowned let batchService: BatchService
    public let collectionIdOrName: String

    public init(batchService: BatchService, collectionIdOrName: String) {
        self.batchService = batchService
        self.collectionIdOrName = collectionIdOrName
    }

    open func upsert(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "PUT",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

    open func create(bodyParams: SendOptions.AnySendableBody? = nil, options: SendOptions? = nil) {
        let req = prepareRequest(
            method: "POST",
            url: "/api/collections/\(collectionIdOrName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectionIdOrName)/records",
            bodyParams: bodyParams,
            options: options
        )
        batchService.appendRequest(req)
    }

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
