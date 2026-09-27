import AISDKProviderUtils
import Foundation

/// Anthropic usage. Mirrors upstream `AnthropicUsage`.
struct AnthropicUsage: Decodable, Sendable {
  struct Iteration: Decodable, Sendable {
    var type: String
    var model: String?
    var input_tokens: Int
    var output_tokens: Int
    var cache_creation_input_tokens: Int?
    var cache_read_input_tokens: Int?
  }

  struct OutputTokensDetails: Decodable, Sendable {
    var thinking_tokens: Int?
  }

  var input_tokens: Int?
  var output_tokens: Int?
  var output_tokens_details: OutputTokensDetails?
  var cache_creation_input_tokens: Int?
  var cache_read_input_tokens: Int?
  var iterations: [Iteration]?
}

struct AnthropicErrorData: Decodable, Sendable {
  struct Detail: Decodable, Sendable {
    var type: String
    var message: String
  }

  var type: String
  var error: Detail
}

/// A content block in a Messages API response or `content_block_start` event.
struct AnthropicContentBlock: Decodable, Sendable {
  var type: String
  var text: String?
  var citations: [JSONValue]?
  var thinking: String?
  var signature: String?
  var data: String?
  var id: String?
  var name: String?
  var input: JSONValue?
  var content: JSONValue?
  var tool_use_id: String?
  var file_id: String?
}

struct AnthropicMessagesResponse: Decodable, Sendable {
  var id: String?
  var model: String?
  var content: [AnthropicContentBlock]
  var stop_reason: String?
  var stop_sequence: String?
  var usage: AnthropicUsage
}

/// A streaming event. Only the fields used by the SDK are decoded.
struct AnthropicStreamEvent: Decodable, Sendable {
  struct Message: Decodable, Sendable {
    var id: String?
    var model: String?
    var stop_reason: String?
    var usage: AnthropicUsage?
    var content: [AnthropicContentBlock]?
  }

  struct Delta: Decodable, Sendable {
    var type: String?
    var text: String?
    var thinking: String?
    var signature: String?
    var partial_json: String?
    var citation: JSONValue?
    var stop_reason: String?
    var stop_sequence: String?
    var content: String?
  }

  struct ErrorDetail: Decodable, Sendable {
    var type: String
    var message: String
  }

  var type: String
  var index: Int?
  var message: Message?
  var content_block: AnthropicContentBlock?
  var delta: Delta?
  var usage: AnthropicUsage?
  var error: ErrorDetail?
}

/// Model capabilities. Mirrors upstream `getModelCapabilities`.
struct AnthropicModelCapabilities: Sendable {
  var maxOutputTokens: Int
  var supportsStructuredOutput: Bool
  var supportsAdaptiveThinking: Bool
  var rejectsSamplingParameters: Bool
  var supportsXhighEffort: Bool
  var rejectsThinkingDisabledAboveHighEffort: Bool
  var rejectsThinkingDisabled: Bool
  var rejectsForcedToolUse: Bool
  var isKnownModel: Bool

  static func forModel(_ modelId: String) -> AnthropicModelCapabilities {
    func caps(
      _ maxOutputTokens: Int, structured: Bool, adaptive: Bool, rejectsSampling: Bool, xhigh: Bool,
      rejectsDisabledAboveHigh: Bool = false, rejectsDisabled: Bool = false, rejectsForced: Bool = false,
      known: Bool = true
    ) -> AnthropicModelCapabilities {
      AnthropicModelCapabilities(
        maxOutputTokens: maxOutputTokens, supportsStructuredOutput: structured, supportsAdaptiveThinking: adaptive,
        rejectsSamplingParameters: rejectsSampling, supportsXhighEffort: xhigh,
        rejectsThinkingDisabledAboveHighEffort: rejectsDisabledAboveHigh, rejectsThinkingDisabled: rejectsDisabled,
        rejectsForcedToolUse: rejectsForced, isKnownModel: known)
    }
    func matches(_ pattern: String) -> Bool { modelId.range(of: pattern, options: .regularExpression) != nil }

    if modelId.contains("claude-opus-5-5") {
      return caps(
        128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true, rejectsDisabledAboveHigh: true,
        rejectsDisabled: true, rejectsForced: true)
    } else if modelId.contains("claude-opus-5") {
      return caps(
        128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true, rejectsDisabledAboveHigh: true)
    } else if modelId.contains("claude-fable-5-1") {
      return caps(
        128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true, rejectsDisabled: true,
        rejectsForced: true)
    } else if modelId.contains("claude-fable-5") {
      return caps(128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true, rejectsDisabled: true)
    } else if modelId.contains("claude-opus-4-8") || modelId.contains("claude-opus-4-7")
      || modelId.contains("claude-sonnet-5")
    {
      return caps(128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true)
    } else if modelId.contains("claude-sonnet-4-6") || modelId.contains("claude-opus-4-6") {
      return caps(128_000, structured: true, adaptive: true, rejectsSampling: false, xhigh: false)
    } else if modelId.contains("claude-sonnet-4-5") || modelId.contains("claude-opus-4-5")
      || modelId.contains("claude-haiku-4-5")
    {
      return caps(64_000, structured: true, adaptive: false, rejectsSampling: false, xhigh: false)
    } else if modelId.contains("claude-opus-4-1") {
      return caps(32_000, structured: true, adaptive: false, rejectsSampling: false, xhigh: false)
    } else if matches("claude-sonnet-4(?:-|@)") {
      return caps(64_000, structured: false, adaptive: false, rejectsSampling: false, xhigh: false)
    } else if matches("claude-opus-4(?:-|@)") {
      return caps(32_000, structured: false, adaptive: false, rejectsSampling: false, xhigh: false)
    } else if modelId.contains("claude-3-haiku") {
      return caps(4096, structured: false, adaptive: false, rejectsSampling: false, xhigh: false)
    } else if matches("claude-(?:instant(?:-|$)|v?2(?=$|[-.:])|3(?=$|[-.]))") {
      return caps(4096, structured: false, adaptive: false, rejectsSampling: false, xhigh: false, known: false)
    } else if modelId.contains("claude-") {
      return caps(
        128_000, structured: true, adaptive: true, rejectsSampling: true, xhigh: true, rejectsDisabledAboveHigh: true,
        known: false)
    }
    return caps(4096, structured: false, adaptive: false, rejectsSampling: false, xhigh: false, known: false)
  }
}

/// Mirrors upstream `mapAnthropicStopReason`.
func mapAnthropicStopReason(_ stopReason: String?, isJsonResponseFromTool: Bool) -> LanguageModelV4FinishReason.Unified {
  switch stopReason {
  case "pause_turn", "end_turn", "stop_sequence": .stop
  case "refusal": .contentFilter
  case "tool_use": isJsonResponseFromTool ? .stop : .toolCalls
  case "max_tokens", "model_context_window_exceeded": .length
  default: .other
  }
}

/// Mirrors upstream `convertAnthropicUsage`.
func convertAnthropicUsage(_ usage: AnthropicUsage, raw: JSONObject?) -> LanguageModelV4Usage {
  let cacheCreation = usage.cache_creation_input_tokens ?? 0
  let cacheRead = usage.cache_read_input_tokens ?? 0
  let reasoningTokens = usage.output_tokens_details?.thinking_tokens

  var inputTokens = usage.input_tokens ?? 0
  var outputTokens = usage.output_tokens ?? 0
  let servedByFallback = usage.iterations?.contains { $0.type == "fallback_message" } ?? false
  if let iterations = usage.iterations, !iterations.isEmpty, !servedByFallback {
    let executor = iterations.filter { $0.type == "compaction" || $0.type == "message" }
    if !executor.isEmpty {
      inputTokens = executor.reduce(0) { $0 + $1.input_tokens }
      outputTokens = executor.reduce(0) { $0 + $1.output_tokens }
    }
  }

  return LanguageModelV4Usage(
    inputTokens: .init(
      total: inputTokens + cacheCreation + cacheRead, noCache: inputTokens, cacheRead: cacheRead,
      cacheWrite: cacheCreation),
    outputTokens: .init(
      total: outputTokens, text: reasoningTokens.map { outputTokens - $0 }, reasoning: reasoningTokens),
    raw: raw)
}

/// Classifies stream errors. Mirrors upstream `createAnthropicStreamError`.
func createAnthropicStreamError(type: String, message: String, data: JSONValue?) -> ProviderStreamError {
  let (statusCode, isRetryable): (Int?, Bool?) =
    switch type {
    case "api_error": (500, true)
    case "overloaded_error": (529, true)
    case "rate_limit_error": (429, true)
    case "request_too_large": (413, false)
    case "authentication_error": (401, false)
    case "permission_error": (403, false)
    case "not_found_error": (404, false)
    case "billing_error", "invalid_request_error": (400, false)
    default: (nil, nil)
    }
  return ProviderStreamError(
    message: message, type: type, statusCode: statusCode, isRetryable: isRetryable, data: data)
}

/// Provider options for Anthropic models, passed as `providerOptions["anthropic"]`.
/// Mirrors the commonly used subset of upstream `AnthropicLanguageModelOptions`.
public struct AnthropicOptions: Codable, Sendable, Equatable {
  public struct Thinking: Codable, Sendable, Equatable {
    /// `enabled`, `adaptive` or `disabled`.
    public var type: String?
    /// Token budget for `enabled` thinking.
    public var budgetTokens: Int?
    /// `summarized`, `omitted` or `updates` for adaptive thinking.
    public var display: String?

    public init(type: String? = nil, budgetTokens: Int? = nil, display: String? = nil) {
      self.type = type
      self.budgetTokens = budgetTokens
      self.display = display
    }
  }

  public struct Metadata: Codable, Sendable, Equatable {
    public var userId: String?

    public init(userId: String? = nil) {
      self.userId = userId
    }
  }

  /// Whether reasoning from earlier turns is sent back. Defaults to true.
  public var sendReasoning: Bool?
  public var thinking: Thinking?
  /// `low`, `medium`, `high`, `xhigh` or `max`.
  public var effort: String?
  public var disableParallelToolUse: Bool?
  /// Top-level cache control, e.g. `{"type": "ephemeral"}`.
  public var cacheControl: JSONValue?
  public var metadata: Metadata?
  /// `auto`, `outputFormat` or `jsonTool`.
  public var structuredOutputMode: String?
  /// Additional `anthropic-beta` values.
  public var anthropicBeta: [String]?
  /// Whether tool input is streamed eagerly. Defaults to true when streaming.
  public var toolStreaming: Bool?
  public var serviceTier: String?

  public init(
    sendReasoning: Bool? = nil,
    thinking: Thinking? = nil,
    effort: String? = nil,
    disableParallelToolUse: Bool? = nil,
    cacheControl: JSONValue? = nil,
    metadata: Metadata? = nil,
    structuredOutputMode: String? = nil,
    anthropicBeta: [String]? = nil,
    toolStreaming: Bool? = nil,
    serviceTier: String? = nil
  ) {
    self.sendReasoning = sendReasoning
    self.thinking = thinking
    self.effort = effort
    self.disableParallelToolUse = disableParallelToolUse
    self.cacheControl = cacheControl
    self.metadata = metadata
    self.structuredOutputMode = structuredOutputMode
    self.anthropicBeta = anthropicBeta
    self.toolStreaming = toolStreaming
    self.serviceTier = serviceTier
  }

  func merging(_ other: AnthropicOptions?) -> AnthropicOptions {
    guard let other else { return self }
    var merged = self
    merged.sendReasoning = other.sendReasoning ?? sendReasoning
    merged.thinking = other.thinking ?? thinking
    merged.effort = other.effort ?? effort
    merged.disableParallelToolUse = other.disableParallelToolUse ?? disableParallelToolUse
    merged.cacheControl = other.cacheControl ?? cacheControl
    merged.metadata = other.metadata ?? metadata
    merged.structuredOutputMode = other.structuredOutputMode ?? structuredOutputMode
    merged.anthropicBeta = other.anthropicBeta ?? anthropicBeta
    merged.toolStreaming = other.toolStreaming ?? toolStreaming
    merged.serviceTier = other.serviceTier ?? serviceTier
    return merged
  }
}

/// Reasoning metadata attached to reasoning parts. Mirrors upstream `AnthropicReasoningMetadata`.
struct AnthropicReasoningMetadata: Decodable, Sendable {
  var signature: String?
  var redactedData: String?
}

/// Per-file-part options. Mirrors upstream `anthropicFilePartProviderOptions`.
struct AnthropicFilePartOptions: Decodable, Sendable {
  struct Citations: Decodable, Sendable {
    var enabled: Bool?
  }

  var citations: Citations?
  var title: String?
  var context: String?
}
