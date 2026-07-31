import Foundation

public struct MultipartFormData: Sendable {
    public let boundary: String
    public let bodyData: Data
    public let contentTypeHeader: String

    public init(fields: [String: SendOptions.FormValue], boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
        self.contentTypeHeader = "multipart/form-data; boundary=\(boundary)"

        var data = Data()

        for (key, val) in fields {
            switch val {
            case .string(let str):
                data.append("--\(boundary)\r\n".data(using: .utf8)!)
                data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                data.append("\(str)\r\n".data(using: .utf8)!)

            case .json(let anyCodable):
                let jsonEncoder = JSONEncoder()
                if let encodedData = try? jsonEncoder.encode(anyCodable),
                   let jsonString = String(data: encodedData, encoding: .utf8) {
                    data.append("--\(boundary)\r\n".data(using: .utf8)!)
                    data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                    data.append("\(jsonString)\r\n".data(using: .utf8)!)
                }

            case .file(let fileParam):
                data.append("--\(boundary)\r\n".data(using: .utf8)!)
                data.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(fileParam.filename)\"\r\n".data(using: .utf8)!)
                data.append("Content-Type: \(fileParam.mimeType)\r\n\r\n".data(using: .utf8)!)
                data.append(fileParam.data)
                data.append("\r\n".data(using: .utf8)!)

            case .files(let fileParams):
                for fileParam in fileParams {
                    data.append("--\(boundary)\r\n".data(using: .utf8)!)
                    data.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(fileParam.filename)\"\r\n".data(using: .utf8)!)
                    data.append("Content-Type: \(fileParam.mimeType)\r\n\r\n".data(using: .utf8)!)
                    data.append(fileParam.data)
                    data.append("\r\n".data(using: .utf8)!)
                }
            }
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        self.bodyData = data
    }
}
