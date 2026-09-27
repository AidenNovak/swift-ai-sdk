import AISDKProviderUtils
import Foundation

/// Provider options for FIM completion, passed as `providerOptions["deepseek"]`.
public struct DeepSeekCompletionOptions: Codable, Sendable, Equatable {
  /// Text after the completion; the model fills in the middle.
  public var suffix: String?
  /// Echo the prompt before the completion. Cannot be combined with `suffix` or `logprobs`.
  public var echo: Bool?
  /// Number of most likely tokens (0-20) to return log probabilities for.
  public var logprobs: Int?

  public init(suffix: String? = nil, echo: Bool? = nil, logprobs: Int? = nil) {
    self.suffix = suffix
    self.echo = echo
    self.logprobs = logprobs
  }
}

struct DeepSeekCompletionResponse: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    var text: String?
    var index: Int?
    var logprobs: JSONValue?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var system_fingerprint: String?
  var choices: [Choice]?
  var usage: DeepSeekTokenUsage?
  var error: DeepSeekErrorDetail?
}

/// DeepSeek FIM (fill-in-the-middle) completion, served from the beta API.
///
/// The prompt is the text before the gap; pass the text after it as
/// `providerOptions["deepseek"]["suffix"]`. FIM output is limited to 4K tokens.
public struct DeepSeekCompletionLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: DeepSeekChatConfig

  public init(modelId: String, config: DeepSeekChatConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { "deepseek.completion" }

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message })
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    let completionOptions =
      try parseProviderOptions(provider: "deepseek", providerOptions: options.providerOptions, as: DeepSeekCompletionOptions.self)
      ?? DeepSeekCompletionOptions()
    if let logprobs = completionOptions.logprobs, !(0...20).contains(logprobs) {
      throw InvalidArgumentError(argument: "logprobs", message: "logprobs must be between 0 and 20")
    }

    var warnings: [SharedV4Warning] = []
    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.seed != nil { warnings.append(.unsupported(feature: "seed")) }
    if options.frequencyPenalty != nil { warnings.append(.unsupported(feature: "frequencyPenalty")) }
    if options.presencePenalty != nil { warnings.append(.unsupported(feature: "presencePenalty")) }
    if options.tools?.isEmpty == false { warnings.append(.unsupported(feature: "tools")) }
    if options.toolChoice != nil { warnings.append(.unsupported(feature: "toolChoice")) }
    if options.responseFormat != nil, options.responseFormat != .text {
      warnings.append(.unsupported(feature: "responseFormat", details: "JSON output is not supported by FIM completion."))
    }
    if isCustomReasoning(options.reasoning) { warnings.append(.unsupported(feature: "reasoning")) }

    let args = jsonObject([
      "model": .string(modelId),
      "prompt": .string(try convertToCompletionPrompt(options.prompt)),
      "suffix": .optional(completionOptions.suffix),
      "echo": .optional(completionOptions.echo),
      "logprobs": .optional(completionOptions.logprobs),
      "max_tokens": .optional(options.maxOutputTokens),
      "temperature": .optional(options.temperature),
      "top_p": .optional(options.topP),
      "stop": .optional(options.stopSequences),
    ])
    return (args.objectValue ?? [:], warnings)
  }

  private var completionsURL: String {
    let base = config.url("")
    return base.hasSuffix("/beta") ? "\(base)/completions" : "\(base)/beta/completions"
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: completionsURL,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(args),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekCompletionResponse.self),
      httpClient: config.httpClient)

    let body = response.value
    guard let choice = body.choices?.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }
    let text = choice.text ?? ""

    return LanguageModelV4GenerateResult(
      content: text.isEmpty ? [] : [.text(LanguageModelV4Text(text: text))],
      finishReason: LanguageModelV4FinishReason(
        unified: mapDeepSeekFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertDeepSeekUsage(body.usage, raw: response.rawValue?["usage"]),
      providerMetadata: [
        "deepseek": jsonObject([
          "promptCacheHitTokens": .optional(body.usage?.prompt_cache_hit_tokens),
          "promptCacheMissTokens": .optional(body.usage?.prompt_cache_miss_tokens),
          "logprobs": choice.logprobs.flatMap { $0.isNull ? nil : $0 },
          "systemFingerprint": .optional(body.system_fingerprint),
        ]).objectValue ?? [:]
      ],
      request: LanguageModelV4RequestInfo(body: .object(args)),
      response: LanguageModelV4ResponseInfo(
        metadata: createLanguageModelResponseMetadata(id: body.id, model: body.model, created: body.created),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings) = try getArgs(options)
    var body = args
    body["stream"] = true
    body["stream_options"] = ["include_usage": true]

    let response = try await postJsonToApi(
      url: completionsURL,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(DeepSeekCompletionResponse.self),
      httpClient: config.httpClient)

    let chunks = response.value
    let includeRawChunks = options.includeRawChunks == true
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      continuation.yield(.streamStart(warnings: warnings))
      var isFirstChunk = true
      var isTextActive = false
      var finishReason = LanguageModelV4FinishReason(unified: .other)
      var usage: DeepSeekTokenUsage?
      var rawUsage: JSONValue?
      do {
        for try await chunk in chunks {
          if includeRawChunks { continuation.yield(.raw(rawValue: chunk.rawValue ?? .null)) }
          guard case .success(let value, let raw) = chunk else {
            finishReason = LanguageModelV4FinishReason(unified: .error)
            continuation.yield(.error(chunk.error ?? NoContentGeneratedError()))
            continue
          }
          if let error = value.error {
            finishReason = LanguageModelV4FinishReason(unified: .error)
            continuation.yield(.error(createDeepSeekStreamError(error, data: raw)))
            continue
          }
          if isFirstChunk {
            isFirstChunk = false
            continuation.yield(
              .responseMetadata(createLanguageModelResponseMetadata(id: value.id, model: value.model, created: value.created)))
          }
          if let chunkUsage = value.usage {
            usage = chunkUsage
            rawUsage = raw["usage"]
          }
          guard let choice = value.choices?.first else { continue }
          if let reason = choice.finish_reason {
            finishReason = LanguageModelV4FinishReason(unified: mapDeepSeekFinishReason(reason), raw: reason)
          }
          if let text = choice.text, !text.isEmpty {
            if !isTextActive {
              continuation.yield(.textStart(id: "0"))
              isTextActive = true
            }
            continuation.yield(.textDelta(id: "0", delta: text))
          }
        }
        if isTextActive { continuation.yield(.textEnd(id: "0")) }
        continuation.yield(.finish(usage: convertDeepSeekUsage(usage, raw: rawUsage), finishReason: finishReason))
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }

    return LanguageModelV4StreamResult(
      stream: stream, request: LanguageModelV4RequestInfo(body: .object(body)), responseHeaders: response.responseHeaders)
  }
}

/// Converts a prompt to plain completion text. A lone user message is sent
/// verbatim; conversations are rendered with `user:` / `assistant:` labels.
/// Mirrors upstream `convertToCompletionPrompt`.
func convertToCompletionPrompt(_ prompt: LanguageModelV4Prompt) throws -> String {
  var system: [String] = []
  var turns: [(role: String, text: String)] = []
  for message in prompt {
    switch message {
    case .system(let text, _):
      system.append(text)
    case .user(let parts, _):
      let text = try parts.map { part -> String in
        guard case .text(let textPart) = part else {
          throw UnsupportedFunctionalityError(functionality: "file parts in completion prompts")
        }
        return textPart.text
      }.joined()
      turns.append(("user", text))
    case .assistant(let parts, _):
      let text = try parts.compactMap { part -> String? in
        switch part {
        case .text(let textPart): return textPart.text
        case .reasoning: return nil
        default: throw UnsupportedFunctionalityError(functionality: "tool calls in completion prompts")
        }
      }.joined()
      turns.append(("assistant", text))
    case .tool:
      throw UnsupportedFunctionalityError(functionality: "tool messages in completion prompts")
    }
  }

  let prefix = system.isEmpty ? "" : system.joined(separator: "\n\n") + "\n\n"
  if turns.count == 1, turns[0].role == "user" {
    return prefix + turns[0].text
  }
  let conversation = turns.map { "\($0.role):\n\($0.text)" }.joined(separator: "\n\n")
  return prefix + conversation + "\n\nassistant:\n"
}
