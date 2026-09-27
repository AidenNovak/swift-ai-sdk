import AISDKProviderUtils
import Foundation

/// Configuration for an OpenAI-compatible embedding model.
public struct OpenAICompatibleEmbeddingConfig: Sendable {
  public var provider: String
  public var headers: @Sendable () throws -> [String: String]
  public var url: @Sendable (_ path: String) -> String
  public var httpClient: (any HTTPClient)?
  /// Defaults to 2048.
  public var maxEmbeddingsPerCall: Int?
  /// Defaults to true.
  public var supportsParallelCalls: Bool?
  public var failedResponseHandler: ResponseHandler<APICallError>

  public init(
    provider: String,
    headers: @escaping @Sendable () throws -> [String: String],
    url: @escaping @Sendable (_ path: String) -> String,
    httpClient: (any HTTPClient)? = nil,
    maxEmbeddingsPerCall: Int? = nil,
    supportsParallelCalls: Bool? = nil,
    failedResponseHandler: @escaping ResponseHandler<APICallError> = defaultOpenAICompatibleFailedResponseHandler
  ) {
    self.provider = provider
    self.headers = headers
    self.url = url
    self.httpClient = httpClient
    self.maxEmbeddingsPerCall = maxEmbeddingsPerCall
    self.supportsParallelCalls = supportsParallelCalls
    self.failedResponseHandler = failedResponseHandler
  }
}

private struct OpenAICompatibleEmbeddingResponse: Decodable, Sendable {
  struct Item: Decodable, Sendable {
    var embedding: [Double]
  }

  struct Usage: Decodable, Sendable {
    var prompt_tokens: Int
  }

  var data: [Item]
  var usage: Usage?
  var providerMetadata: SharedV4ProviderMetadata?
}

/// An embedding model for any API that implements OpenAI's `/embeddings`.
/// Mirrors upstream `OpenAICompatibleEmbeddingModel`.
public struct OpenAICompatibleEmbeddingModel: EmbeddingModelV4 {
  public let modelId: String
  let config: OpenAICompatibleEmbeddingConfig

  public init(modelId: String, config: OpenAICompatibleEmbeddingConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  private var limit: Int { config.maxEmbeddingsPerCall ?? 2048 }

  public var maxEmbeddingsPerCall: Int? {
    get async throws { limit }
  }

  public var supportsParallelCalls: Bool {
    get async throws { config.supportsParallelCalls ?? true }
  }

  public func doEmbed(_ options: EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result {
    var warnings: [SharedV4Warning] = []
    let providerOptions = options.providerOptions
    let rawName = String(config.provider.split(separator: ".").first ?? "").trimmingCharacters(in: .whitespaces)

    if providerOptions?["openai-compatible"] != nil {
      warnings.append(.deprecated(setting: "providerOptions key 'openai-compatible'", message: "Use 'openaiCompatible' instead."))
    }
    warnIfDeprecatedProviderOptionsKey(rawName, providerOptions, warnings: &warnings)
    let embeddingOptions =
      try mergedProviderOptions(
        ["openai-compatible", "openaiCompatible", rawName], providerOptions, as: OpenAICompatibleEmbeddingOptions.self)
      ?? OpenAICompatibleEmbeddingOptions()

    if options.values.count > limit {
      throw TooManyEmbeddingValuesForCallError(
        provider: provider, modelId: modelId, maxEmbeddingsPerCall: limit, values: options.values)
    }

    let response = try await postJsonToApi(
      url: config.url("/embeddings"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: jsonObject([
        "model": .string(modelId),
        "input": .array(options.values.map(JSONValue.string)),
        "encoding_format": "float",
        "dimensions": .optional(embeddingOptions.dimensions),
        "user": .optional(embeddingOptions.user),
      ]),
      failedResponseHandler: config.failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAICompatibleEmbeddingResponse.self),
      httpClient: config.httpClient)

    return EmbeddingModelV4Result(
      embeddings: response.value.data.map(\.embedding),
      usage: response.value.usage.map { .init(tokens: $0.prompt_tokens) },
      providerMetadata: response.value.providerMetadata,
      response: .init(headers: response.responseHeaders, body: response.rawValue),
      warnings: warnings)
  }
}
