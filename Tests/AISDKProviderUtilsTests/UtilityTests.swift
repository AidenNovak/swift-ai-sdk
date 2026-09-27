import Foundation
import Testing

@testable import AISDKProviderUtils

@Suite struct SettingsTests {
  @Test func loadApiKeyPrefersParameter() throws {
    #expect(
      try loadApiKey(
        apiKey: "param", environmentVariableName: "X_KEY", description: "X", environment: ["X_KEY": "env"])
        == "param")
  }

  @Test func loadApiKeyFallsBackToEnvironment() throws {
    #expect(
      try loadApiKey(
        apiKey: nil, environmentVariableName: "X_KEY", description: "X", environment: ["X_KEY": "env"])
        == "env")
  }

  @Test func loadApiKeyMissingMessage() {
    #expect {
      _ = try loadApiKey(
        apiKey: nil, environmentVariableName: "DEEPSEEK_API_KEY", description: "DeepSeek", environment: [:])
    } throws: { error in
      (error as? LoadAPIKeyError)?.message
        == "DeepSeek API key is missing. Pass it using the 'apiKey' parameter or the DEEPSEEK_API_KEY environment variable."
    }
  }

  @Test func loadSettingAndOptionalSetting() throws {
    #expect(
      try loadSetting(
        settingValue: nil, environmentVariableName: "BASE", settingName: "baseURL", description: "X",
        environment: ["BASE": "https://x"]) == "https://x")
    #expect(throws: LoadSettingError.self) {
      try loadSetting(
        settingValue: nil, environmentVariableName: "BASE", settingName: "baseURL", description: "X",
        environment: [:])
    }
    #expect(loadOptionalSetting(settingValue: nil, environmentVariableName: "BASE", environment: [:]) == nil)
    #expect(loadOptionalSetting(settingValue: "v", environmentVariableName: "BASE", environment: [:]) == "v")
  }

  @Test func withoutTrailingSlashRemovesOneSlash() {
    #expect(withoutTrailingSlash("https://api.deepseek.com/") == "https://api.deepseek.com")
    #expect(withoutTrailingSlash("https://api.deepseek.com") == "https://api.deepseek.com")
    #expect(withoutTrailingSlash(nil) == nil)
  }

  @Test func combineHeadersLaterWinsCaseInsensitively() {
    let combined = combineHeaders(["Authorization": "a", "X": "1"], nil, ["authorization": "b"])
    #expect(combined == ["X": "1", "authorization": "b"])
  }

  @Test func userAgentSuffix() {
    #expect(withUserAgentSuffix(nil, "ai-sdk/1") == ["user-agent": "ai-sdk/1"])
    #expect(
      withUserAgentSuffix(["User-Agent": "app/2", "X-Custom": "v"], "ai-sdk/1", "runtime/swift")
        == ["user-agent": "app/2 ai-sdk/1 runtime/swift", "x-custom": "v"])
  }

  @Test func parseProviderOptionsDecodesProviderEntry() throws {
    struct Options: Decodable, Equatable { var thinking: Bool }
    #expect(
      try parseProviderOptions(
        provider: "deepseek", providerOptions: ["deepseek": ["thinking": true]], as: Options.self)
        == Options(thinking: true))
    #expect(try parseProviderOptions(provider: "deepseek", providerOptions: nil, as: Options.self) == nil)
    #expect(throws: InvalidArgumentError.self) {
      try parseProviderOptions(
        provider: "deepseek", providerOptions: ["deepseek": ["thinking": "yes"]], as: Options.self)
    }
  }
}

@Suite struct GenerateIdTests {
  @Test func generatesIdWithRequestedLength() throws {
    let generator = try createIdGenerator(size: 10)
    #expect(generator().count == 10)
    #expect(generateId().count == 16)
  }

  @Test func prefixesIds() throws {
    let generator = try createIdGenerator(prefix: "msg")
    let id = generator()
    #expect(id.hasPrefix("msg-"))
    #expect(id.count == 20)
  }

  @Test func rejectsSeparatorInAlphabet() {
    #expect(throws: InvalidArgumentError.self) {
      try createIdGenerator(prefix: "b", separator: "a")
    }
  }

  @Test func generatesUniqueIds() {
    #expect(Set((0..<100).map { _ in generateId() }).count == 100)
  }
}

@Suite struct RetryTests {
  struct Retryable: Error {}
  struct Fatal: Error {}

  actor Counter {
    var value = 0
    func increment() -> Int {
      value += 1
      return value
    }
  }

  @Test func retriesUntilSuccess() async throws {
    let counter = Counter()
    let retry = RetryWithExponentialBackoff(initialDelayInMs: 1, shouldRetry: { $0 is Retryable })
    let result = try await retry {
      if await counter.increment() < 3 { throw Retryable() }
      return "ok"
    }
    #expect(result == "ok")
    #expect(await counter.value == 3)
  }

  @Test func wrapsAfterMaxRetries() async throws {
    let retry = RetryWithExponentialBackoff(maxRetries: 2, initialDelayInMs: 1, shouldRetry: { _ in true })
    await #expect {
      _ = try await retry { () async throws -> Int in throw Retryable() }
    } throws: { error in
      (error as? GenericRetryError)?.message.hasPrefix("Failed after 3 attempts. Last error:") == true
    }
  }

  @Test func nonRetryableFirstErrorPassesThrough() async throws {
    let retry = RetryWithExponentialBackoff(initialDelayInMs: 1, shouldRetry: { $0 is Retryable })
    await #expect(throws: Fatal.self) {
      _ = try await retry { () async throws -> Int in throw Fatal() }
    }
  }

  @Test func nonRetryableLaterErrorIsWrapped() async throws {
    let counter = Counter()
    let retry = RetryWithExponentialBackoff(
      initialDelayInMs: 1, shouldRetry: { $0 is Retryable },
      createRetryError: { message, reason, errors in
        GenericRetryError(message: "\(reason.rawValue):\(errors.count)")
      })
    await #expect {
      _ = try await retry { () async throws -> Int in
        if await counter.increment() == 1 { throw Retryable() }
        throw Fatal()
      }
    } throws: { error in
      (error as? GenericRetryError)?.message == "errorNotRetryable:2"
    }
  }

  @Test func zeroRetriesPassesErrorThrough() async throws {
    let retry = RetryWithExponentialBackoff(maxRetries: 0, shouldRetry: { _ in true })
    await #expect(throws: Retryable.self) {
      _ = try await retry { () async throws -> Int in throw Retryable() }
    }
  }

  @Test func cancellationIsNotRetried() async throws {
    let counter = Counter()
    let retry = RetryWithExponentialBackoff(initialDelayInMs: 1, shouldRetry: { _ in true })
    await #expect(throws: CancellationError.self) {
      _ = try await retry { () async throws -> Int in
        _ = await counter.increment()
        throw CancellationError()
      }
    }
    #expect(await counter.value == 1)
  }
}

@Suite struct SchemaAndParseTests {
  struct Point: Codable, Sendable, Equatable {
    var x: Int
    var y: Int
  }

  @Test func decodableSchemaValidates() throws {
    let schema = Schema(Point.self, jsonSchema: ["type": "object"])
    #expect(try validateTypes(value: ["x": 1, "y": 2], schema: schema) == Point(x: 1, y: 2))
    #expect(throws: TypeValidationError.self) {
      try validateTypes(value: ["x": "one"], schema: schema)
    }
  }

  @Test func safeValidateReportsContext() {
    let schema = Schema(Point.self, jsonSchema: ["type": "object"])
    let result = safeValidateTypes(
      value: ["x": 1], schema: schema, context: TypeValidationContext(field: "input"))
    let error = result.error as? TypeValidationError
    #expect(error?.context?.field == "input")
    #expect(result.rawValue == ["x": 1])
  }

  @Test func parseJSONVariants() throws {
    #expect(try parseJSON(#"{"x":1,"y":2}"#, as: Point.self) == Point(x: 1, y: 2))
    #expect(throws: JSONParseError.self) { try parseJSON("{", as: Point.self) }
    #expect(throws: TypeValidationError.self) { try parseJSON("[]", as: Point.self) }
    #expect(safeParseJSON("[1]").value == [1])
    #expect(isParsableJson("{}"))
    #expect(!isParsableJson("{"))
  }

  @Test func customValidatorSchema() throws {
    let positive = jsonSchema(["type": "number"]) { value -> Double in
      guard let number = value.doubleValue, number > 0 else {
        throw InvalidArgumentError(argument: "value", message: "must be positive")
      }
      return number
    }
    #expect(try positive.validate(3) == 3)
    #expect(throws: TypeValidationError.self) { try validateTypes(value: -1, schema: positive) }
  }

  @Test func base64Helpers() {
    #expect(convertBase64ToData("aGk") == Data("hi".utf8))
    #expect(convertBase64ToData("-_8") == Data([0xFB, 0xFF]))
    #expect(convertDataToBase64(Data("hi".utf8)) == "aGk=")
  }
}
