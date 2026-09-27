import Foundation

/// Input to a response handler.
public struct ResponseHandlerInput: Sendable {
  public var url: String
  public var requestBodyValues: JSONValue?
  public var response: HTTPResponse

  public init(url: String, requestBodyValues: JSONValue?, response: HTTPResponse) {
    self.url = url
    self.requestBodyValues = requestBodyValues
    self.response = response
  }
}

/// Output of a response handler.
public struct ResponseHandlerOutput<Value: Sendable>: Sendable {
  public var value: Value
  /// The raw parsed JSON, when the handler parsed JSON.
  public var rawValue: JSONValue?
  public var responseHeaders: [String: String]?

  public init(value: Value, rawValue: JSONValue? = nil, responseHeaders: [String: String]? = nil) {
    self.value = value
    self.rawValue = rawValue
    self.responseHeaders = responseHeaders
  }
}

/// Turns an HTTP response into a value. Mirrors upstream `ResponseHandler`.
public typealias ResponseHandler<Value: Sendable> =
  @Sendable (ResponseHandlerInput) async throws -> ResponseHandlerOutput<Value>

/// Parses a JSON error body into an `APICallError`. Falls back to the status
/// text when the body is empty, not JSON, or does not match `errorType`.
/// Mirrors upstream `createJsonErrorResponseHandler`.
public func createJsonErrorResponseHandler<ErrorBody: Decodable & Sendable>(
  errorType: ErrorBody.Type,
  errorToMessage: @escaping @Sendable (ErrorBody) -> String,
  isRetryable: (@Sendable (HTTPResponse, ErrorBody?) -> Bool)? = nil
) -> ResponseHandler<APICallError> {
  { input in
    let response = input.response
    let responseBody = try await response.bodyText()
    let responseHeaders = response.headers

    func fallback() -> ResponseHandlerOutput<APICallError> {
      ResponseHandlerOutput(
        value: APICallError(
          message: response.statusText,
          url: input.url,
          requestBodyValues: input.requestBodyValues,
          statusCode: response.statusCode,
          responseHeaders: responseHeaders,
          responseBody: responseBody,
          isRetryable: isRetryable?(response, nil)),
        responseHeaders: responseHeaders)
    }

    if responseBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return fallback()
    }

    guard case .success(let parsedError, let rawValue) = safeParseJSON(responseBody, as: ErrorBody.self)
    else {
      return fallback()
    }

    return ResponseHandlerOutput(
      value: APICallError(
        message: errorToMessage(parsedError),
        url: input.url,
        requestBodyValues: input.requestBodyValues,
        statusCode: response.statusCode,
        responseHeaders: responseHeaders,
        responseBody: responseBody,
        isRetryable: isRetryable?(response, parsedError),
        data: rawValue),
      responseHeaders: responseHeaders)
  }
}

/// Parses a server-sent event stream of JSON chunks.
/// Mirrors upstream `createEventSourceResponseHandler`.
public func createEventSourceResponseHandler<Chunk: Decodable & Sendable>(
  _ chunkType: Chunk.Type
) -> ResponseHandler<AsyncThrowingStream<ParseResult<Chunk>, any Error>> {
  { input in
    let body = wrapResponseBodyStream(input)
    return ResponseHandlerOutput(
      value: parseJsonEventStream(body, as: Chunk.self),
      responseHeaders: input.response.headers)
  }
}

/// Parses a JSON response body. Mirrors upstream `createJsonResponseHandler`.
public func createJsonResponseHandler<Value: Decodable & Sendable>(
  _ valueType: Value.Type
) -> ResponseHandler<Value> {
  { input in
    let responseBody = try await input.response.bodyText()
    let responseHeaders = input.response.headers

    switch safeParseJSON(responseBody, as: Value.self) {
    case .success(let value, let rawValue):
      return ResponseHandlerOutput(value: value, rawValue: rawValue, responseHeaders: responseHeaders)
    case .failure(let error, _):
      throw APICallError(
        message: "Invalid JSON response",
        url: input.url,
        requestBodyValues: input.requestBodyValues,
        statusCode: input.response.statusCode,
        responseHeaders: responseHeaders,
        responseBody: responseBody,
        cause: error)
    }
  }
}

/// Parses a newline-delimited JSON body. Mirrors upstream `createJsonLinesResponseHandler`.
public func createJsonLinesResponseHandler<Value: Decodable & Sendable>(
  _ valueType: Value.Type
) -> ResponseHandler<AsyncThrowingStream<Value, any Error>> {
  { input in
    let body = input.response.body
    let (lines, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
    let task = Task {
      var buffer = Data()
      func emit(_ lineData: Data) throws {
        var line = String(decoding: lineData, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
          continuation.yield(try parseJSON(line, as: Value.self))
        }
      }
      do {
        for try await chunk in body {
          buffer.append(chunk)
          while let newline = buffer.firstIndex(of: 0x0A) {
            try emit(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
          }
        }
        try emit(buffer)
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return ResponseHandlerOutput(value: lines, responseHeaders: input.response.headers)
  }
}

/// Reads the whole body as bytes. Mirrors upstream `createBinaryResponseHandler`.
public func createBinaryResponseHandler() -> ResponseHandler<Data> {
  { input in
    do {
      return ResponseHandlerOutput(
        value: try await input.response.bodyData(), responseHeaders: input.response.headers)
    } catch let error where isCancellationError(error) {
      throw error
    } catch {
      throw APICallError(
        message: "Failed to read response as array buffer",
        url: input.url,
        requestBodyValues: input.requestBodyValues,
        statusCode: input.response.statusCode,
        responseHeaders: input.response.headers,
        cause: error)
    }
  }
}

/// Passes the body through as a stream. Mirrors upstream `createBinaryStreamResponseHandler`.
public func createBinaryStreamResponseHandler() -> ResponseHandler<HTTPBodyStream> {
  { input in
    ResponseHandlerOutput(value: wrapResponseBodyStream(input), responseHeaders: input.response.headers)
  }
}

/// Creates an `APICallError` from the status code and raw body.
/// Mirrors upstream `createStatusCodeErrorResponseHandler`.
public func createStatusCodeErrorResponseHandler() -> ResponseHandler<APICallError> {
  { input in
    let responseBody = try await input.response.bodyText()
    return ResponseHandlerOutput(
      value: APICallError(
        message: input.response.statusText,
        url: input.url,
        requestBodyValues: input.requestBodyValues,
        statusCode: input.response.statusCode,
        responseHeaders: input.response.headers,
        responseBody: responseBody),
      responseHeaders: input.response.headers)
  }
}

/// Converts transport errors raised while reading a successful body into
/// `APICallError`s, leaving cancellation untouched.
func wrapResponseBodyStream(_ input: ResponseHandlerInput) -> HTTPBodyStream {
  let body = input.response.body
  let (stream, continuation) = HTTPBodyStream.makeStream()
  let task = Task {
    do {
      for try await chunk in body {
        continuation.yield(chunk)
      }
      continuation.finish()
    } catch let error where isCancellationError(error) {
      continuation.finish(throwing: error)
    } catch {
      continuation.finish(
        throwing: handleFetchError(
          APICallError(
            message: "Failed to process successful response",
            url: input.url,
            requestBodyValues: input.requestBodyValues,
            statusCode: input.response.statusCode,
            responseHeaders: input.response.headers,
            cause: error),
          url: input.url,
          requestBodyValues: input.requestBodyValues))
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return stream
}
