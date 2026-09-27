import AISDKProviderUtils
import Foundation

struct DeepSeekTokenUsage: Decodable, Sendable {
  struct CompletionTokensDetails: Decodable, Sendable {
    var reasoning_tokens: Int?
  }

  var prompt_tokens: Int?
  var completion_tokens: Int?
  var prompt_cache_hit_tokens: Int?
  var prompt_cache_miss_tokens: Int?
  var total_tokens: Int?
  var completion_tokens_details: CompletionTokensDetails?
}

struct DeepSeekErrorDetail: Decodable, Sendable {
  var message: String
  var type: String?
  var code: JSONValue?
}

struct DeepSeekErrorData: Decodable, Sendable {
  var error: DeepSeekErrorDetail
}

struct DeepSeekChatResponse: Decodable, Sendable {
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

      var role: String?
      var content: String?
      var reasoning_content: String?
      var tool_calls: [ToolCall]?
    }

    var index: Int?
    var message: Message
    var logprobs: JSONValue?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var object: String?
  var system_fingerprint: String?
  var choices: [Choice]
  var usage: DeepSeekTokenUsage?
}

/// A streamed chunk, or an error envelope sent inside the stream.
struct DeepSeekChatChunk: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
      var role: String?
      var content: String?
      var reasoning_content: String?
      var tool_calls: [StreamingToolCallDelta]?
    }

    struct Logprobs: Decodable, Sendable {
      var content: [JSONValue]?
      var reasoning_content: [JSONValue]?
    }

    var index: Int?
    var delta: Delta?
    var logprobs: Logprobs?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var object: String?
  var system_fingerprint: String?
  var choices: [Choice]?
  var usage: DeepSeekTokenUsage?
  var error: DeepSeekErrorDetail?
}

/// Provider options for DeepSeek chat models, passed as `providerOptions["deepseek"]`.
/// Mirrors upstream `DeepSeekLanguageModelChatOptions`.
public struct DeepSeekChatOptions: Codable, Sendable, Equatable {
  public struct Thinking: Codable, Sendable, Equatable {
    /// `enabled` or `disabled`. `adaptive` is accepted and mapped to `enabled`.
    public var type: String?

    public init(type: String? = nil) {
      self.type = type
    }
  }

  /// Return log probabilities of the output tokens.
  public var logprobs: Bool?
  /// Number of most likely tokens (0-20) to return at each position.
  public var topLogprobs: Int?
  /// An end-user identifier, matching `^[a-zA-Z0-9_-]+$`.
  public var userId: String?
  public var thinking: Thinking?
  /// `low`, `high` or `max`. `medium` and `xhigh` are mapped with a warning.
  public var reasoningEffort: String?
  /// Whether JSON schema outputs are strict. Defaults to true.
  public var strictJsonSchema: Bool?

  public init(
    logprobs: Bool? = nil,
    topLogprobs: Int? = nil,
    userId: String? = nil,
    thinking: Thinking? = nil,
    reasoningEffort: String? = nil,
    strictJsonSchema: Bool? = nil
  ) {
    self.logprobs = logprobs
    self.topLogprobs = topLogprobs
    self.userId = userId
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
    self.strictJsonSchema = strictJsonSchema
  }

  func validate() throws {
    if let topLogprobs, !(0...20).contains(topLogprobs) {
      throw InvalidArgumentError(argument: "topLogprobs", message: "topLogprobs must be between 0 and 20")
    }
    if let userId {
      let valid = userId.count <= 512 && !userId.isEmpty
        && userId.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        && userId.allSatisfy(\.isASCII)
      if !valid {
        throw InvalidArgumentError(argument: "userId", message: "userId must match /^[a-zA-Z0-9_-]+$/")
      }
    }
    if let type = thinking?.type, !["adaptive", "enabled", "disabled"].contains(type) {
      throw InvalidArgumentError(argument: "thinking.type", message: "invalid thinking type \(type)")
    }
    if let reasoningEffort, !["low", "medium", "high", "xhigh", "max"].contains(reasoningEffort) {
      throw InvalidArgumentError(argument: "reasoningEffort", message: "invalid reasoningEffort \(reasoningEffort)")
    }
  }
}

/// Per-message provider options. Mirrors upstream `DeepSeekAssistantMessageProviderOptions`.
struct DeepSeekMessageOptions: Decodable, Sendable {
  var name: String?
  var prefix: Bool?
}

/// Per-file-part provider options. Mirrors upstream `DeepSeekFilePartProviderOptions`.
struct DeepSeekFilePartOptions: Decodable, Sendable {
  var imageDetail: String?
  var fileData: Bool?
}

/// Whether the model is a DeepSeek V4 model. Mirrors upstream `isDeepSeekV4Model`.
func isDeepSeekV4Model(_ modelId: String) -> Bool {
  modelId.contains("deepseek-v4") || modelId.hasPrefix("deepseek-flash") || modelId.hasPrefix("deepseek-pro")
}

/// Mirrors upstream `mapDeepSeekFinishReason`.
func mapDeepSeekFinishReason(_ finishReason: String?) -> LanguageModelV4FinishReason.Unified {
  switch finishReason {
  case "stop": .stop
  case "length": .length
  case "content_filter": .contentFilter
  case "tool_calls": .toolCalls
  case "insufficient_system_resource": .error
  default: .other
  }
}

/// Mirrors upstream `convertDeepSeekUsage`.
func convertDeepSeekUsage(_ usage: DeepSeekTokenUsage?, raw: JSONValue?) -> LanguageModelV4Usage {
  guard let usage else { return LanguageModelV4Usage() }
  let promptTokens = usage.prompt_tokens ?? 0
  let completionTokens = usage.completion_tokens ?? 0
  let cacheReadTokens = usage.prompt_cache_hit_tokens ?? 0
  let reasoningTokens = usage.completion_tokens_details?.reasoning_tokens ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(
      total: promptTokens, noCache: promptTokens - cacheReadTokens, cacheRead: cacheReadTokens, cacheWrite: nil),
    outputTokens: .init(
      total: completionTokens, text: max(0, completionTokens - reasoningTokens), reasoning: reasoningTokens),
    raw: raw?.objectValue)
}
