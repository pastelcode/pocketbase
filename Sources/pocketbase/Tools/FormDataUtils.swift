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
    /// their filename and MIME type. ``SendOptions/FormValue/array(_:)`` values
    /// emit one part per element under the same field name.
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
            Self.append(val, named: key, boundary: boundary, to: &data)
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        self.bodyData = data
    }

    /// Appends the encoded representation of one form value to `data`.
    private static func append(
        _ value: SendOptions.FormValue,
        named key: String,
        boundary: String,
        to data: inout Data
    ) {
        switch value {
        case .string(let str):
            data.append(textPart(named: key, value: str, boundary: boundary))

        case .json(let anyCodable):
            let jsonEncoder = JSONEncoder()
            if let encodedData = try? jsonEncoder.encode(anyCodable),
               let jsonString = String(data: encodedData, encoding: .utf8) {
                data.append(textPart(named: key, value: jsonString, boundary: boundary))
            }

        case .file(let fileParam):
            data.append(filePart(named: key, file: fileParam, boundary: boundary))

        case .files(let fileParams):
            for fileParam in fileParams {
                data.append(filePart(named: key, file: fileParam, boundary: boundary))
            }

        case .array(let values):
            for value in values {
                append(value, named: key, boundary: boundary, to: &data)
            }
        }
    }

    /// Encodes a plain text part.
    private static func textPart(named key: String, value: String, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
        return data
    }

    /// Encodes a file part with its filename and MIME type.
    private static func filePart(named key: String, file fileParam: FileParam, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(fileParam.filename)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(fileParam.mimeType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileParam.data)
        data.append("\r\n".data(using: .utf8)!)
        return data
    }
}
