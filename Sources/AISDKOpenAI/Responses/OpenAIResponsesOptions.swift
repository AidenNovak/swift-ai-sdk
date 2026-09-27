import AISDKProviderUtils
import Foundation

/// The maximum `logprobs` count for the Responses API.
public let OPENAI_RESPONSES_TOP_LOGPROBS_MAX = 20

/// Provider options for OpenAI Responses models, passed as `providerOptions["openai"]`.
/// Mirrors upstream `OpenAILanguageModelResponsesOptions`.
public struct OpenAIResponsesOptions: Codable, Sendable, Equatable {
  public struct PromptCacheOptions: Codable, Sendable, Equatable {
    public var mode: String?
    public var ttl: String?

    public init(mode: String? = nil, ttl: String? = nil) {
      self.mode = mode
      self.ttl = ttl
    }
  }

  public struct ContextManagement: Codable, Sendable, Equatable {
    /// Always `compaction`.
    public var type: String
    public var compactThreshold: Double

    public init(type: String = "compaction", compactThreshold: Double) {
      self.type = type
      self.compactThreshold = compactThreshold
    }
  }

  public struct AllowedTools: Codable, Sendable, Equatable {
    public var toolNames: [String]
    /// `auto` or `required`.
    public var mode: String?

    public init(toolNames: [String], mode: String? = nil) {
      self.toolNames = toolNames
      self.mode = mode
    }
  }

  /// A conversation ID; cannot be combined with `previousResponseId`.
  public var conversation: String?
  public var include: [String]?
  /// Adds `web_search_call.action.sources` when a web search tool is used. Defaults to true.
  public var includeWebSearchSources: Bool?
  public var instructions: String?
  public var logprobs: OpenAILogprobs?
  public var maxToolCalls: Int?
  public var metadata: JSONValue?
  public var parallelToolCalls: Bool?
  public var previousResponseId: String?
  public var promptCacheKey: String?
  public var promptCacheOptions: PromptCacheOptions?
  public var promptCacheRetention: String?
  public var reasoningEffort: String?
  /// Changes reasoning effort mid-conversation (GPT-6 and later).
  public var reasoningEffortUpdate: String?
  /// `standard` or `pro`.
  public var reasoningMode: String?
  /// `auto`, `current_turn` or `all_turns`.
  public var reasoningContext: String?
  public var reasoningSummary: String?
  public var safetyIdentifier: String?
  public var serviceTier: String?
  /// Whether OpenAI stores the response. Defaults to true.
  public var store: Bool?
  /// Sends file types other than PDF instead of rejecting them.
  public var passThroughUnsupportedFiles: Bool?
  public var strictJsonSchema: Bool?
  public var textVerbosity: String?
  /// `auto` or `disabled`.
  public var truncation: String?
  public var user: String?
  public var systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode?
  public var forceReasoning: Bool?
  public var contextManagement: [ContextManagement]?
  /// Appends a `compaction_trigger` item to force server-side compaction.
  public var compactionTrigger: Bool?
  public var allowedTools: AllowedTools?

  public init(
    conversation: String? = nil, include: [String]? = nil, includeWebSearchSources: Bool? = nil,
    instructions: String? = nil, logprobs: OpenAILogprobs? = nil, maxToolCalls: Int? = nil, metadata: JSONValue? = nil,
    parallelToolCalls: Bool? = nil, previousResponseId: String? = nil, promptCacheKey: String? = nil,
    promptCacheOptions: PromptCacheOptions? = nil, promptCacheRetention: String? = nil, reasoningEffort: String? = nil,
    reasoningEffortUpdate: String? = nil, reasoningMode: String? = nil, reasoningContext: String? = nil,
    reasoningSummary: String? = nil, safetyIdentifier: String? = nil, serviceTier: String? = nil, store: Bool? = nil,
    passThroughUnsupportedFiles: Bool? = nil, strictJsonSchema: Bool? = nil, textVerbosity: String? = nil,
    truncation: String? = nil, user: String? = nil,
    systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode? = nil, forceReasoning: Bool? = nil,
    contextManagement: [ContextManagement]? = nil, compactionTrigger: Bool? = nil, allowedTools: AllowedTools? = nil
  ) {
    self.conversation = conversation
    self.include = include
    self.includeWebSearchSources = includeWebSearchSources
    self.instructions = instructions
    self.logprobs = logprobs
    self.maxToolCalls = maxToolCalls
    self.metadata = metadata
    self.parallelToolCalls = parallelToolCalls
    self.previousResponseId = previousResponseId
    self.promptCacheKey = promptCacheKey
    self.promptCacheOptions = promptCacheOptions
    self.promptCacheRetention = promptCacheRetention
    self.reasoningEffort = reasoningEffort
    self.reasoningEffortUpdate = reasoningEffortUpdate
    self.reasoningMode = reasoningMode
    self.reasoningContext = reasoningContext
    self.reasoningSummary = reasoningSummary
    self.safetyIdentifier = safetyIdentifier
    self.serviceTier = serviceTier
    self.store = store
    self.passThroughUnsupportedFiles = passThroughUnsupportedFiles
    self.strictJsonSchema = strictJsonSchema
    self.textVerbosity = textVerbosity
    self.truncation = truncation
    self.user = user
    self.systemMessageMode = systemMessageMode
    self.forceReasoning = forceReasoning
    self.contextManagement = contextManagement
    self.compactionTrigger = compactionTrigger
    self.allowedTools = allowedTools
  }

  func validate() throws {
    func check(_ value: String?, _ allowed: [String], _ name: String) throws {
      if let value, !allowed.contains(value) {
        throw InvalidArgumentError(argument: name, message: "invalid \(name) \(value)")
      }
    }
    for value in include ?? [] {
      try check(
        value,
        ["reasoning.encrypted_content", "file_search_call.results", "web_search_call.results", "message.output_text.logprobs"],
        "include")
    }
    if case .top(let count)? = logprobs, !(1...OPENAI_RESPONSES_TOP_LOGPROBS_MAX).contains(count) {
      throw InvalidArgumentError(argument: "logprobs", message: "logprobs must be between 1 and 20")
    }
    try check(promptCacheRetention, ["in_memory", "24h"], "promptCacheRetention")
    try check(reasoningEffortUpdate, ["none", "low", "medium", "high", "xhigh", "max"], "reasoningEffortUpdate")
    try check(reasoningMode, ["standard", "pro"], "reasoningMode")
    try check(reasoningContext, ["auto", "current_turn", "all_turns"], "reasoningContext")
    try check(serviceTier, ["auto", "flex", "priority", "fast", "ultrafast", "default"], "serviceTier")
    try check(textVerbosity, ["low", "medium", "high"], "textVerbosity")
    try check(truncation, ["auto", "disabled"], "truncation")
    if let allowedTools {
      if allowedTools.toolNames.isEmpty {
        throw InvalidArgumentError(argument: "allowedTools", message: "allowedTools.toolNames must not be empty")
      }
      try check(allowedTools.mode, ["auto", "required"], "allowedTools.mode")
    }
  }
}

/// Mirrors upstream `convertOpenAIResponsesUsage`.
func convertOpenAIResponsesUsage(_ usage: JSONValue?) -> LanguageModelV4Usage {
  guard case .object(let object)? = usage, let input = object["input_tokens"]?.intValue,
    let output = object["output_tokens"]?.intValue
  else { return LanguageModelV4Usage() }
  let cached = object["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
  let cacheWrite = object["input_tokens_details"]?["cache_write_tokens"]?.intValue
  let reasoning = object["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(total: input, noCache: input - cached - (cacheWrite ?? 0), cacheRead: cached, cacheWrite: cacheWrite),
    outputTokens: .init(total: output, text: output - reasoning, reasoning: reasoning),
    raw: object)
}

/// Mirrors upstream `mapOpenAIResponseFinishReason`.
func mapOpenAIResponseFinishReason(_ finishReason: String?, hasFunctionCall: Bool) -> LanguageModelV4FinishReason.Unified {
  switch finishReason {
  case nil: hasFunctionCall ? .toolCalls : .stop
  case "max_output_tokens": .length
  case "content_filter": .contentFilter
  default: hasFunctionCall ? .toolCalls : .other
  }
}
