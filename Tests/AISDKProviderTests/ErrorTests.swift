import Foundation
import Testing

@testable import AISDKProvider

@Suite struct GetErrorMessageTests {
  struct CustomError: Error, CustomStringConvertible {
    var description: String { "CustomError: custom failure" }
  }

  @Test func nilReturnsUnknownError() {
    #expect(getErrorMessage(nil) == "unknown error")
  }

  @Test func stringsAreReturnedAsIs() {
    #expect(getErrorMessage("something went wrong") == "something went wrong")
    #expect(getErrorMessage("") == "")
  }

  @Test func errorsUseTheirDescription() {
    #expect(getErrorMessage(CustomError()) == "CustomError: custom failure")
  }

  @Test func sdkErrorsIncludeTheirName() {
    #expect(
      getErrorMessage(LoadAPIKeyError(message: "missing key"))
        == "AI_LoadAPIKeyError: missing key")
  }

  @Test func jsonValuesAreStringified() {
    let value: JSONValue = ["code": "FAIL"]
    #expect(getErrorMessage(value) == #"{"code":"FAIL"}"#)
    #expect(getErrorMessage(JSONValue.array(["a", "b"])) == #"["a","b"]"#)
  }
}

@Suite struct ProviderErrorTests {
  @Test(arguments: [
    (408, true), (409, true), (429, true), (500, true), (503, true),
    (400, false), (401, false), (404, false),
  ])
  func apiCallErrorRetryability(statusCode: Int, retryable: Bool) {
    let error = APICallError(
      message: "failed", url: "https://api.example.com", requestBodyValues: nil,
      statusCode: statusCode)
    #expect(error.isRetryable == retryable)
  }

  @Test func apiCallErrorWithoutStatusIsNotRetryable() {
    let error = APICallError(message: "failed", url: "u", requestBodyValues: nil)
    #expect(!error.isRetryable)
  }

  @Test func explicitRetryabilityOverridesDefault() {
    let error = APICallError(
      message: "failed", url: "u", requestBodyValues: nil, statusCode: 400, isRetryable: true)
    #expect(error.isRetryable)
  }

  @Test func typeValidationErrorMessageIncludesContext() {
    let error = TypeValidationError(
      value: ["a": 1],
      cause: InvalidArgumentError(argument: "a", message: "bad"),
      context: TypeValidationContext(field: "message.parts[0]", entityName: "tool", entityId: "t1"))
    #expect(
      error.message
        == "Type validation failed for message.parts[0] (tool, id: \"t1\"): Value: {\"a\":1}.\nError message: AI_InvalidArgumentError: bad"
    )
  }

  @Test func typeValidationErrorWrapReusesMatchingError() {
    let original = TypeValidationError(value: 1, cause: LoadSettingError(message: "x"))
    let wrapped = TypeValidationError.wrap(value: 1, cause: original)
    #expect(wrapped.message == original.message)

    let rewrapped = TypeValidationError.wrap(value: 2, cause: original)
    #expect(rewrapped.value == 2)
  }

  @Test func invalidPromptErrorPrefixesMessage() {
    let error = InvalidPromptError(prompt: "[]", message: "messages must not be empty")
    #expect(error.message == "Invalid prompt: messages must not be empty")
    #expect(error.localizedDescription == "Invalid prompt: messages must not be empty")
  }

  @Test func noSuchModelErrorDefaultMessage() {
    let error = NoSuchModelError(modelId: "gpt-x", modelType: .languageModel)
    #expect(error.message == "No such languageModel: gpt-x")
  }

  @Test func tooManyEmbeddingValuesMessage() {
    let error = TooManyEmbeddingValuesForCallError(
      provider: "openai", modelId: "text-embedding-3-small", maxEmbeddingsPerCall: 2,
      values: ["a", "b", "c"])
    #expect(
      error.message
        == "Too many values for a single embedding call. The openai model \"text-embedding-3-small\" can only embed up to 2 values per call, but 3 values were provided."
    )
  }
}
