import Foundation

/// An embedding vector. Mirrors upstream `Embedding`.
public typealias Embedding = [Double]

/// The result of `embed`. Mirrors upstream `EmbedResult`.
public struct EmbedResult: Sendable, Equatable {
  public let value: String
  public let embedding: Embedding
  public let usage: EmbeddingModelUsage
  public let warnings: [Warning]
  public let providerMetadata: ProviderMetadata?
  public let response: EmbeddingModelV4Result.Response?
}

/// The result of `embedMany`. Mirrors upstream `EmbedManyResult`.
public struct EmbedManyResult: Sendable, Equatable {
  public let values: [String]
  /// Embeddings in the same order as `values`.
  public let embeddings: [Embedding]
  public let usage: EmbeddingModelUsage
  public let warnings: [Warning]
  public let providerMetadata: ProviderMetadata?
  public let responses: [EmbeddingModelV4Result.Response?]
}

/// Token usage of an embedding call. Mirrors upstream `EmbeddingModelUsage`.
public struct EmbeddingModelUsage: Sendable, Hashable {
  public var tokens: Int

  public init(tokens: Int) {
    self.tokens = tokens
  }
}

/// Embeds one value. Mirrors upstream `embed`.
public func embed(
  model: EmbeddingModel,
  value: String,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil
) async throws -> EmbedResult {
  let retry = prepareRetries(maxRetries: maxRetries)
  let options = EmbeddingModelV4CallOptions(
    values: [value], providerOptions: providerOptions, headers: withUserAgentSuffix(headers, "ai/\(AISDK_VERSION)"))
  let result = try await retry { try await model.doEmbed(options) }
  guard let embedding = result.embeddings.first, result.embeddings.count == 1 else {
    throw InvalidResponseDataError(
      data: nil, message: "Expected 1 embeddings, but received \(result.embeddings.count).")
  }
  return EmbedResult(
    value: value, embedding: embedding, usage: EmbeddingModelUsage(tokens: result.usage?.tokens ?? 0),
    warnings: result.warnings, providerMetadata: result.providerMetadata, response: result.response)
}

/// Embeds many values, splitting them into calls that respect the model's
/// `maxEmbeddingsPerCall` and running calls in parallel when supported.
/// Mirrors upstream `embedMany`.
public func embedMany(
  model: EmbeddingModel,
  values: [String],
  maxParallelCalls: Int = .max,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil
) async throws -> EmbedManyResult {
  let retry = prepareRetries(maxRetries: maxRetries)
  let headers = withUserAgentSuffix(headers, "ai/\(AISDK_VERSION)")
  let maxPerCall = try await model.maxEmbeddingsPerCall
  let supportsParallel = try await model.supportsParallelCalls

  let chunkSize = max(1, maxPerCall ?? max(values.count, 1))
  let chunks = stride(from: 0, to: values.count, by: chunkSize).map { Array(values[$0..<min($0 + chunkSize, values.count)]) }
  let parallelism = supportsParallel ? max(1, maxParallelCalls) : 1

  var results = [EmbeddingModelV4Result?](repeating: nil, count: chunks.count)
  for batchStart in stride(from: 0, to: chunks.count, by: parallelism) {
    let batch = Array(batchStart..<min(batchStart + parallelism, chunks.count))
    try await withThrowingTaskGroup(of: (Int, EmbeddingModelV4Result).self) { group in
      for index in batch {
        let chunk = chunks[index]
        group.addTask {
          let options = EmbeddingModelV4CallOptions(values: chunk, providerOptions: providerOptions, headers: headers)
          let result = try await retry { try await model.doEmbed(options) }
          guard result.embeddings.count == chunk.count else {
            throw InvalidResponseDataError(
              data: nil, message: "Expected \(chunk.count) embeddings, but received \(result.embeddings.count).")
          }
          return (index, result)
        }
      }
      for try await (index, result) in group {
        results[index] = result
      }
    }
  }

  let completed = results.compactMap { $0 }
  var providerMetadata: ProviderMetadata?
  for result in completed {
    guard let metadata = result.providerMetadata else { continue }
    var merged = providerMetadata ?? [:]
    for (provider, values) in metadata {
      merged[provider] = (merged[provider] ?? [:]).merging(values) { _, new in new }
    }
    providerMetadata = merged
  }

  return EmbedManyResult(
    values: values,
    embeddings: completed.flatMap(\.embeddings),
    usage: EmbeddingModelUsage(tokens: completed.reduce(0) { $0 + ($1.usage?.tokens ?? 0) }),
    warnings: completed.flatMap(\.warnings),
    providerMetadata: providerMetadata,
    responses: completed.map(\.response))
}

/// Cosine similarity of two vectors, in [-1, 1]. Returns 0 when either
/// vector has zero magnitude. Mirrors upstream `cosineSimilarity`.
///
/// - Throws: `InvalidArgumentError` when the vectors differ in length.
public func cosineSimilarity(_ vector1: [Double], _ vector2: [Double]) throws -> Double {
  guard vector1.count == vector2.count else {
    throw InvalidArgumentError(argument: "vector1,vector2", message: "Vectors must have the same length")
  }
  guard !vector1.isEmpty else { return 0 }
  var dot = 0.0
  var magnitude1 = 0.0
  var magnitude2 = 0.0
  for (a, b) in zip(vector1, vector2) {
    dot += a * b
    magnitude1 += a * a
    magnitude2 += b * b
  }
  guard magnitude1 != 0, magnitude2 != 0 else { return 0 }
  return dot / (magnitude1.squareRoot() * magnitude2.squareRoot())
}
