@_exported import AISDKProviderUtils
import Foundation

/// Settings for an OpenAI-compatible provider. Mirrors upstream `OpenAICompatibleProviderSettings`.
public struct OpenAICompatibleProviderSettings: Sendable {
  /// Base URL for API calls, e.g. `https://api.example.com/v1`.
  public var baseURL: String
  /// Provider name, used as the provider ID prefix and provider-options key.
  public var name: String
  /// Sent as `Authorization: Bearer <apiKey>` when set.
  public var apiKey: String?
  /// Custom headers, applied after the `Authorization` header.
  public var headers: [String: String]?
  /// Query parameters appended to every request URL.
  public var queryParams: [String: String]?
  public var httpClient: (any HTTPClient)?
  /// Requests usage in streaming responses.
  public var includeUsage: Bool
  /// Whether chat models accept `response_format.json_schema`.
  public var supportsStructuredOutputs: Bool
  public var transformRequestBody: (@Sendable (JSONObject) -> JSONObject)?
  public var metadataExtractor: (any OpenAICompatibleMetadataExtractor)?
  public var supportedUrls: [String: [String]]
  public var convertUsage: (@Sendable (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage)?

  public init(
    baseURL: String,
    name: String,
    apiKey: String? = nil,
    headers: [String: String]? = nil,
    queryParams: [String: String]? = nil,
    httpClient: (any HTTPClient)? = nil,
    includeUsage: Bool = false,
    supportsStructuredOutputs: Bool = false,
    transformRequestBody: (@Sendable (JSONObject) -> JSONObject)? = nil,
    metadataExtractor: (any OpenAICompatibleMetadataExtractor)? = nil,
    supportedUrls: [String: [String]] = [:],
    convertUsage: (@Sendable (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage)? = nil
  ) {
    self.baseURL = baseURL
    self.name = name
    self.apiKey = apiKey
    self.headers = headers
    self.queryParams = queryParams
    self.httpClient = httpClient
    self.includeUsage = includeUsage
    self.supportsStructuredOutputs = supportsStructuredOutputs
    self.transformRequestBody = transformRequestBody
    self.metadataExtractor = metadataExtractor
    self.supportedUrls = supportedUrls
    self.convertUsage = convertUsage
  }
}

/// A provider for any OpenAI-compatible API (vLLM, Ollama, LM Studio, Groq,
/// Together, OpenRouter, …). Mirrors upstream `OpenAICompatibleProvider`.
///
/// ```swift
/// let lmstudio = createOpenAICompatible(.init(baseURL: "http://localhost:1234/v1", name: "lmstudio"))
/// let result = try await generateText(model: lmstudio("qwen3-8b"), prompt: "Hello")
/// ```
public struct OpenAICompatibleProvider: ProviderV4 {
  public let settings: OpenAICompatibleProviderSettings
  let baseURL: String

  init(settings: OpenAICompatibleProviderSettings) {
    self.settings = settings
    self.baseURL = withoutTrailingSlash(settings.baseURL) ?? settings.baseURL
  }

  /// Creates a chat model.
  public func callAsFunction(_ modelId: String) -> OpenAICompatibleChatLanguageModel {
    chatModel(modelId)
  }

  public func chatModel(_ modelId: String) -> OpenAICompatibleChatLanguageModel {
    OpenAICompatibleChatLanguageModel(
      modelId: modelId,
      config: OpenAICompatibleChatConfig(
        provider: "\(settings.name).chat", headers: headers, url: url, httpClient: settings.httpClient,
        includeUsage: settings.includeUsage, supportsStructuredOutputs: settings.supportsStructuredOutputs,
        supportedUrls: settings.supportedUrls, transformRequestBody: settings.transformRequestBody,
        metadataExtractor: settings.metadataExtractor, convertUsage: settings.convertUsage))
  }

  public func completionModel(_ modelId: String) -> OpenAICompatibleCompletionLanguageModel {
    OpenAICompatibleCompletionLanguageModel(
      modelId: modelId,
      config: OpenAICompatibleCompletionConfig(
        provider: "\(settings.name).completion", headers: headers, url: url, httpClient: settings.httpClient,
        includeUsage: settings.includeUsage))
  }

  public func textEmbeddingModel(_ modelId: String) -> OpenAICompatibleEmbeddingModel {
    OpenAICompatibleEmbeddingModel(
      modelId: modelId,
      config: OpenAICompatibleEmbeddingConfig(
        provider: "\(settings.name).embedding", headers: headers, url: url, httpClient: settings.httpClient))
  }

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    chatModel(modelId)
  }

  public func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4 {
    textEmbeddingModel(modelId)
  }

  private var headers: @Sendable () throws -> [String: String] {
    let settings = settings
    return {
      var headers: [String: String] = [:]
      if let apiKey = settings.apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
      for (name, value) in settings.headers ?? [:] { headers[name] = value }
      return withUserAgentSuffix(headers, "ai-sdk/openai-compatible/\(AISDK_VERSION)")
    }
  }

  private var url: @Sendable (String) -> String {
    let baseURL = baseURL
    let queryParams = settings.queryParams
    return { path in
      guard let queryParams, !queryParams.isEmpty, var components = URLComponents(string: baseURL + path) else {
        return baseURL + path
      }
      components.queryItems = queryParams.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
      return components.string ?? baseURL + path
    }
  }
}

/// Creates an OpenAI-compatible provider. Mirrors upstream `createOpenAICompatible`.
public func createOpenAICompatible(_ settings: OpenAICompatibleProviderSettings) -> OpenAICompatibleProvider {
  OpenAICompatibleProvider(settings: settings)
}
