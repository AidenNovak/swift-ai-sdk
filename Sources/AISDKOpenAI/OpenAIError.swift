import AISDKProviderUtils
import Foundation

/// The OpenAI error body. Mirrors upstream `OpenAIErrorData`.
public struct OpenAIErrorData: Decodable, Sendable {
  public struct Detail: Decodable, Sendable {
    public var message: String
    public var type: String?
    public var param: JSONValue?
    public var code: JSONValue?
  }

  public var error: Detail
}

/// Mirrors upstream `openaiFailedResponseHandler`.
public let openaiFailedResponseHandler: ResponseHandler<APICallError> =
  createJsonErrorResponseHandler(errorType: OpenAIErrorData.self, errorToMessage: { $0.error.message })

private struct OpenAIStreamErrorInfo {
  var message: String
  var code: JSONValue?
  var type: String?
}

private func parseStreamError(_ frame: JSONValue) -> OpenAIStreamErrorInfo? {
  guard case .object(let value) = frame else { return nil }

  if value["type"]?.stringValue == "response.failed" {
    guard let error = value["response"]?["error"]?.objectValue, let message = error["message"]?.stringValue else {
      return nil
    }
    return OpenAIStreamErrorInfo(message: message, code: stringOrNumber(error["code"]), type: "response.failed")
  }

  let nested = value["error"]?.objectValue
  let error = nested ?? value
  guard let message = error["message"]?.stringValue,
    nested != nil || error["type"]?.stringValue != nil || error.keys.contains("code") || error.keys.contains("param")
  else { return nil }
  return OpenAIStreamErrorInfo(message: message, code: stringOrNumber(error["code"]), type: error["type"]?.stringValue)
}

private func stringOrNumber(_ value: JSONValue?) -> JSONValue? {
  switch value {
  case .string?, .number?: value
  default: nil
  }
}

private func httpStatusCode(_ code: JSONValue?) -> Int? {
  let number: Int? =
    switch code {
    case .number(let value)? where value == value.rounded(): Int(value)
    case .string(let value)? where value.count == 3 && value.allSatisfy(\.isNumber): Int(value)
    default: nil
    }
  guard let number, (400...599).contains(number) else { return nil }
  return number
}

private func statusCode(_ error: OpenAIStreamErrorInfo) -> Int {
  if let explicit = httpStatusCode(error.code) { return explicit }

  let codeText: String? =
    switch error.code {
    case .string(let value)?: value
    case .number(let value)?: value == value.rounded() ? String(Int(value)) : String(value)
    default: nil
    }
  let discriminator = [codeText, error.type].compactMap { $0 }.joined(separator: " ").lowercased()

  if ["insufficient_quota", "rate_limit"].contains(where: discriminator.contains) { return 429 }
  if discriminator.contains("authentication") { return 401 }
  if discriminator.contains("permission") { return 403 }
  if discriminator.contains("not_found") { return 404 }
  if ["invalid", "bad_request", "context_length"].contains(where: discriminator.contains) { return 400 }
  if discriminator.contains("overload") { return 503 }
  if discriminator.contains("timeout") { return 504 }
  return 500
}

private func isRetryable(_ error: OpenAIStreamErrorInfo, statusCode: Int) -> Bool {
  if error.code?.stringValue == "insufficient_quota" || error.type == "insufficient_quota" { return false }
  return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
}

/// Converts an OpenAI stream error frame into a `ProviderStreamError`.
/// Mirrors upstream `createOpenAIProviderStreamError`.
public func createOpenAIProviderStreamError(_ frame: JSONValue) -> ProviderStreamError? {
  guard let error = parseStreamError(frame) else { return nil }
  let status = statusCode(error)
  return ProviderStreamError(
    message: error.message, type: error.type, code: error.code, statusCode: status,
    isRetryable: isRetryable(error, statusCode: status), data: frame)
}

private final class IteratorBox<Element: Sendable>: @unchecked Sendable {
  var iterator: AsyncThrowingStream<Element, any Error>.AsyncIterator

  init(_ iterator: AsyncThrowingStream<Element, any Error>.AsyncIterator) {
    self.iterator = iterator
  }
}

/// Reads ahead until the first output chunk and throws an `APICallError` if
/// an error frame arrives first, so errors that happen before any output
/// (e.g. `insufficient_quota`) surface as call failures that can be retried.
/// Mirrors upstream `throwIfOpenAIStreamErrorBeforeOutput`.
///
/// - Parameter isAcceptedChunk: Marks a chunk proving generation has started.
///   After it, the read-ahead only waits `acceptedGraceMilliseconds` per chunk.
func throwIfOpenAIStreamErrorBeforeOutput<Chunk: Sendable>(
  stream: AsyncThrowingStream<ParseResult<Chunk>, any Error>,
  getError: @escaping @Sendable (Chunk) -> JSONValue?,
  isOutputChunk: @escaping @Sendable (Chunk) -> Bool,
  isAcceptedChunk: (@Sendable (Chunk) -> Bool)? = nil,
  acceptedGraceMilliseconds: UInt64 = 50,
  url: String,
  requestBodyValues: JSONValue?,
  responseHeaders: [String: String]?
) async throws -> AsyncThrowingStream<ParseResult<Chunk>, any Error> {
  let box = IteratorBox(stream.makeAsyncIterator())
  var buffered: [ParseResult<Chunk>] = []
  var pendingRead: Task<ParseResult<Chunk>?, any Error>?
  var accepted = false

  readAhead: while true {
    let read = Task { try await box.iterator.next() }
    let next: ParseResult<Chunk>?
    if accepted {
      let timeout = Task {
        try? await Task.sleep(nanoseconds: acceptedGraceMilliseconds * 1_000_000)
        return true
      }
      let timedOut = await withTaskGroup(of: Bool.self) { group in
        group.addTask { _ = try? await read.value; return false }
        group.addTask { await timeout.value }
        let first = await group.next() ?? true
        group.cancelAll()
        return first
      }
      timeout.cancel()
      if timedOut {
        pendingRead = read
        break readAhead
      }
      next = try await read.value
    } else {
      next = try await read.value
    }

    guard let chunk = next else { break }
    buffered.append(chunk)
    guard case .success(let value, _) = chunk else { break }

    if let frame = getError(value) {
      let streamError = createOpenAIProviderStreamError(frame)
      throw APICallError(
        message: streamError?.message ?? "OpenAI stream failed before any output was generated",
        url: url, requestBodyValues: requestBodyValues, statusCode: streamError?.statusCode ?? 500,
        responseHeaders: responseHeaders, responseBody: frame.jsonString(sortedKeys: false),
        isRetryable: streamError?.isRetryable, data: frame)
    }
    if isOutputChunk(value) { break }
    if !accepted, isAcceptedChunk?(value) == true { accepted = true }
  }

  let prefix = buffered
  let pending = pendingRead
  let (output, continuation) = AsyncThrowingStream<ParseResult<Chunk>, any Error>.makeStream()
  let task = Task {
    do {
      for chunk in prefix { continuation.yield(chunk) }
      if let pending, let chunk = try await pending.value {
        continuation.yield(chunk)
      } else if pending != nil {
        continuation.finish()
        return
      }
      while let chunk = try await box.iterator.next() {
        continuation.yield(chunk)
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}
