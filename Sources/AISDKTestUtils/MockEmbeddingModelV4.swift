import AISDKProviderUtils
import Foundation

/// A scriptable embedding model for tests. Mirrors upstream `MockEmbeddingModelV4`.
public final class MockEmbeddingModelV4: EmbeddingModelV4, @unchecked Sendable {
  public let provider: String
  public let modelId: String
  private let maxPerCall: Int?
  private let parallel: Bool
  private let handler: @Sendable (EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result
  private let lock = NSLock()
  private var calls: [EmbeddingModelV4CallOptions] = []

  public init(
    provider: String = "mock-provider",
    modelId: String = "mock-model-id",
    maxEmbeddingsPerCall: Int? = 1,
    supportsParallelCalls: Bool = true,
    doEmbed: @escaping @Sendable (EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result
  ) {
    self.provider = provider
    self.modelId = modelId
    self.maxPerCall = maxEmbeddingsPerCall
    self.parallel = supportsParallelCalls
    self.handler = doEmbed
  }

  public var maxEmbeddingsPerCall: Int? { get async throws { maxPerCall } }
  public var supportsParallelCalls: Bool { get async throws { parallel } }

  /// Options of every `doEmbed` call.
  public var doEmbedCalls: [EmbeddingModelV4CallOptions] { lock.withLock { calls } }

  public func doEmbed(_ options: EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result {
    lock.withLock { calls.append(options) }
    return try await handler(options)
  }
}
