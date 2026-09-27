@_exported import AISDKProviderUtils
import Foundation

/// Settings for the OpenAI provider. Mirrors upstream `OpenAIProviderSettings`.
public struct OpenAIProviderSettings: Sendable {
  /// Defaults to `OPENAI_BASE_URL`, then `https://api.openai.com/v1`.
  public var baseURL: String?
  /// Defaults to the `OPENAI_API_KEY` environment variable.
  public var apiKey: String?
  /// Sent as `OpenAI-Organization`.
  public var organization: String?
  /// Sent as `OpenAI-Project`.
  public var project: String?
  public var headers: [String: String]?
  /// Overrides the `openai` provider name, e.g. for third-party deployments.
  public var name: String?
  public var httpClient: (any HTTPClient)?
  public var generateId: IdGenerator?

  public init(
    baseURL: String? = nil, apiKey: String? = nil, organization: String? = nil, project: String? = nil,
    headers: [String: String]? = nil, name: String? = nil, httpClient: (any HTTPClient)? = nil,
    generateId: IdGenerator? = nil
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.organization = organization
    self.project = project
    self.headers = headers
    self.name = name
    self.httpClient = httpClient
    self.generateId = generateId
  }
}

/// The OpenAI provider. Mirrors upstream `OpenAIProvider`.
///
/// ```swift
/// let openai = try createOpenAI()
/// let result = try await generateText(model: openai("gpt-5.4-mini"), prompt: "Hello")
/// ```
public struct OpenAIProvider: ProviderV4 {
  public let settings: OpenAIProviderSettings
  let baseURL: String
  let providerName: String

  init(settings: OpenAIProviderSettings) throws {
    self.settings = settings
    let configured = loadOptionalSetting(settingValue: settings.baseURL, environmentVariableName: "OPENAI_BASE_URL")
    if let configured, URL(string: configured)?.scheme == nil {
      throw InvalidArgumentError(argument: "baseURL", message: "Invalid base URL: \(configured)")
    }
    self.baseURL = withoutTrailingSlash(configured) ?? "https://api.openai.com/v1"
    self.providerName = settings.name ?? "openai"
  }

  /// Creates a Responses API model, the default OpenAI model.
  public func callAsFunction(_ modelId: String) -> OpenAIResponsesLanguageModel {
    responses(modelId)
  }

  /// Creates a Responses API model (`POST /responses`).
  public func responses(_ modelId: String) -> OpenAIResponsesLanguageModel {
    var config = config("responses")
    config.fileIdPrefixes = ["file-"]
    return OpenAIResponsesLanguageModel(modelId: modelId, config: config)
  }

  /// OpenAI's built-in Responses API tools.
  public var tools: OpenAITools.Type { OpenAITools.self }

  /// Creates a Chat Completions model (`POST /chat/completions`).
  public func chat(_ modelId: String) -> OpenAIChatLanguageModel {
    OpenAIChatLanguageModel(modelId: modelId, config: config("chat"))
  }

  /// Creates a legacy completions model (`POST /completions`).
  public func completion(_ modelId: String) -> OpenAICompletionLanguageModel {
    OpenAICompletionLanguageModel(modelId: modelId, config: config("completion"))
  }

  /// Creates an embedding model (`POST /embeddings`).
  public func embedding(_ modelId: String) -> OpenAIEmbeddingModel {
    OpenAIEmbeddingModel(modelId: modelId, config: config("embedding"))
  }

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    responses(modelId)
  }

  public func embeddingModel(_ modelId: String) throws -> any EmbeddingModelV4 {
    embedding(modelId)
  }

  var headers: @Sendable () throws -> [String: String] {
    let settings = settings
    return {
      var headers = [
        "Authorization": "Bearer \(try loadApiKey(apiKey: settings.apiKey, environmentVariableName: "OPENAI_API_KEY", description: "OpenAI"))"
      ]
      if let organization = settings.organization { headers["OpenAI-Organization"] = organization }
      if let project = settings.project { headers["OpenAI-Project"] = project }
      for (name, value) in settings.headers ?? [:] { headers[name] = value }
      return withUserAgentSuffix(headers, "ai-sdk/openai/\(AISDK_VERSION)")
    }
  }

  func config(_ modelType: String) -> OpenAIConfig {
    let baseURL = baseURL
    return OpenAIConfig(
      provider: "\(providerName).\(modelType)", headers: headers, url: { "\(baseURL)\($0)" },
      httpClient: settings.httpClient, generateId: settings.generateId ?? AISDKProviderUtils.generateId)
  }
}

/// Creates an OpenAI provider. Mirrors upstream `createOpenAI`.
///
/// - Throws: `InvalidArgumentError` when the base URL is not a valid URL.
public func createOpenAI(_ settings: OpenAIProviderSettings = OpenAIProviderSettings()) throws -> OpenAIProvider {
  try OpenAIProvider(settings: settings)
}
