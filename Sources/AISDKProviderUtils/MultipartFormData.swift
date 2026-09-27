import Foundation

/// A `multipart/form-data` body. Mirrors upstream `FormData` usage with
/// `postFormDataToApi`.
public struct MultipartFormData: Sendable {
  public enum Value: Sendable {
    case text(String)
    case file(Data, filename: String, mediaType: String)
  }

  public let boundary: String
  public private(set) var fields: [(name: String, value: Value)] = []

  public init(boundary: String = "swift-ai-sdk-\(generateId())") {
    self.boundary = boundary
  }

  public mutating func append(_ name: String, _ text: String) {
    fields.append((name, .text(text)))
  }

  public mutating func append(_ name: String, data: Data, filename: String, mediaType: String) {
    fields.append((name, .file(data, filename: filename, mediaType: mediaType)))
  }

  /// The `Content-Type` header value, including the boundary.
  public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  /// The encoded body.
  public var body: Data {
    var data = Data()
    func line(_ string: String) { data.append(Data((string + "\r\n").utf8)) }
    for (name, value) in fields {
      line("--\(boundary)")
      switch value {
      case .text(let text):
        line("Content-Disposition: form-data; name=\"\(escape(name))\"")
        line("")
        line(text)
      case .file(let bytes, let filename, let mediaType):
        line("Content-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(filename))\"")
        line("Content-Type: \(mediaType)")
        line("")
        data.append(bytes)
        line("")
      }
    }
    line("--\(boundary)--")
    return data
  }

  /// Text fields as a JSON object, used as `requestBodyValues` in errors.
  public var textValues: JSONValue {
    var object: JSONObject = [:]
    for (name, value) in fields {
      switch value {
      case .text(let text): object[name] = .string(text)
      case .file(_, let filename, _): object[name] = .string(filename)
      }
    }
    return .object(object)
  }

  private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r\n", with: " ")
  }
}

/// Posts a multipart form. Mirrors upstream `postFormDataToApi`.
public func postFormDataToApi<Value: Sendable>(
  url: String,
  headers: [String: String]? = nil,
  formData: MultipartFormData,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)? = nil
) async throws -> ResponseHandlerOutput<Value> {
  try await postToApi(
    url: url,
    headers: combineHeaders(headers, ["Content-Type": formData.contentType]),
    body: formData.body,
    bodyValues: formData.textValues,
    failedResponseHandler: failedResponseHandler,
    successfulResponseHandler: successfulResponseHandler,
    httpClient: httpClient)
}
