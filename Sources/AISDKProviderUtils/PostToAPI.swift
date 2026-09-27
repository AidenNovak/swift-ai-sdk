import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The shared default HTTP client.
public let defaultHTTPClient: any HTTPClient = URLSessionHTTPClient()

/// Posts a JSON body. Mirrors upstream `postJsonToApi`.
public func postJsonToApi<Value: Sendable>(
  url: String,
  headers: [String: String]? = nil,
  body: JSONValue,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)? = nil
) async throws -> ResponseHandlerOutput<Value> {
  let content: Data
  do {
    content = try body.jsonData()
  } catch {
    throw InvalidArgumentError(argument: "body", message: "Body is not serializable.", cause: error)
  }
  return try await postToApi(
    url: url,
    headers: combineHeaders(["Content-Type": "application/json"], headers),
    body: content,
    bodyValues: body,
    failedResponseHandler: failedResponseHandler,
    successfulResponseHandler: successfulResponseHandler,
    httpClient: httpClient)
}

/// Posts a raw body. Mirrors upstream `postToApi`.
public func postToApi<Value: Sendable>(
  url: String,
  headers: [String: String]? = nil,
  body: Data,
  bodyValues: JSONValue?,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)? = nil
) async throws -> ResponseHandlerOutput<Value> {
  try await sendToApi(
    method: "POST", url: url, headers: headers, body: body, bodyValues: bodyValues,
    failedResponseHandler: failedResponseHandler,
    successfulResponseHandler: successfulResponseHandler, httpClient: httpClient)
}

/// Sends a GET request. Mirrors upstream `getFromApi`.
public func getFromApi<Value: Sendable>(
  url: String,
  headers: [String: String]? = nil,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)? = nil
) async throws -> ResponseHandlerOutput<Value> {
  try await sendToApi(
    method: "GET", url: url, headers: headers, body: nil, bodyValues: nil,
    failedResponseHandler: failedResponseHandler,
    successfulResponseHandler: successfulResponseHandler, httpClient: httpClient)
}

/// Sends a DELETE request. Mirrors upstream `deleteFromApi`.
public func deleteFromApi<Value: Sendable>(
  url: String,
  headers: [String: String]? = nil,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)? = nil
) async throws -> ResponseHandlerOutput<Value> {
  try await sendToApi(
    method: "DELETE", url: url, headers: headers, body: nil, bodyValues: nil,
    failedResponseHandler: failedResponseHandler,
    successfulResponseHandler: successfulResponseHandler, httpClient: httpClient)
}

private func sendToApi<Value: Sendable>(
  method: String,
  url: String,
  headers: [String: String]?,
  body: Data?,
  bodyValues: JSONValue?,
  failedResponseHandler: ResponseHandler<APICallError>,
  successfulResponseHandler: ResponseHandler<Value>,
  httpClient: (any HTTPClient)?
) async throws -> ResponseHandlerOutput<Value> {
  guard let requestURL = URL(string: url) else {
    throw InvalidArgumentError(argument: "url", message: "Invalid URL: \(url)")
  }
  let request = HTTPRequest(
    method: method,
    url: requestURL,
    headers: withUserAgentSuffix(
      headers, "swift-ai-sdk/provider-utils/\(AISDK_VERSION)", runtimeEnvironmentUserAgent),
    body: body)

  do {
    let response = try await (httpClient ?? defaultHTTPClient).send(request)
    let input = ResponseHandlerInput(url: url, requestBodyValues: bodyValues, response: response)

    if !response.isOK {
      let errorInformation: ResponseHandlerOutput<APICallError>
      do {
        errorInformation = try await failedResponseHandler(input)
      } catch let error where isCancellationError(error) || error is APICallError {
        throw error
      } catch {
        throw APICallError(
          message: "Failed to process error response",
          url: url,
          requestBodyValues: bodyValues,
          statusCode: response.statusCode,
          responseHeaders: response.headers,
          cause: error)
      }
      throw errorInformation.value
    }

    do {
      return try await successfulResponseHandler(input)
    } catch let error where isCancellationError(error) || error is APICallError {
      throw error
    } catch {
      throw APICallError(
        message: "Failed to process successful response",
        url: url,
        requestBodyValues: bodyValues,
        statusCode: response.statusCode,
        responseHeaders: response.headers,
        cause: error)
    }
  } catch {
    throw handleFetchError(error, url: url, requestBodyValues: bodyValues)
  }
}

/// The runtime part of the `user-agent` header.
public let runtimeEnvironmentUserAgent = "runtime/swift"

/// Whether the error means the operation was cancelled. Mirrors upstream `isAbortError`.
public func isCancellationError(_ error: any Error) -> Bool {
  if error is CancellationError { return true }
  if let urlError = error as? URLError, urlError.code == .cancelled { return true }
  return false
}

/// Converts transport failures into retryable `APICallError`s.
/// Mirrors upstream `handleFetchError`.
public func handleFetchError(_ error: any Error, url: String, requestBodyValues: JSONValue?)
  -> any Error
{
  if isCancellationError(error) {
    return CancellationError()
  }
  let networkError = findNetworkError(error)
  guard let networkError else { return error }

  if let apiCallError = error as? APICallError {
    return APICallError(
      message: apiCallError.message,
      url: apiCallError.url,
      requestBodyValues: apiCallError.requestBodyValues,
      statusCode: apiCallError.statusCode,
      responseHeaders: apiCallError.responseHeaders,
      responseBody: apiCallError.responseBody,
      cause: apiCallError.cause,
      isRetryable: true,
      data: apiCallError.data)
  }
  return APICallError(
    message: "Cannot connect to API: \(networkError.localizedDescription)",
    url: url,
    requestBodyValues: requestBodyValues,
    cause: error,
    isRetryable: true)
}

private let retryableURLErrorCodes: Set<URLError.Code> = [
  .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
  .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
]

private func findNetworkError(_ error: any Error) -> URLError? {
  var current: (any Error)? = error
  var depth = 0
  while let candidate = current, depth < 16 {
    if let urlError = candidate as? URLError, retryableURLErrorCodes.contains(urlError.code) {
      return urlError
    }
    current = (candidate as? any AISDKError)?.cause
    depth += 1
  }
  return nil
}

/// Whether the error (or one of its causes) is a network failure such as a
/// lost connection or an unreachable host.
public func isNetworkError(_ error: any Error) -> Bool {
  findNetworkError(error) != nil
}
