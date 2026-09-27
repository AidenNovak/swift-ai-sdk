import AISDKProviderUtils
import Foundation

/// Mirrors upstream `OpenAIChatUsage`.
struct OpenAIChatUsage: Decodable, Sendable {
  struct PromptTokensDetails: Decodable, Sendable {
    var cached_tokens: Int?
    var cache_write_tokens: Int?
  }

  struct CompletionTokensDetails: Decodable, Sendable {
    var reasoning_tokens: Int?
    var accepted_prediction_tokens: Int?
    var rejected_prediction_tokens: Int?
  }

  var prompt_tokens: Int?
  var completion_tokens: Int?
  var total_tokens: Int?
  var prompt_tokens_details: PromptTokensDetails?
  var completion_tokens_details: CompletionTokensDetails?
}

/// Mirrors upstream `convertOpenAIChatUsage`.
func convertOpenAIChatUsage(_ usage: OpenAIChatUsage?, raw: JSONValue?) -> LanguageModelV4Usage {
  guard let usage else { return LanguageModelV4Usage() }
  let promptTokens = usage.prompt_tokens ?? 0
  let completionTokens = usage.completion_tokens ?? 0
  let cachedTokens = usage.prompt_tokens_details?.cached_tokens ?? 0
  let cacheWriteTokens = usage.prompt_tokens_details?.cache_write_tokens
  let reasoningTokens = usage.completion_tokens_details?.reasoning_tokens ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(
      total: promptTokens, noCache: promptTokens - cachedTokens - (cacheWriteTokens ?? 0), cacheRead: cachedTokens,
      cacheWrite: cacheWriteTokens),
    outputTokens: .init(
      total: completionTokens, text: max(0, completionTokens - reasoningTokens), reasoning: reasoningTokens),
    raw: raw?.objectValue)
}

/// Mirrors upstream `mapOpenAIFinishReason`.
func mapOpenAIFinishReason(_ finishReason: String?) -> LanguageModelV4FinishReason.Unified {
  switch finishReason {
  case "stop": .stop
  case "length": .length
  case "content_filter": .contentFilter
  case "function_call", "tool_calls": .toolCalls
  default: .other
  }
}

struct OpenAIURLCitation: Decodable, Sendable {
  struct Citation: Decodable, Sendable {
    var url: String
    var title: String?
  }

  var type: String?
  var url_citation: Citation
}

struct OpenAIChatLogprobs: Decodable, Sendable {
  var content: JSONValue?
}

struct OpenAIChatResponse: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Message: Decodable, Sendable {
      struct ToolCall: Decodable, Sendable {
        struct Function: Decodable, Sendable {
          var name: String
          var arguments: String
        }

        var id: String?
        var type: String?
        var function: Function
      }

      struct Audio: Decodable, Sendable {
        var transcript: String?
      }

      var role: String?
      var content: String?
      var tool_calls: [ToolCall]?
      var annotations: [OpenAIURLCitation]?
      var audio: Audio?
    }

    var index: Int?
    var message: Message
    var logprobs: OpenAIChatLogprobs?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]
  var usage: OpenAIChatUsage?
}

struct OpenAIChatChunk: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
      var role: String?
      var content: String?
      var tool_calls: [StreamingToolCallDelta]?
      var annotations: [OpenAIURLCitation]?
    }

    var index: Int?
    var delta: Delta?
    var logprobs: OpenAIChatLogprobs?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]?
  var usage: OpenAIChatUsage?
  var error: JSONValue?

  var isOutput: Bool {
    guard error == nil else { return false }
    return (choices ?? []).contains { choice in
      guard let delta = choice.delta else { return false }
      return !(delta.content ?? "").isEmpty || !(delta.tool_calls ?? []).isEmpty || !(delta.annotations ?? []).isEmpty
    }
  }
}

/// Either a boolean or a top-N count for `logprobs`.
public enum OpenAILogprobs: Codable, Sendable, Equatable {
  case enabled(Bool)
  case top(Int)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .enabled(value)
    } else {
      self = .top(try container.decode(Int.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .enabled(let value): try container.encode(value)
    case .top(let value): try container.encode(value)
    }
  }
}

/// Provider options for OpenAI chat models, passed as `providerOptions["openai"]`.
/// Mirrors upstream `OpenAILanguageModelChatOptions`.
public struct OpenAIChatOptions: Codable, Sendable, Equatable {
  public struct PromptCacheOptions: Codable, Sendable, Equatable {
    /// `implicit` or `explicit`.
    public var mode: String?
    /// Currently only `30m`.
    public var ttl: String?

    public init(mode: String? = nil, ttl: String? = nil) {
      self.mode = mode
      self.ttl = ttl
    }
  }

  public var logitBias: [String: Double]?
  public var logprobs: OpenAILogprobs?
  public var parallelToolCalls: Bool?
  public var user: String?
  /// `none`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max`.
  public var reasoningEffort: String?
  public var maxCompletionTokens: Int?
  public var store: Bool?
  public var metadata: [String: String]?
  public var prediction: JSONValue?
  /// `auto`, `flex`, `priority`, `fast`, `ultrafast` or `default`.
  public var serviceTier: String?
  public var strictJsonSchema: Bool?
  /// `low`, `medium` or `high`.
  public var textVerbosity: String?
  public var promptCacheKey: String?
  public var promptCacheOptions: PromptCacheOptions?
  /// `in_memory` or `24h`. Deprecated for GPT-5.6 and later.
  public var promptCacheRetention: String?
  public var safetyIdentifier: String?
  public var systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode?
  /// Treats an unrecognized model ID as a reasoning model.
  public var forceReasoning: Bool?

  public init(
    logitBias: [String: Double]? = nil, logprobs: OpenAILogprobs? = nil, parallelToolCalls: Bool? = nil,
    user: String? = nil, reasoningEffort: String? = nil, maxCompletionTokens: Int? = nil, store: Bool? = nil,
    metadata: [String: String]? = nil, prediction: JSONValue? = nil, serviceTier: String? = nil,
    strictJsonSchema: Bool? = nil, textVerbosity: String? = nil, promptCacheKey: String? = nil,
    promptCacheOptions: PromptCacheOptions? = nil, promptCacheRetention: String? = nil,
    safetyIdentifier: String? = nil, systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode? = nil,
    forceReasoning: Bool? = nil
  ) {
    self.logitBias = logitBias
    self.logprobs = logprobs
    self.parallelToolCalls = parallelToolCalls
    self.user = user
    self.reasoningEffort = reasoningEffort
    self.maxCompletionTokens = maxCompletionTokens
    self.store = store
    self.metadata = metadata
    self.prediction = prediction
    self.serviceTier = serviceTier
    self.strictJsonSchema = strictJsonSchema
    self.textVerbosity = textVerbosity
    self.promptCacheKey = promptCacheKey
    self.promptCacheOptions = promptCacheOptions
    self.promptCacheRetention = promptCacheRetention
    self.safetyIdentifier = safetyIdentifier
    self.systemMessageMode = systemMessageMode
    self.forceReasoning = forceReasoning
  }

  func validate() throws {
    if let reasoningEffort, !["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(reasoningEffort) {
      throw InvalidArgumentError(argument: "reasoningEffort", message: "invalid reasoningEffort \(reasoningEffort)")
    }
    if let serviceTier, !["auto", "flex", "priority", "fast", "ultrafast", "default"].contains(serviceTier) {
      throw InvalidArgumentError(argument: "serviceTier", message: "invalid serviceTier \(serviceTier)")
    }
    if let textVerbosity, !["low", "medium", "high"].contains(textVerbosity) {
      throw InvalidArgumentError(argument: "textVerbosity", message: "invalid textVerbosity \(textVerbosity)")
    }
    for (key, value) in metadata ?? [:] where key.count > 64 || value.count > 512 {
      throw InvalidArgumentError(argument: "metadata", message: "metadata keys are limited to 64 and values to 512 characters")
    }
  }
}

/// Response metadata, treating a `0` timestamp as missing because Azure and
/// some compatible providers send it as a placeholder. Mirrors upstream `getResponseMetadata`.
func getResponseMetadata(id: String?, model: String?, created: Double?) -> LanguageModelV4ResponseMetadata {
  createLanguageModelResponseMetadata(id: id, model: model, created: created == 0 ? nil : created)
}
