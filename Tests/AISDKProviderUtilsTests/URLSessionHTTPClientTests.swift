import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKProviderUtils

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Serves canned responses keyed by URL path, delivering the body in chunks.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var chunks: [Data]
  }

  nonisolated(unsafe) static var stubs: [String: Stub] = [:]
  nonisolated(unsafe) static var lastRequestBody: Data?
  static let lock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if request.url?.path == "/hang" { return }
    let stub = Self.lock.withLock { () -> Stub? in
      Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
      return Self.stubs[request.url?.path ?? ""]
    }
    guard let stub, let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in stub.chunks {
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

@Suite(.serialized) struct URLSessionHTTPClientTests {
  func makeClient() -> URLSessionHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    #if canImport(FoundationNetworking)
      return URLSessionHTTPClient(configuration: configuration)
    #else
      return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    #endif
  }

  @Test func streamsBodyAndLowercasesHeaders() async throws {
    StubURLProtocol.lock.withLock {
      StubURLProtocol.stubs["/stream"] = .init(
        statusCode: 200, headers: ["Content-Type": "text/event-stream", "X-Request-Id": "abc"],
        chunks: [Data("data: 1\n\n".utf8), Data("data: 2\n\n".utf8)])
    }
    let response = try await makeClient().send(
      HTTPRequest(
        method: "POST", url: URL(string: "https://stub.test/stream")!,
        headers: ["content-type": "application/json"], body: Data(#"{"a":1}"#.utf8)))

    #expect(response.statusCode == 200)
    #expect(response.headers["x-request-id"] == "abc")
    let events = try await collect(parseEventStream(response.body))
    #expect(events.map(\.data) == ["1", "2"])
    #expect(StubURLProtocol.lock.withLock { StubURLProtocol.lastRequestBody } == Data(#"{"a":1}"#.utf8))
  }

  @Test func deliversErrorStatusWithBody() async throws {
    StubURLProtocol.lock.withLock {
      StubURLProtocol.stubs["/error"] = .init(
        statusCode: 429, headers: ["Retry-After": "1"], chunks: [Data(#"{"error":"slow"}"#.utf8)])
    }
    let response = try await makeClient().send(
      HTTPRequest(method: "GET", url: URL(string: "https://stub.test/error")!))
    #expect(response.statusCode == 429)
    #expect(!response.isOK)
    #expect(response.headers["retry-after"] == "1")
    #expect(try await response.bodyText() == #"{"error":"slow"}"#)
  }

  @Test func cancelledTaskThrowsCancellation() async throws {
    let client = makeClient()
    let task = Task {
      try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://stub.test/hang")!))
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
  }
}
