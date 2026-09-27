import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKProviderUtils

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct Message: Codable, Sendable, Equatable {
  var id: String
  var text: String
}

private struct ErrorBody: Codable, Sendable {
  struct Detail: Codable, Sendable { var message: String }
  var error: Detail
}

private func input(_ response: HTTPResponse) -> ResponseHandlerInput {
  ResponseHandlerInput(url: "test-url", requestBodyValues: ["prompt": "test"], response: response)
}

@Suite struct ResponseHandlerTests {
  @Test func jsonHandlerReturnsParsedAndRawValue() async throws {
    let handler = createJsonResponseHandler(Message.self)
    let result = try await handler(
      input(HTTPResponse(statusCode: 200, headers: ["X-Id": "1"], body: Data(#"{"id":"1","text":"hi","extra":true}"#.utf8))))
    #expect(result.value == Message(id: "1", text: "hi"))
    #expect(result.rawValue == ["id": "1", "text": "hi", "extra": true])
    #expect(result.responseHeaders == ["x-id": "1"])
  }

  @Test func jsonHandlerThrowsAPICallErrorForInvalidJSON() async throws {
    let handler = createJsonResponseHandler(Message.self)
    await #expect {
      _ = try await handler(input(HTTPResponse(statusCode: 200, body: Data("not json".utf8))))
    } throws: { error in
      let error = error as? APICallError
      return error?.message == "Invalid JSON response" && error?.responseBody == "not json"
        && error?.cause is JSONParseError && error?.requestBodyValues == ["prompt": "test"]
    }
  }

  @Test func jsonErrorHandlerParsesErrorBody() async throws {
    let handler = createJsonErrorResponseHandler(
      errorType: ErrorBody.self, errorToMessage: { $0.error.message })
    let result = try await handler(
      input(HTTPResponse(statusCode: 429, body: Data(#"{"error":{"message":"slow down"}}"#.utf8))))
    #expect(result.value.message == "slow down")
    #expect(result.value.statusCode == 429)
    #expect(result.value.isRetryable)
    #expect(result.value.data == ["error": ["message": "slow down"]])
  }

  @Test func jsonErrorHandlerFallsBackToStatusText() async throws {
    let handler = createJsonErrorResponseHandler(
      errorType: ErrorBody.self, errorToMessage: { $0.error.message })
    let empty = try await handler(input(HTTPResponse(statusCode: 400, body: Data())))
    #expect(empty.value.message == "Bad Request")
    #expect(!empty.value.isRetryable)

    let html = try await handler(input(HTTPResponse(statusCode: 502, body: Data("<html>".utf8))))
    #expect(html.value.message == "Bad Gateway")
    #expect(html.value.responseBody == "<html>")
    #expect(html.value.isRetryable)
  }

  @Test func jsonErrorHandlerUsesCustomRetryability() async throws {
    let handler = createJsonErrorResponseHandler(
      errorType: ErrorBody.self, errorToMessage: { $0.error.message },
      isRetryable: { response, _ in response.statusCode == 400 })
    let result = try await handler(input(HTTPResponse(statusCode: 400, body: Data())))
    #expect(result.value.isRetryable)
  }

  @Test func eventSourceHandlerMarksBodySocketErrorsAsRetryable() async throws {
    struct Chunk: Decodable, Sendable { var value: String }
    let handler = createEventSourceResponseHandler(Chunk.self)
    let response = HTTPResponse(
      statusCode: 200, headers: ["x-request-id": "request-id"],
      body: HTTPBodyStream { continuation in
        continuation.yield(Data("data: {\"value\":\"partial\"}\n\n".utf8))
        continuation.finish(throwing: URLError(.networkConnectionLost))
      })
    let result = try await handler(input(response))

    var iterator = result.value.makeAsyncIterator()
    #expect(try await iterator.next()?.value?.value == "partial")
    await #expect {
      _ = try await iterator.next()
    } throws: { error in
      let error = error as? APICallError
      return error?.message == "Failed to process successful response" && error?.isRetryable == true
        && error?.statusCode == 200 && error?.responseHeaders == ["x-request-id": "request-id"]
    }
  }

  @Test func jsonLinesHandlerParsesAcrossByteBoundaries() async throws {
    let bytes = Array("{\"id\":\"first\",\"text\":\"café\"}\r\n\n{\"id\":\"second\",\"text\":\"done\"}".utf8)
    let response = HTTPResponse(
      statusCode: 200,
      body: HTTPBodyStream { continuation in
        for byte in bytes { continuation.yield(Data([byte])) }
        continuation.finish()
      })
    let result = try await createJsonLinesResponseHandler(Message.self)(input(response))
    #expect(
      try await collect(result.value) == [
        Message(id: "first", text: "café"), Message(id: "second", text: "done"),
      ])
  }

  @Test func jsonLinesHandlerFailsOnInvalidLine() async throws {
    let response = HTTPResponse(statusCode: 200, body: Data("{\"id\":\"1\",\"text\":\"a\"}\nnope\n".utf8))
    let result = try await createJsonLinesResponseHandler(Message.self)(input(response))
    await #expect(throws: JSONParseError.self) { _ = try await collect(result.value) }
  }

  @Test func binaryHandlerReturnsBytes() async throws {
    let result = try await createBinaryResponseHandler()(
      input(HTTPResponse(statusCode: 200, body: Data([1, 2, 3]))))
    #expect(result.value == Data([1, 2, 3]))
  }

  @Test func statusCodeErrorHandlerIncludesBody() async throws {
    let result = try await createStatusCodeErrorResponseHandler()(
      input(HTTPResponse(statusCode: 404, body: Data("missing".utf8))))
    #expect(result.value.message == "Not Found")
    #expect(result.value.responseBody == "missing")
    #expect(result.value.statusCode == 404)
  }
}
