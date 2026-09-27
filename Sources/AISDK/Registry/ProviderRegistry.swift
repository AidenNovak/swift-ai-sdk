import Foundation

/// A registry has no provider with the requested ID. Mirrors upstream `NoSuchProviderError`.
public struct NoSuchProviderError: AISDKError {
  public let name = "AI_NoSuchProviderError"
  public let message: String
  public let modelId: String
  public let modelType: NoSuchModelError.ModelType
  public let providerId: String
  public let availableProviders: [String]

  public init(
    modelId: String, modelType: NoSuchModelError.ModelType, providerId: String, availableProviders: [String],
    message: String? = nil
  ) {
    self.modelId = modelId
    self.modelType = modelType
    self.providerId = providerId
    self.availableProviders = availableProviders
    self.message =
      message ?? "No such provider: \(providerId) (available providers: \(availableProviders.joined(separator: ",")))"
  }
}

/// Looks up models by `providerId:modelId` across registered providers.
/// Mirrors upstream `createProviderRegistry`.
///
/// ```swift
/// let registry = createProviderRegistry(["deepseek": deepseek, "anthropic": anthropic])
/// let model = try registry.languageModel("deepseek:deepseek-flash")
/// ```
public struct ProviderRegistry: ProviderV4 {
  public let providers: [String: any ProviderV4]
  public let separator: String
  public let languageModelMiddleware: [LanguageModelMiddleware]

  private func split(_ id: String, _ modelType: NoSuchModelError.ModelType) throws -> (String, String) {
    guard let range = id.range(of: separator) else {
      throw NoSuchModelError(
        modelId: id, modelType: modelType,
        message:
          "Invalid \(modelType.rawValue) id for registry: \(id) (must be in the format \"providerId\(separator)modelId\")")
    }
    return (String(id[..<range.lowerBound]), String(id[range.upperBound...]))
  }

  private func provider(_ id: String, _ modelType: NoSuchModelError.ModelType) throws -> any ProviderV4 {
    guard let provider = providers[id] else {
      throw NoSuchProviderError(
        modelId: id, modelType: modelType, providerId: id, availableProviders: providers.keys.sorted())
    }
    return provider
  }

  /// Returns a language model for `providerId:modelId`.
  public func languageModel(_ id: String) throws -> any LanguageModelV4 {
    let (providerId, modelId) = try split(id, .languageModel)
    let model = try provider(providerId, .languageModel).languageModel(modelId)
    return languageModelMiddleware.isEmpty ? model : wrapLanguageModel(model: model, middleware: languageModelMiddleware)
  }

  /// Returns an embedding model for `providerId:modelId`.
  public func embeddingModel(_ id: String) throws -> any EmbeddingModelV4 {
    let (providerId, modelId) = try split(id, .embeddingModel)
    return try provider(providerId, .embeddingModel).embeddingModel(modelId)
  }
}

/// Creates a provider registry. Mirrors upstream `createProviderRegistry`.
public func createProviderRegistry(
  _ providers: [String: any ProviderV4], separator: String = ":",
  languageModelMiddleware: [LanguageModelMiddleware] = []
) -> ProviderRegistry {
  ProviderRegistry(providers: providers, separator: separator, languageModelMiddleware: languageModelMiddleware)
}

/// A provider with fixed model aliases and an optional fallback provider.
/// Mirrors upstream `customProvider`.
///
/// ```swift
/// let myProvider = customProvider(
///   languageModels: ["fast": deepseek("deepseek-flash"), "smart": deepseek("deepseek-v4-pro")],
///   fallbackProvider: deepseek)
/// ```
public struct CustomProvider: ProviderV4 {
  public let languageModels: [String: any LanguageModelV4]
  public let embeddingModels: [String: any EmbeddingModelV4]
  public let fallbackProvider: (any ProviderV4)?

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    if let model = languageModels[modelId] { return model }
    if let fallbackProvider { return try fallbackProvider.languageModel(modelId) }
    throw NoSuchModelError(modelId: modelId, modelType: .languageModel)
  }

  public func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4 {
    if let model = embeddingModels[modelId] { return model }
    if let fallbackProvider { return try fallbackProvider.embeddingModel(modelId) }
    throw NoSuchModelError(modelId: modelId, modelType: .embeddingModel)
  }
}

/// Creates a custom provider. Mirrors upstream `customProvider`.
public func customProvider(
  languageModels: [String: any LanguageModelV4] = [:],
  embeddingModels: [String: any EmbeddingModelV4] = [:],
  fallbackProvider: (any ProviderV4)? = nil
) -> CustomProvider {
  CustomProvider(languageModels: languageModels, embeddingModels: embeddingModels, fallbackProvider: fallbackProvider)
}
