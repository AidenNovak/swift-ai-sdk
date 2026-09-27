/// Whether a middleware call wraps `doGenerate` or `doStream`.
public enum LanguageModelV4CallType: String, Sendable, Hashable {
  case generate
  case stream
}

/// Options passed to `wrapGenerate` / `wrapStream`.
public struct LanguageModelV4WrapOptions: Sendable {
  /// Calls the wrapped model's `doGenerate` with the transformed params.
  public var doGenerate: @Sendable () async throws -> LanguageModelV4GenerateResult
  /// Calls the wrapped model's `doStream` with the transformed params.
  public var doStream: @Sendable () async throws -> LanguageModelV4StreamResult
  public var params: LanguageModelV4CallOptions
  public var model: any LanguageModelV4

  public init(
    doGenerate: @escaping @Sendable () async throws -> LanguageModelV4GenerateResult,
    doStream: @escaping @Sendable () async throws -> LanguageModelV4StreamResult,
    params: LanguageModelV4CallOptions,
    model: any LanguageModelV4
  ) {
    self.doGenerate = doGenerate
    self.doStream = doStream
    self.params = params
    self.model = model
  }
}

/// Middleware for language models. Mirrors upstream `LanguageModelV4Middleware`.
public struct LanguageModelV4Middleware: Sendable {
  public var overrideProvider: (@Sendable (any LanguageModelV4) -> String)?
  public var overrideModelId: (@Sendable (any LanguageModelV4) -> String)?
  public var overrideSupportedUrls: (@Sendable (any LanguageModelV4) async throws -> [String: [String]])?
  /// Transforms the call options before they reach the model.
  public var transformParams:
    (@Sendable (LanguageModelV4CallType, LanguageModelV4CallOptions, any LanguageModelV4) async throws
      -> LanguageModelV4CallOptions)?
  /// Wraps `doGenerate`.
  public var wrapGenerate: (@Sendable (LanguageModelV4WrapOptions) async throws -> LanguageModelV4GenerateResult)?
  /// Wraps `doStream`.
  public var wrapStream: (@Sendable (LanguageModelV4WrapOptions) async throws -> LanguageModelV4StreamResult)?

  public init(
    overrideProvider: (@Sendable (any LanguageModelV4) -> String)? = nil,
    overrideModelId: (@Sendable (any LanguageModelV4) -> String)? = nil,
    overrideSupportedUrls: (@Sendable (any LanguageModelV4) async throws -> [String: [String]])? = nil,
    transformParams: (
      @Sendable (LanguageModelV4CallType, LanguageModelV4CallOptions, any LanguageModelV4) async throws
        -> LanguageModelV4CallOptions
    )? = nil,
    wrapGenerate: (@Sendable (LanguageModelV4WrapOptions) async throws -> LanguageModelV4GenerateResult)? = nil,
    wrapStream: (@Sendable (LanguageModelV4WrapOptions) async throws -> LanguageModelV4StreamResult)? = nil
  ) {
    self.overrideProvider = overrideProvider
    self.overrideModelId = overrideModelId
    self.overrideSupportedUrls = overrideSupportedUrls
    self.transformParams = transformParams
    self.wrapGenerate = wrapGenerate
    self.wrapStream = wrapStream
  }
}

/// Options passed to `EmbeddingModelV4Middleware.wrapEmbed`.
public struct EmbeddingModelV4WrapOptions: Sendable {
  public var doEmbed: @Sendable () async throws -> EmbeddingModelV4Result
  public var params: EmbeddingModelV4CallOptions
  public var model: any EmbeddingModelV4

  public init(
    doEmbed: @escaping @Sendable () async throws -> EmbeddingModelV4Result,
    params: EmbeddingModelV4CallOptions,
    model: any EmbeddingModelV4
  ) {
    self.doEmbed = doEmbed
    self.params = params
    self.model = model
  }
}

/// Middleware for embedding models. Mirrors upstream `EmbeddingModelV4Middleware`.
public struct EmbeddingModelV4Middleware: Sendable {
  public var overrideProvider: (@Sendable (any EmbeddingModelV4) -> String)?
  public var overrideModelId: (@Sendable (any EmbeddingModelV4) -> String)?
  public var transformParams:
    (@Sendable (EmbeddingModelV4CallOptions, any EmbeddingModelV4) async throws -> EmbeddingModelV4CallOptions)?
  public var wrapEmbed: (@Sendable (EmbeddingModelV4WrapOptions) async throws -> EmbeddingModelV4Result)?

  public init(
    overrideProvider: (@Sendable (any EmbeddingModelV4) -> String)? = nil,
    overrideModelId: (@Sendable (any EmbeddingModelV4) -> String)? = nil,
    transformParams: (
      @Sendable (EmbeddingModelV4CallOptions, any EmbeddingModelV4) async throws -> EmbeddingModelV4CallOptions
    )? = nil,
    wrapEmbed: (@Sendable (EmbeddingModelV4WrapOptions) async throws -> EmbeddingModelV4Result)? = nil
  ) {
    self.overrideProvider = overrideProvider
    self.overrideModelId = overrideModelId
    self.transformParams = transformParams
    self.wrapEmbed = wrapEmbed
  }
}
