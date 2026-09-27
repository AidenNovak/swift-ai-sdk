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

  /// Creates a chat completions model (`POST /chat/completions`).
  public func chat(_ modelId: String) -> DeepSeekChatLanguageModel {
    DeepSeekChatLanguageModel(modelId: modelId, config: config(provider: "deepseek.chat"))
  }

  /// Creates a FIM (fill-in-the-middle) completion model (`POST /beta/completions`).
  public func completion(_ modelId: String) -> DeepSeekCompletionLanguageModel {
    DeepSeekCompletionLanguageModel(modelId: modelId, config: config(provider: "deepseek.completion"))
  }

  /// Creates a Responses API model (`POST /responses`).
  public func responses(_ modelId: String) -> DeepSeekResponsesLanguageModel {
    DeepSeekResponsesLanguageModel(modelId: modelId, config: config(provider: "deepseek.responses"))
  }

  /// The Files API.
  public func files() -> DeepSeekFiles {
    DeepSeekFiles(baseURL: apiRootURL, headers: headers, httpClient: settings.httpClient)
  }

  /// Lists the models available to the API key (`GET /models`).
  public func listModels() async throws -> [DeepSeekModelInfo] {
    try await getFromApi(
      url: "\(apiRootURL)/models", headers: try headers(),
      failedResponseHandler: createJsonErrorResponseHandler(
        errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message }),
      successfulResponseHandler: createJsonResponseHandler(DeepSeekModelList.self),
      httpClient: settings.httpClient
    ).value.data
  }

  /// Returns the account balance (`GET /user/balance`).
  public func balance() async throws -> DeepSeekBalance {
    try await getFromApi(
      url: "\(apiRootURL)/user/balance", headers: try headers(),
      failedResponseHandler: createJsonErrorResponseHandler(
        errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message }),
      successfulResponseHandler: createJsonResponseHandler(DeepSeekBalance.self),
      httpClient: settings.httpClient
    ).value
  }

  public func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
    chat(modelId)
  }

  /// The base URL without a `/beta` suffix, for non-beta endpoints.
  private var apiRootURL: String {
    baseURL.hasSuffix("/beta") ? String(baseURL.dropLast("/beta".count)) : baseURL
  }

  private var headers: @Sendable () throws -> [String: String] {
    let settings = settings
    return {
      var headers = ["Authorization": "Bearer \(try loadDeepSeekAPIKey(settings.apiKey))"]
      for (name, value) in settings.headers ?? [:] { headers[name] = value }
      return withUserAgentSuffix(headers, "ai-sdk/deepseek/\(DEEPSEEK_PROVIDER_VERSION)")
    }
  }

  private func config(provider: String) -> DeepSeekChatConfig {
    let baseURL = baseURL
    let isBeta = baseURL.hasSuffix("/beta")
    return DeepSeekChatConfig(
      provider: provider,
      headers: headers,
      url: { path in "\(baseURL)\(path)" },
      httpClient: settings.httpClient,
      supportsAssistantPrefixCompletion: isBeta,
      supportsStrictToolCalls: isBeta,
      generateId: settings.generateId ?? AISDKProviderUtils.generateId)
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
