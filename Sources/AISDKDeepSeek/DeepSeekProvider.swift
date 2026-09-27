@_exported import AISDKProviderUtils
import Foundation

/// The version of the DeepSeek provider, sent in the `user-agent` header.
public let DEEPSEEK_PROVIDER_VERSION = AISDK_VERSION

/// Settings for the DeepSeek provider. Mirrors upstream `DeepSeekProviderSettings`.
public struct DeepSeekProviderSettings: Sendable {
  /// DeepSeek API key. Defaults to the `DEEPSEEK_API_KEY` environment variable.
  public var apiKey: String?
  /// Base URL for API calls. Defaults to `https://api.deepseek.com`. Use
  /// `https://api.deepseek.com/beta` for prefix completion and strict tools.
  public var baseURL: String?
  /// Custom headers sent with every request.
  public var headers: [String: String]?
  /// Custom HTTP transport, e.g. for proxies or tests.
  public var httpClient: (any HTTPClient)?
  public var generateId: IdGenerator?

  public init(
    apiKey: String? = nil,
    baseURL: String? = nil,
    headers: [String: String]? = nil,
    httpClient: (any HTTPClient)? = nil,
    generateId: IdGenerator? = nil
  ) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.headers = headers
    self.httpClient = httpClient
    self.generateId = generateId
  }
}

/// The DeepSeek provider. Mirrors upstream `DeepSeekProvider`.
///
/// ```swift
/// let deepseek = createDeepSeek(DeepSeekProviderSettings(apiKey: key))
/// let result = try await generateText(model: deepseek("deepseek-v4-flash"), prompt: "Hello")
/// ```
public struct DeepSeekProvider: ProviderV4 {
  let settings: DeepSeekProviderSettings
  let baseURL: String

  init(settings: DeepSeekProviderSettings) {
    self.settings = settings
    self.baseURL = withoutTrailingSlash(settings.baseURL ?? "https://api.deepseek.com") ?? "https://api.deepseek.com"
  }

  /// Creates a chat model.
  public func callAsFunction(_ modelId: String) -> DeepSeekChatLanguageModel {
    chat(modelId)
  }

  /// Creates a chat model.
  public func chat(_ modelId: String) -> DeepSeekChatLanguageModel {
    let settings = settings
    let baseURL = baseURL
    let isBeta = baseURL.hasSuffix("/beta")
    return DeepSeekChatLanguageModel(
      modelId: modelId,
      config: DeepSeekChatConfig(
        provider: "deepseek.chat",
        headers: {
          var headers = ["Authorization": "Bearer \(try loadDeepSeekAPIKey(settings.apiKey))"]
          for (name, value) in settings.headers ?? [:] { headers[name] = value }
          return withUserAgentSuffix(headers, "ai-sdk/deepseek/\(DEEPSEEK_PROVIDER_VERSION)")
        },
        url: { path in "\(baseURL)\(path)" },
        httpClient: settings.httpClient,
        supportsAssistantPrefixCompletion: isBeta,
        supportsStrictToolCalls: isBeta,
        generateId: settings.generateId ?? AISDKProviderUtils.generateId))
  }

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    chat(modelId)
  }
}

private func loadDeepSeekAPIKey(_ apiKey: String?) throws -> String {
  try loadApiKey(apiKey: apiKey, environmentVariableName: "DEEPSEEK_API_KEY", description: "DeepSeek API key")
}

/// Creates a DeepSeek provider. Mirrors upstream `createDeepSeek`.
public func createDeepSeek(_ settings: DeepSeekProviderSettings = DeepSeekProviderSettings()) -> DeepSeekProvider {
  DeepSeekProvider(settings: settings)
}

/// The default DeepSeek provider, reading `DEEPSEEK_API_KEY`. Mirrors upstream `deepSeek`.
public let deepSeek = createDeepSeek()
