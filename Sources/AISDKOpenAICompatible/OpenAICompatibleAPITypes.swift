import AISDKProviderUtils
import Foundation

/// The error body most OpenAI-compatible APIs return. Mirrors upstream `OpenAICompatibleErrorData`.
public struct OpenAICompatibleErrorData: Decodable, Sendable {
  public struct Detail: Decodable, Sendable {
    public var message: String
    public var type: String?
    public var param: JSONValue?
    public var code: JSONValue?
  }

  public var error: Detail
}

/// The default error handler for OpenAI-compatible APIs.
public let defaultOpenAICompatibleFailedResponseHandler: ResponseHandler<APICallError> =
  createJsonErrorResponseHandler(errorType: OpenAICompatibleErrorData.self, errorToMessage: { $0.error.message })

/// Token usage in the OpenAI chat format. Mirrors upstream `openaiCompatibleTokenUsageSchema`.
public struct OpenAICompatibleTokenUsage: Decodable, Sendable, Equatable {
  public struct PromptTokensDetails: Decodable, Sendable, Equatable {
    public var cached_tokens: Int?
  }

  public struct CompletionTokensDetails: Decodable, Sendable, Equatable {
    public var reasoning_tokens: Int?
    public var accepted_prediction_tokens: Int?
    public var rejected_prediction_tokens: Int?
  }

  public var prompt_tokens: Int?
  public var completion_tokens: Int?
  public var total_tokens: Int?
  public var prompt_tokens_details: PromptTokensDetails?
  public var completion_tokens_details: CompletionTokensDetails?
}

/// Mirrors upstream `convertOpenAICompatibleChatUsage`.
public func convertOpenAICompatibleChatUsage(_ usage: OpenAICompatibleTokenUsage?, raw: JSONValue?)
  -> LanguageModelV4Usage
{
  guard let usage else { return LanguageModelV4Usage() }
  let promptTokens = usage.prompt_tokens ?? 0
  let completionTokens = usage.completion_tokens ?? 0
  let cacheReadTokens = usage.prompt_tokens_details?.cached_tokens ?? 0
  let reasoningTokens = usage.completion_tokens_details?.reasoning_tokens ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(
      total: promptTokens, noCache: promptTokens - cacheReadTokens, cacheRead: cacheReadTokens, cacheWrite: nil),
    outputTokens: .init(
      total: completionTokens, text: max(0, completionTokens - reasoningTokens), reasoning: reasoningTokens),
    raw: raw?.objectValue)
}

/// Mirrors upstream `mapOpenAICompatibleFinishReason`.
public func mapOpenAICompatibleFinishReason(_ finishReason: String?) -> LanguageModelV4FinishReason.Unified {
  switch finishReason {
  case "stop": .stop
  case "length": .length
  case "content_filter": .contentFilter
  case "function_call", "tool_calls": .toolCalls
  default: .other
  }
}

/// Converts `snake_case` or `kebab-case` to `camelCase`. Mirrors upstream `toCamelCase`.
func toCamelCase(_ string: String) -> String {
  let characters = Array(string)
  var result = ""
  var index = 0
  while index < characters.count {
    let character = characters[index]
    if character == "_" || character == "-", index + 1 < characters.count,
      ("a"..."z").contains(characters[index + 1])
    {
      result += characters[index + 1].uppercased()
      index += 2
    } else {
      result.append(character)
      index += 1
    }
  }
  return result
}

/// The provider-metadata key: the camelCase name when the caller used it,
/// otherwise the raw name. Mirrors upstream `resolveProviderOptionsKey`.
func resolveProviderOptionsKey(_ rawName: String, _ providerOptions: SharedV4ProviderOptions?) -> String {
  let camelName = toCamelCase(rawName)
  if camelName != rawName, providerOptions?[camelName] != nil {
    return camelName
  }
  return rawName
}

/// Mirrors upstream `warnIfDeprecatedProviderOptionsKey`.
func warnIfDeprecatedProviderOptionsKey(
  _ rawName: String, _ providerOptions: SharedV4ProviderOptions?, warnings: inout [SharedV4Warning]
) {
  let camelName = toCamelCase(rawName)
  if camelName != rawName, providerOptions?[rawName] != nil {
    warnings.append(.deprecated(setting: "providerOptions key '\(rawName)'", message: "Use '\(camelName)' instead."))
  }
}

/// Merges the option objects stored under `keys` (later keys win) and decodes them.
func mergedProviderOptions<Options: Decodable>(
  _ keys: [String], _ providerOptions: SharedV4ProviderOptions?, as type: Options.Type
) throws -> Options? {
  var merged: [String: JSONValue] = [:]
  var found = false
  for key in keys {
    guard let options = providerOptions?[key] else { continue }
    found = true
    merged.merge(options) { _, new in new }
  }
  guard found else { return nil }
  return try parseProviderOptions(provider: "merged", providerOptions: ["merged": merged], as: Options.self)
}

/// Provider options for OpenAI-compatible chat models, passed under
/// `providerOptions["openaiCompatible"]` or the provider name.
/// Mirrors upstream `OpenAICompatibleLanguageModelChatOptions`.
public struct OpenAICompatibleChatOptions: Codable, Sendable, Equatable {
  /// An end-user identifier for abuse monitoring.
  public var user: String?
  /// Reasoning effort for reasoning models.
  public var reasoningEffort: String?
  /// Controls output verbosity.
  public var textVerbosity: String?
  /// Whether JSON schema outputs are strict. Defaults to true.
  public var strictJsonSchema: Bool?

  static let knownKeys: Set<String> = ["user", "reasoningEffort", "textVerbosity", "strictJsonSchema"]

  public init(user: String? = nil, reasoningEffort: String? = nil, textVerbosity: String? = nil, strictJsonSchema: Bool? = nil) {
    self.user = user
    self.reasoningEffort = reasoningEffort
    self.textVerbosity = textVerbosity
    self.strictJsonSchema = strictJsonSchema
  }
}

/// Provider options for OpenAI-compatible completion models.
/// Mirrors upstream `OpenAICompatibleLanguageModelCompletionOptions`.
public struct OpenAICompatibleCompletionOptions: Codable, Sendable, Equatable {
  public var echo: Bool?
  public var logitBias: [String: Double]?
  public var suffix: String?
  public var user: String?

  public init(echo: Bool? = nil, logitBias: [String: Double]? = nil, suffix: String? = nil, user: String? = nil) {
    self.echo = echo
    self.logitBias = logitBias
    self.suffix = suffix
    self.user = user
  }
}

/// Provider options for OpenAI-compatible embedding models.
/// Mirrors upstream `OpenAICompatibleEmbeddingModelOptions`.
public struct OpenAICompatibleEmbeddingOptions: Codable, Sendable, Equatable {
  /// Output dimensions, for models that support shortening.
  public var dimensions: Int?
  public var user: String?

  public init(dimensions: Int? = nil, user: String? = nil) {
    self.dimensions = dimensions
    self.user = user
  }
}

/// Extracts provider-specific metadata from responses. Mirrors upstream `MetadataExtractor`.
public protocol OpenAICompatibleMetadataExtractor: Sendable {
  /// Metadata from a complete, non-streaming response body.
  func extractMetadata(parsedBody: JSONValue) async throws -> SharedV4ProviderMetadata?
  /// A fresh extractor for one streaming response.
  func createStreamExtractor() -> any OpenAICompatibleStreamMetadataExtractor
}

/// Accumulates metadata across the chunks of one stream.
public protocol OpenAICompatibleStreamMetadataExtractor: AnyObject {
  func processChunk(_ parsedChunk: JSONValue)
  func buildMetadata() -> SharedV4ProviderMetadata?
}

struct OpenAICompatibleChatResponse: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Message: Decodable, Sendable {
      struct ToolCall: Decodable, Sendable {
        struct Function: Decodable, Sendable {
          var name: String
          var arguments: String
        }

        var id: String?
        var function: Function
        var extra_content: JSONValue?
      }

      var role: String?
      var content: JSONValue?
      var reasoning_content: String?
      var reasoning: String?
      var tool_calls: [ToolCall]?
    }

    var message: Message
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]
  var usage: OpenAICompatibleTokenUsage?
}

struct OpenAICompatibleChatChunk: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
      var role: String?
      var content: JSONValue?
      var reasoning_content: String?
      var reasoning: String?
      var tool_calls: [StreamingToolCallDelta]?
    }

    var delta: Delta?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]?
  var usage: OpenAICompatibleTokenUsage?
  var error: OpenAICompatibleErrorData.Detail?
}

/// Text and reasoning parts from a `content` field that is either a string
/// or an array of typed parts. Mirrors upstream `convertOpenAICompatibleContent`.
func convertOpenAICompatibleContent(_ content: JSONValue?) -> [LanguageModelV4Content] {
  switch content {
  case .string(let text)?:
    return text.isEmpty ? [] : [.text(LanguageModelV4Text(text: text))]
  case .array(let parts)?:
    return parts.compactMap { part -> LanguageModelV4Content? in
      switch part["type"]?.stringValue {
      case "text":
        guard let text = part["text"]?.stringValue, !text.isEmpty else { return nil }
        return .text(LanguageModelV4Text(text: text))
      case "thinking":
        let text = (part["thinking"]?.arrayValue ?? [])
          .filter { $0["type"]?.stringValue == "text" }
          .compactMap { $0["text"]?.stringValue }
          .joined()
        return text.isEmpty ? nil : .reasoning(LanguageModelV4Reasoning(text: text))
      default:
        return nil
      }
    }
  default:
    return []
  }
}

/// Response metadata, treating a `0` timestamp as missing because Azure and
/// some compatible providers send it as a placeholder. Mirrors upstream `getResponseMetadata`.
func getResponseMetadata(id: String?, model: String?, created: Double?) -> LanguageModelV4ResponseMetadata {
  createLanguageModelResponseMetadata(id: id, model: model, created: created == 0 ? nil : created)
}
