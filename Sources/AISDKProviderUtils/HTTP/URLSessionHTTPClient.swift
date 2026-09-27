import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The default `HTTPClient`, backed by `URLSession`.
///
/// Response bodies stream chunk by chunk as they arrive, which is required for
/// server-sent events.
public final class URLSessionHTTPClient: HTTPClient {
  #if canImport(FoundationNetworking)
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
      self.configuration = configuration
    }
  #else
    private let session: URLSession

    public init(session: URLSession = .shared) {
      self.session = session
    }
  #endif

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()

    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let delegate = StreamingDataDelegate()
    #if canImport(FoundationNetworking)
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      let task = session.dataTask(with: urlRequest)
      delegate.onComplete = { session.finishTasksAndInvalidate() }
    #else
      let task = session.dataTask(with: urlRequest)
      task.delegate = delegate
    #endif

    do {
      return try await withTaskCancellationHandler {
        try await delegate.start(task)
      } onCancel: {
        task.cancel()
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}

/// Bridges `URLSessionDataDelegate` callbacks to an async response head and a
/// streaming body.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var headContinuation: CheckedContinuation<HTTPResponse, any Error>?
  private let body: HTTPBodyStream
  private let bodyContinuation: HTTPBodyStream.Continuation
  var onComplete: (@Sendable () -> Void)?

  override init() {
    (body, bodyContinuation) = HTTPBodyStream.makeStream()
    super.init()
  }

  func start(_ task: URLSessionDataTask) async throws -> HTTPResponse {
    bodyContinuation.onTermination = { @Sendable _ in task.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      lock.withLock { headContinuation = continuation }
      task.resume()
    }
  }

  private func takeHeadContinuation() -> CheckedContinuation<HTTPResponse, any Error>? {
    lock.withLock {
      let continuation = headContinuation
      headContinuation = nil
      return continuation
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let httpResponse = response as? HTTPURLResponse
    var headers: [String: String] = [:]
    for (name, value) in httpResponse?.allHeaderFields ?? [:] {
      headers[String(describing: name).lowercased()] = String(describing: value)
    }
    let result = HTTPResponse(
      statusCode: httpResponse?.statusCode ?? 0, headers: headers, body: body)
    takeHeadContinuation()?.resume(returning: result)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    bodyContinuation.yield(data)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let mappedError = error.map(Self.mapCancellation)
    if let head = takeHeadContinuation() {
      head.resume(throwing: mappedError ?? URLError(.badServerResponse))
    }
    if let mappedError {
      bodyContinuation.finish(throwing: mappedError)
    } else {
      bodyContinuation.finish()
    }
    onComplete?()
  }

  private static func mapCancellation(_ error: any Error) -> any Error {
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return CancellationError()
    }
    return error
  }
}
