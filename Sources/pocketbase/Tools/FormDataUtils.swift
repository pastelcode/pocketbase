import Foundation

/// An encoded `multipart/form-data` request body.
///
/// The initializer serializes the form fields into a single ``bodyData``
/// payload separated by ``boundary`` and exposes the matching `Content-Type`
/// value in ``contentTypeHeader``.
///
/// ```swift
/// let formData = MultipartFormData(fields: [
///     "title": .string("Hello"),
///     "avatar": .file(FileParam(filename: "avatar.png", mimeType: "image/png", data: pngData))
/// ])
/// ```
public struct MultipartFormData: Sendable {
    /// The boundary string that separates the encoded parts.
    public let boundary: String
    /// The fully encoded request body.
    public let bodyData: Data
    /// The value for the request's `Content-Type` header.
    public let contentTypeHeader: String

    /// Encodes the given form fields into a multipart body.
    ///
    /// String and JSON values are written as plain parts, while files include
    /// their filename and MIME type.
    ///
    /// - Parameters:
    ///   - fields: A dictionary of form field names to
    ///     ``SendOptions/FormValue`` values.
    ///   - boundary: The multipart boundary. Defaults to a unique generated
    ///     string.
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
