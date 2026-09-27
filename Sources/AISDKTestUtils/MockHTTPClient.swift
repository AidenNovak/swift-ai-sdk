import AISDKProviderUtils
import Foundation

/// A replaying `HTTPClient` for tests. Mirrors upstream `createTestServer`
/// from `@ai-sdk/test-server`.
///
/// Register a response per URL, run the code under test, then inspect the
/// recorded requests.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
  /// A canned response. Mirrors the upstream test server response types.
  public enum Response: Sendable {
    /// A JSON body.
    case jsonValue(JSONValue, statusCode: Int = 200, headers: [String: String] = [:])
    /// A body streamed as the given chunks, byte for byte.
    case streamChunks([String], statusCode: Int = 200, headers: [String: String] = [:])
    /// A binary body.
    case binary(Data, statusCode: Int = 200, headers: [String: String] = [:])
    /// An error status with a raw text body.
    case error(statusCode: Int, body: String = "", headers: [String: String] = [:])
    /// An empty body.
    case empty(statusCode: Int = 200, headers: [String: String] = [:])
    /// A transport-level failure, thrown before any response arrives.
    case failure(any Error)
    /// Chunks followed by a transport failure mid-body.
    case streamChunksThenFailure([String], any Error, statusCode: Int = 200)
    /// A body the test feeds over time, e.g. a long-lived SSE stream.
    case stream(HTTPBodyStream, statusCode: Int = 200, headers: [String: String] = [:])
  }

  private let lock = NSLock()
  private var responses: [String: [Response]]
  private var recordedRequests: [HTTPRequest] = []
  private let handler: (@Sendable (HTTPRequest) async throws -> Response?)?

  /// Creates a client. Each URL maps to one response, reused for every call.
  public init(_ responses: [String: Response] = [:]) {
    self.responses = responses.mapValues { [$0] }
    self.handler = nil
  }

  /// Creates a client that answers each request with `handler`, e.g. by
  /// method. Returning `nil` falls back to the URL responses.
  public init(handler: @escaping @Sendable (HTTPRequest) async throws -> Response?) {
    self.responses = [:]
    self.handler = handler
  }

  /// Sets the response for a URL, reused for every call.
  public func respond(to url: String, with response: Response) {
    lock.withLock { responses[url] = [response] }
  }

  /// Sets a sequence of responses for a URL. The last one repeats.
  public func respond(to url: String, withSequence sequence: [Response]) {
    lock.withLock { responses[url] = sequence }
  }

  /// All requests received, in order.
  public var requests: [HTTPRequest] {
    lock.withLock { recordedRequests }
  }

  /// The most recent request.
  public var lastRequest: HTTPRequest? {
    requests.last
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    if let handler {
      lock.withLock { recordedRequests.append(request) }
      if let response = try await handler(request) { return try makeResponse(response) }
    }
    let response: Response? = lock.withLock {
      if handler == nil { recordedRequests.append(request) }
      let key = request.url.absoluteString
      guard var queue = responses[key], let first = queue.first else { return nil }
      if queue.count > 1 {
        queue.removeFirst()
        responses[key] = queue
      }
      return first
    }

    guard let response else {
      return HTTPResponse(statusCode: 404, body: Data("No mock response for \(request.url)".utf8))
    }
    return try makeResponse(response)
  }

  private func makeResponse(_ response: Response) throws -> HTTPResponse {
    switch response {
    case .jsonValue(let value, let statusCode, let headers):
      return HTTPResponse(
        statusCode: statusCode,
        headers: ["content-type": "application/json"].merging(headers) { _, new in new },
        body: try value.jsonData())
    case .streamChunks(let chunks, let statusCode, let headers):
      return HTTPResponse(
        statusCode: statusCode,
        headers: [
          "content-type": "text/event-stream", "cache-control": "no-cache", "connection": "keep-alive",
        ].merging(headers) { _, new in new },
        body: HTTPBodyStream { continuation in
          for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
          continuation.finish()
        })
    case .binary(let data, let statusCode, let headers):
      return HTTPResponse(statusCode: statusCode, headers: headers, body: data)
    case .error(let statusCode, let body, let headers):
      return HTTPResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8))
    case .empty(let statusCode, let headers):
      return HTTPResponse(statusCode: statusCode, headers: headers, body: Data())
    case .failure(let error):
      throw error
    case .streamChunksThenFailure(let chunks, let error, let statusCode):
      return HTTPResponse(
        statusCode: statusCode,
        headers: ["content-type": "text/event-stream"],
        body: HTTPBodyStream { continuation in
          for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
          continuation.finish(throwing: error)
        })
    case .stream(let body, let statusCode, let headers):
      return HTTPResponse(
        statusCode: statusCode,
        headers: ["content-type": "text/event-stream"].merging(headers) { _, new in new }, body: body)
    }
  }
}
