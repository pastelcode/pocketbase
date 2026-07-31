import Foundation

public typealias CustomFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public struct FileParam: Equatable, Sendable, Codable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String = "application/octet-stream", data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct SendOptions: Sendable {
    public var method: String
    public var headers: [String: String]
    public var body: AnySendableBody?
    public var query: [String: AnyCodable]
    public var requestKey: String?
    public var fetch: CustomFetch?
    public var autoRefresh: Bool?
    public var autoRefreshThreshold: Double?

    public enum AnySendableBody: Sendable {
        case data(Data)
        case json([String: AnyCodable])
        case rawJson(AnyCodable)
        case form([String: FormValue])
    }

    public enum FormValue: Sendable {
        case string(String)
        case file(FileParam)
        case files([FileParam])
        case json(AnyCodable)
    }

    public init(
        method: String = "GET",
        headers: [String: String] = [:],
        body: AnySendableBody? = nil,
        query: [String: AnyCodable] = [:],
        requestKey: String? = nil,
        fetch: CustomFetch? = nil,
        autoRefresh: Bool? = nil,
        autoRefreshThreshold: Double? = nil
    ) {
        self.method = method
        self.headers = headers
        self.body = body
        self.query = query
        self.requestKey = requestKey
        self.fetch = fetch
        self.autoRefresh = autoRefresh
        self.autoRefreshThreshold = autoRefreshThreshold
    }
}

extension String {
    public func encodeURIComponent() -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return self.addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

public func serializeQueryParams(_ params: [String: AnyCodable]) -> String {
    var result: [String] = []

    let sortedKeys = params.keys.sorted()

    for key in sortedKeys {
        guard let value = params[key] else { continue }
        let encodedKey = key.encodeURIComponent()

        let arrValues: [AnyCodable]
        if case .array(let arr) = value.value {
            arrValues = arr
        } else {
            arrValues = [value]
        }

        for v in arrValues {
            if let prepared = prepareQueryParamValue(v) {
                result.append("\(encodedKey)=\(prepared)")
            }
        }
    }

    return result.joined(separator: "&")
}

private func prepareQueryParamValue(_ val: AnyCodable) -> String? {
    switch val.value {
    case .null:
        return nil
    case .bool(let b):
        return String(b)
    case .int(let i):
        return String(i)
    case .double(let d):
        return String(d)
    case .string(let s):
        return s.encodeURIComponent()
    case .array, .dictionary:
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(val),
           let jsonStr = String(data: data, encoding: .utf8) {
            return jsonStr.encodeURIComponent()
        }
        return nil
    }
}
