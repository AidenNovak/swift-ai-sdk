/// Provider for language, embedding and other models. Mirrors upstream `ProviderV4`.
///
/// Model types whose specifications are not ported yet (image, speech,
/// transcription, reranking, video) will be added as they land.
public protocol ProviderV4: Sendable {
  /// The provider interface version. Always `"v4"`.
  var specificationVersion: String { get }

  /// Returns the language model with the given ID.
  ///
  /// - Throws: `NoSuchModelError` if the provider has no such model.
  func languageModel(_ modelId: String) throws -> any LanguageModelV4

  /// Returns the text embedding model with the given ID.
  ///
  /// - Throws: `NoSuchModelError` if the provider has no such model.
  func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4
}

extension ProviderV4 {
  public var specificationVersion: String { "v4" }

  public func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4 {
    throw NoSuchModelError(modelId: modelId, modelType: .embeddingModel)
  }
}
