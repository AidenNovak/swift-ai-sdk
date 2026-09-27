import Foundation

/// An HTTP request sent by a provider.
public struct HTTPRequest: Sendable, Equatable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data?

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  /// The body decoded as JSON, if it is JSON.
  public var bodyJSON: JSONValue? {
    guard let body else { return nil }
    return try? JSONValue(jsonData: body)
  }
}

/// A stream of response body chunks.
public typealias HTTPBodyStream = AsyncThrowingStream<Data, any Error>

/// An HTTP response whose body is delivered as a stream of chunks.
public struct HTTPResponse: Sendable {
  public var statusCode: Int
  /// Response headers with lower-cased names.
  public var headers: [String: String]
  public var body: HTTPBodyStream

  public init(statusCode: Int, headers: [String: String] = [:], body: HTTPBodyStream) {
    self.statusCode = statusCode
    self.headers = Dictionary(
      headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    self.body = body
  }

  /// Creates a response with a fully buffered body.
  public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
    self.init(
      statusCode: statusCode, headers: headers,
      body: HTTPBodyStream { continuation in
        if !body.isEmpty { continuation.yield(body) }
        continuation.finish()
      })
  }

  /// Whether the status code is in the 2xx range, like `Response.ok`.
  public var isOK: Bool { (200..<300).contains(statusCode) }

  /// The standard reason phrase for the status code, like `Response.statusText`.
  public var statusText: String { HTTPStatus.reasonPhrase(for: statusCode) }

  /// Reads the whole body.
  public func bodyData() async throws -> Data {
    var data = Data()
    for try await chunk in body {
      data.append(chunk)
    }
    return data
  }

  /// Reads the whole body as UTF-8 text.
  public func bodyText() async throws -> String {
    String(decoding: try await bodyData(), as: UTF8.self)
  }
}

/// Sends HTTP requests. Every provider performs HTTP through this protocol so
/// apps can supply their own transport and tests can replay recorded responses.
public protocol HTTPClient: Sendable {
  /// Sends the request and returns as soon as the response head arrives. The
  /// body streams afterwards. Cancelling the calling task, or terminating the
  /// body stream, cancels the request.
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

enum HTTPStatus {
  static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 402: "Payment Required"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 408: "Request Timeout"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 415: "Unsupported Media Type"
    case 422: "Unprocessable Entity"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    case 529: "Site Overloaded"
    default: ""
    }
  }
}
