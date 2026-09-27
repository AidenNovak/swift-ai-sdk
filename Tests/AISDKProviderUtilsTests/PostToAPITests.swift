import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKProviderUtils

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct ErrorBody: Codable, Sendable {
  var message: String
}

private let failedHandler = createJsonErrorResponseHandler(
  errorType: ErrorBody.self, errorToMessage: { $0.message })

@Suite struct PostToAPITests {
  let url = "https://api.example.com/v1/chat"

  @Test func sendsJSONWithLowercasedHeadersAndUserAgent() async throws {
    let client = MockHTTPClient([url: .jsonValue(["ok": true])])
    let result = try await postJsonToApi(
      url: url,
      headers: ["Authorization": "Bearer key", "User-Agent": "my-app/1.0"],
      body: ["model": "m", "stream": false],
      failedResponseHandler: failedHandler,
      successfulResponseHandler: createJsonResponseHandler(JSONValue.self),
      httpClient: client)

    #expect(result.value == ["ok": true])
    let request = try #require(client.lastRequest)
    #expect(request.method == "POST")
    #expect(request.headers["authorization"] == "Bearer key")
    #expect(request.headers["content-type"] == "application/json")
    #expect(request.headers["user-agent"] == "my-app/1.0 swift-ai-sdk/provider-utils/\(AISDK_VERSION) runtime/swift")
    #expect(request.bodyJSON == ["model": "m", "stream": false])
  }

  @Test func throwsParsedAPICallErrorForErrorStatus() async throws {
    let client = MockHTTPClient([url: .error(statusCode: 401, body: #"{"message":"bad key"}"#)])
    await #expect {
      _ = try await postJsonToApi(
        url: url, body: ["a": 1], failedResponseHandler: failedHandler,
        successfulResponseHandler: createJsonResponseHandler(JSONValue.self), httpClient: client)
    } throws: { error in
      let error = error as? APICallError
      return error?.message == "bad key" && error?.statusCode == 401 && error?.isRetryable == false
        && error?.requestBodyValues == ["a": 1]
    }
  }

  @Test func wrapsTransportFailuresAsRetryable() async throws {
    let client = MockHTTPClient([url: .failure(URLError(.cannotConnectToHost))])
    await #expect {
      _ = try await postJsonToApi(
        url: url, body: [:], failedResponseHandler: failedHandler,
        successfulResponseHandler: createJsonResponseHandler(JSONValue.self), httpClient: client)
    } throws: { error in
      let error = error as? APICallError
      return error?.message.hasPrefix("Cannot connect to API:") == true && error?.isRetryable == true
    }
  }

  @Test func passesCancellationThrough() async throws {
    let client = MockHTTPClient([url: .failure(URLError(.cancelled))])
    await #expect(throws: CancellationError.self) {
      _ = try await postJsonToApi(
        url: url, body: [:], failedResponseHandler: failedHandler,
        successfulResponseHandler: createJsonResponseHandler(JSONValue.self), httpClient: client)
    }
  }

  @Test func wrapsSuccessfulHandlerFailures() async throws {
    struct Boom: Error {}
    let client = MockHTTPClient([url: .jsonValue([:])])
    let handler: ResponseHandler<JSONValue> = { _ in throw Boom() }
    await #expect {
      _ = try await postJsonToApi(
        url: url, body: [:], failedResponseHandler: failedHandler,
        successfulResponseHandler: handler, httpClient: client)
    } throws: { error in
      (error as? APICallError)?.message == "Failed to process successful response"
    }
  }

  @Test func getFromApiSendsGet() async throws {
    let client = MockHTTPClient([url: .jsonValue(["items": []])])
    _ = try await getFromApi(
      url: url, failedResponseHandler: failedHandler,
      successfulResponseHandler: createJsonResponseHandler(JSONValue.self), httpClient: client)
    #expect(client.lastRequest?.method == "GET")
    #expect(client.lastRequest?.body == nil)
  }
}
