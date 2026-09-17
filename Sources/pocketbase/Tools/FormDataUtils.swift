import Foundation

/// An encoded `multipart/form-data` request body.
///
/// The initializer serializes the form fields into a single ``bodyData``
/// payload separated by ``boundary`` and exposes the matching `Content-Type`
/// value in ``contentTypeHeader``.
///
/// The encoding mirrors the reference SDK's
/// `convertToFormDataIfNeeded`:
///
/// - ``SendOptions/FormValue/string(_:)`` and files are appended under their
///   field name.
/// - ``SendOptions/FormValue/json(_:)`` values are wrapped as
///   `{"<field>": <value>}` and appended under the reserved `@jsonPayload`
///   field, so the server merges them without applying its implicit string
///   inference.
/// - ``SendOptions/FormValue/jsonPayload(_:)`` values are appended under
///   `@jsonPayload` verbatim.
/// - ``SendOptions/FormValue/array(_:)`` values emit one part per element.
///
/// Field names and filenames are escaped the way browsers do it: carriage
/// returns, line feeds and double quotes become `%0D`, `%0A` and `%22`.
///
/// ```swift
/// let formData = MultipartFormData(fields: [
///     "title": .string("Hello"),
///     "meta": .json(AnyCodable(["tags": ["a", "b"]])),
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
            data.append(jsonPayloadPart(wrapping: AnyCodable([key: anyCodable]), boundary: boundary))

        case .jsonPayload(let anyCodable):
            data.append(jsonPayloadPart(wrapping: anyCodable, boundary: boundary))

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

    /// Encodes a part for the reserved `@jsonPayload` field.
    private static func jsonPayloadPart(wrapping value: AnyCodable, boundary: String) -> Data {
        guard let encodedData = try? JSONEncoder().encode(value),
              let jsonString = String(data: encodedData, encoding: .utf8) else {
            return Data()
        }
        return textPart(named: "@jsonPayload", value: jsonString, boundary: boundary)
    }

    /// Encodes a plain text part.
    private static func textPart(named key: String, value: String, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(escape(key))\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
        return data
    }

    /// Encodes a file part with its filename and MIME type.
    private static func filePart(named key: String, file fileParam: FileParam, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(escape(key))\"; filename=\"\(escape(fileParam.filename))\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(fileParam.mimeType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileParam.data)
        data.append("\r\n".data(using: .utf8)!)
        return data
    }

    /// Escapes a name or filename like browser `FormData` implementations do.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
