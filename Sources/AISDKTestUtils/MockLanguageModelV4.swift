import AISDKProviderUtils
import Foundation

/// A scriptable language model for tests. Mirrors upstream `MockLanguageModelV4`
/// from `ai/test`.
///
/// Configure fixed results, a sequence of results (one per call), or closures,
/// then inspect the recorded calls.
public final class MockLanguageModelV4: LanguageModelV4, @unchecked Sendable {
  public enum GenerateBehavior: Sendable {
    case result(LanguageModelV4GenerateResult)
    case sequence([LanguageModelV4GenerateResult])
    case handler(@Sendable (LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult)
    case notImplemented
  }

  public enum StreamBehavior: Sendable {
    case parts([LanguageModelV4StreamPart])
    case sequence([[LanguageModelV4StreamPart]])
    case handler(@Sendable (LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult)
    case notImplemented
  }

  public let provider: String
  public let modelId: String
  private let urls: [String: [String]]
  private let generateBehavior: GenerateBehavior
  private let streamBehavior: StreamBehavior
  private let lock = NSLock()
  private var generateCalls: [LanguageModelV4CallOptions] = []
  private var streamCalls: [LanguageModelV4CallOptions] = []

  public init(
    provider: String = "mock-provider",
    modelId: String = "mock-model-id",
    supportedUrls: [String: [String]] = [:],
    doGenerate: GenerateBehavior = .notImplemented,
    doStream: StreamBehavior = .notImplemented
  ) {
    self.provider = provider
    self.modelId = modelId
    self.urls = supportedUrls
    self.generateBehavior = doGenerate
    self.streamBehavior = doStream
  }

  public var supportedUrls: [String: [String]] {
    get async throws { urls }
  }

  /// Options of every `doGenerate` call.
  public var doGenerateCalls: [LanguageModelV4CallOptions] { lock.withLock { generateCalls } }

  /// Options of every `doStream` call.
  public var doStreamCalls: [LanguageModelV4CallOptions] { lock.withLock { streamCalls } }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let index = lock.withLock {
      generateCalls.append(options)
      return generateCalls.count - 1
    }
    switch generateBehavior {
    case .result(let result):
      return result
    case .sequence(let results):
      return results[min(index, results.count - 1)]
    case .handler(let handler):
      return try await handler(options)
    case .notImplemented:
      throw UnsupportedFunctionalityError(functionality: "doGenerate")
    }
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let index = lock.withLock {
      streamCalls.append(options)
      return streamCalls.count - 1
    }
    switch streamBehavior {
    case .parts(let parts):
      return LanguageModelV4StreamResult(stream: streamFromArray(parts))
    case .sequence(let sequences):
      return LanguageModelV4StreamResult(stream: streamFromArray(sequences[min(index, sequences.count - 1)]))
    case .handler(let handler):
      return try await handler(options)
    case .notImplemented:
      throw UnsupportedFunctionalityError(functionality: "doStream")
    }
  }
}

extension LanguageModelV4GenerateResult {
  /// A text result for tests.
  public static func mockText(
    _ text: String,
    finishReason: LanguageModelV4FinishReason.Unified = .stop,
    usage: LanguageModelV4Usage = .mock,
    providerMetadata: SharedV4ProviderMetadata? = nil,
    warnings: [SharedV4Warning] = []
  ) -> LanguageModelV4GenerateResult {
    LanguageModelV4GenerateResult(
      content: [.text(LanguageModelV4Text(text: text))],
      finishReason: LanguageModelV4FinishReason(unified: finishReason, raw: finishReason.rawValue),
      usage: usage,
      providerMetadata: providerMetadata,
      response: LanguageModelV4ResponseInfo(
        metadata: LanguageModelV4ResponseMetadata(
          id: "id-0", timestamp: Date(timeIntervalSince1970: 0), modelId: "mock-model-id")),
      warnings: warnings)
  }
}

extension LanguageModelV4Usage {
  /// Usage with 3 input and 10 output tokens, as in upstream test fixtures.
  public static let mock = LanguageModelV4Usage(
    inputTokens: .init(total: 3, noCache: 3, cacheRead: 0, cacheWrite: 0),
    outputTokens: .init(total: 10, text: 10, reasoning: 0))
}
