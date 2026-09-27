import Foundation

/// The language model type accepted by core functions. Mirrors upstream `LanguageModel`.
public typealias LanguageModel = any LanguageModelV4

/// The embedding model type accepted by core functions. Mirrors upstream `EmbeddingModel`.
public typealias EmbeddingModel = any EmbeddingModelV4

/// Why a model finished generating. Mirrors upstream `FinishReason`.
public typealias FinishReason = LanguageModelV4FinishReason.Unified

/// A warning from the model provider. Mirrors upstream `Warning`.
public typealias Warning = SharedV4Warning

/// Provider-specific options. Mirrors upstream `ProviderOptions`.
public typealias ProviderOptions = SharedV4ProviderOptions

/// Provider-specific metadata. Mirrors upstream `ProviderMetadata`.
public typealias ProviderMetadata = SharedV4ProviderMetadata

/// File data in messages. Mirrors upstream `FileData` / `DataContent`.
public typealias FileData = SharedV4FileData

/// Tool choice for a generation call. Mirrors upstream `ToolChoice`.
public enum ToolChoice: Sendable, Hashable {
  /// The model decides whether and which tool to call.
  case auto
  /// The model must not call tools.
  case none
  /// The model must call a tool.
  case required
  /// The model must call the named tool.
  case tool(String)

  /// Converts to the specification tool choice. Mirrors upstream `prepareToolChoice`.
  public var languageModelToolChoice: LanguageModelV4ToolChoice {
    switch self {
    case .auto: .auto
    case .none: .none
    case .required: .required
    case .tool(let name): .tool(toolName: name)
    }
  }
}

/// Token usage for a generation. Mirrors upstream `LanguageModelUsage`.
public struct LanguageModelUsage: Sendable, Equatable {
  public struct InputTokenDetails: Sendable, Hashable {
    public var noCacheTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?

    public init(noCacheTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
      self.noCacheTokens = noCacheTokens
      self.cacheReadTokens = cacheReadTokens
      self.cacheWriteTokens = cacheWriteTokens
    }
  }

  public struct OutputTokenDetails: Sendable, Hashable {
    public var textTokens: Int?
    public var reasoningTokens: Int?

    public init(textTokens: Int? = nil, reasoningTokens: Int? = nil) {
      self.textTokens = textTokens
      self.reasoningTokens = reasoningTokens
    }
  }

  public var inputTokens: Int?
  public var inputTokenDetails: InputTokenDetails
  public var outputTokens: Int?
  public var outputTokenDetails: OutputTokenDetails
  public var totalTokens: Int?
  public var raw: JSONObject?

  public init(
    inputTokens: Int? = nil,
    inputTokenDetails: InputTokenDetails = InputTokenDetails(),
    outputTokens: Int? = nil,
    outputTokenDetails: OutputTokenDetails = OutputTokenDetails(),
    totalTokens: Int? = nil,
    raw: JSONObject? = nil
  ) {
    self.inputTokens = inputTokens
    self.inputTokenDetails = inputTokenDetails
    self.outputTokens = outputTokens
    self.outputTokenDetails = outputTokenDetails
    self.totalTokens = totalTokens
    self.raw = raw
  }

  /// Converts specification usage. Mirrors upstream `asLanguageModelUsage`.
  public init(_ usage: LanguageModelV4Usage) {
    self.init(
      inputTokens: usage.inputTokens.total,
      inputTokenDetails: InputTokenDetails(
        noCacheTokens: usage.inputTokens.noCache,
        cacheReadTokens: usage.inputTokens.cacheRead,
        cacheWriteTokens: usage.inputTokens.cacheWrite),
      outputTokens: usage.outputTokens.total,
      outputTokenDetails: OutputTokenDetails(
        textTokens: usage.outputTokens.text, reasoningTokens: usage.outputTokens.reasoning),
      totalTokens: addTokenCounts(usage.inputTokens.total, usage.outputTokens.total),
      raw: usage.raw)
  }

  /// Adds two usages; `nil + nil` stays `nil`. Mirrors upstream `addLanguageModelUsage`.
  public static func + (lhs: LanguageModelUsage, rhs: LanguageModelUsage) -> LanguageModelUsage {
    LanguageModelUsage(
      inputTokens: addTokenCounts(lhs.inputTokens, rhs.inputTokens),
      inputTokenDetails: InputTokenDetails(
        noCacheTokens: addTokenCounts(lhs.inputTokenDetails.noCacheTokens, rhs.inputTokenDetails.noCacheTokens),
        cacheReadTokens: addTokenCounts(
          lhs.inputTokenDetails.cacheReadTokens, rhs.inputTokenDetails.cacheReadTokens),
        cacheWriteTokens: addTokenCounts(
          lhs.inputTokenDetails.cacheWriteTokens, rhs.inputTokenDetails.cacheWriteTokens)),
      outputTokens: addTokenCounts(lhs.outputTokens, rhs.outputTokens),
      outputTokenDetails: OutputTokenDetails(
        textTokens: addTokenCounts(lhs.outputTokenDetails.textTokens, rhs.outputTokenDetails.textTokens),
        reasoningTokens: addTokenCounts(
          lhs.outputTokenDetails.reasoningTokens, rhs.outputTokenDetails.reasoningTokens)),
      totalTokens: addTokenCounts(lhs.totalTokens, rhs.totalTokens))
  }
}

func addTokenCounts(_ lhs: Int?, _ rhs: Int?) -> Int? {
  if lhs == nil && rhs == nil { return nil }
  return (lhs ?? 0) + (rhs ?? 0)
}

/// Settings shared by every language model call. Mirrors upstream
/// `LanguageModelCallOptions` plus request options.
public struct CallSettings: Sendable, Equatable {
  /// Maximum number of tokens to generate.
  public var maxOutputTokens: Int?
  /// Temperature. Setting both `temperature` and `topP` is not recommended.
  public var temperature: Double?
  /// Nucleus sampling.
  public var topP: Double?
  /// Only sample from the top K options for each subsequent token.
  public var topK: Int?
  public var presencePenalty: Double?
  public var frequencyPenalty: Double?
  public var stopSequences: [String]?
  /// Seed for deterministic sampling, when supported.
  public var seed: Int?
  /// Reasoning effort.
  public var reasoning: LanguageModelV4ReasoningEffort?
  /// Maximum number of retries. `0` disables retries. Defaults to 2.
  public var maxRetries: Int
  /// Additional HTTP headers.
  public var headers: [String: String]?

  public init(
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    presencePenalty: Double? = nil,
    frequencyPenalty: Double? = nil,
    stopSequences: [String]? = nil,
    seed: Int? = nil,
    reasoning: LanguageModelV4ReasoningEffort? = nil,
    maxRetries: Int = 2,
    headers: [String: String]? = nil
  ) {
    self.maxOutputTokens = maxOutputTokens
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.presencePenalty = presencePenalty
    self.frequencyPenalty = frequencyPenalty
    self.stopSequences = stopSequences
    self.seed = seed
    self.reasoning = reasoning
    self.maxRetries = maxRetries
    self.headers = headers
  }

  /// Validates settings. Mirrors upstream `prepareLanguageModelCallOptions`.
  func validated() throws -> CallSettings {
    if let maxOutputTokens, maxOutputTokens < 1 {
      throw InvalidArgumentError(
        argument: "maxOutputTokens", message: "maxOutputTokens must be >= 1")
    }
    if maxRetries < 0 {
      throw InvalidArgumentError(argument: "maxRetries", message: "maxRetries must be >= 0")
    }
    return self
  }

  func callOptions(prompt: LanguageModelV4Prompt) -> LanguageModelV4CallOptions {
    LanguageModelV4CallOptions(
      prompt: prompt,
      maxOutputTokens: maxOutputTokens,
      temperature: temperature,
      stopSequences: stopSequences,
      topP: topP,
      topK: topK,
      presencePenalty: presencePenalty,
      frequencyPenalty: frequencyPenalty,
      seed: seed,
      headers: withUserAgentSuffix(headers, "ai/\(AISDK_VERSION)"),
      reasoning: reasoning)
  }
}
