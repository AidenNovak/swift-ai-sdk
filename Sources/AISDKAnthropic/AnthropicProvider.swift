@_exported import AISDKProviderUtils
import Foundation

/// The default versioned Anthropic API URL.
public let ANTHROPIC_API_VERSIONED_URL = "https://api.anthropic.com/v1"

/// Settings for the Anthropic provider. Mirrors upstream `AnthropicProviderSettings`.
public struct AnthropicProviderSettings: Sendable {
  /// Base URL, e.g. `https://api.anthropic.com/v1`. Defaults to the
  /// `ANTHROPIC_BASE_URL` environment variable, then the Anthropic API.
  public var baseURL: String?
  /// API key sent in `x-api-key`. Defaults to `ANTHROPIC_API_KEY`.
  public var apiKey: String?
  /// Bearer token sent in `Authorization`. Use instead of `apiKey`.
  public var authToken: String?
  /// Custom headers sent with every request.
  public var headers: [String: String]?
  /// Provider name, used as the provider options key. Defaults to `anthropic.messages`.
  public var name: String?
  public var httpClient: (any HTTPClient)?
  public var generateId: IdGenerator?

  public init(
    baseURL: String? = nil,
    apiKey: String? = nil,
    authToken: String? = nil,
    headers: [String: String]? = nil,
    name: String? = nil,
    httpClient: (any HTTPClient)? = nil,
    generateId: IdGenerator? = nil
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.authToken = authToken
    self.headers = headers
    self.name = name
    self.httpClient = httpClient
    self.generateId = generateId
  }
}

/// The Anthropic provider. Mirrors upstream `AnthropicProvider`.
///
/// Anthropic-compatible services work through `baseURL`, for example DeepSeek:
///
/// ```swift
/// let deepseek = try createAnthropic(AnthropicProviderSettings(
///   baseURL: "https://api.deepseek.com/anthropic/v1", apiKey: deepseekKey, name: "deepseek.messages"))
/// ```
public struct AnthropicProvider: ProviderV4 {
  let config: AnthropicMessagesConfig

  /// Creates a Messages model.
  public func callAsFunction(_ modelId: String) -> AnthropicMessagesLanguageModel {
    messages(modelId)
  }

  /// Creates a Messages model.
  public func messages(_ modelId: String) -> AnthropicMessagesLanguageModel {
    AnthropicMessagesLanguageModel(modelId: modelId, config: config)
  }

  /// Creates a Messages model. Same as `messages(_:)`.
  public func chat(_ modelId: String) -> AnthropicMessagesLanguageModel {
    messages(modelId)
  }

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    messages(modelId)
  }
}

/// Creates an Anthropic provider. Mirrors upstream `createAnthropic`.
///
/// - Throws: `InvalidArgumentError` when both `apiKey` and `authToken` are set.
public func createAnthropic(_ settings: AnthropicProviderSettings = AnthropicProviderSettings()) throws
  -> AnthropicProvider
{
  if settings.apiKey != nil && settings.authToken != nil {
    throw InvalidArgumentError(
      argument: "apiKey/authToken",
      message: "Both apiKey and authToken were provided. Please use only one authentication method.")
  }
  let baseURL =
    withoutTrailingSlash(loadOptionalSetting(settingValue: settings.baseURL, environmentVariableName: "ANTHROPIC_BASE_URL"))
    ?? ANTHROPIC_API_VERSIONED_URL

  return AnthropicProvider(
    config: AnthropicMessagesConfig(
      provider: settings.name ?? "anthropic.messages",
      baseURL: baseURL,
      headers: {
        var headers: [String: String] = ["anthropic-version": "2023-06-01"]
        if let authToken = settings.authToken {
          headers["Authorization"] = "Bearer \(authToken)"
        } else {
          headers["x-api-key"] = try loadApiKey(
            apiKey: settings.apiKey, environmentVariableName: "ANTHROPIC_API_KEY", description: "Anthropic")
        }
        for (name, value) in settings.headers ?? [:] { headers[name] = value }
        return withUserAgentSuffix(headers, "ai-sdk/anthropic/\(AISDK_VERSION)")
      },
      httpClient: settings.httpClient,
      supportedUrls: ["image/*": ["^https?://.*$"], "application/pdf": ["^https?://.*$"]],
      generateId: settings.generateId ?? AISDKProviderUtils.generateId))
}
