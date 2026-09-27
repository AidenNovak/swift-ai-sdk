import AISDKProviderUtils
import Foundation

struct OpenAICompatibleCompletionUsage: Decodable, Sendable {
  var prompt_tokens: Int?
  var completion_tokens: Int?
  var total_tokens: Int?
}

struct OpenAICompatibleCompletionResponse: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    var text: String?
    var finish_reason: String?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]?
  var usage: OpenAICompatibleCompletionUsage?
  var error: OpenAICompatibleErrorData.Detail?
}

/// Mirrors upstream `convertOpenAICompatibleCompletionUsage`.
func convertOpenAICompatibleCompletionUsage(_ usage: OpenAICompatibleCompletionUsage?, raw: JSONValue?)
  -> LanguageModelV4Usage
{
  guard let usage else { return LanguageModelV4Usage() }
  let promptTokens = usage.prompt_tokens ?? 0
  let completionTokens = usage.completion_tokens ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(total: promptTokens, noCache: promptTokens),
    outputTokens: .init(total: completionTokens, text: completionTokens),
    raw: raw?.objectValue)
}

/// Renders a chat prompt as `user:` / `assistant:` text and returns the
/// stop sequence that ends the assistant turn.
/// Mirrors upstream `convertToOpenAICompatibleCompletionPrompt`.
func convertToOpenAICompatibleCompletionPrompt(
  _ prompt: LanguageModelV4Prompt, user: String = "user", assistant: String = "assistant"
) throws -> (prompt: String, stopSequences: [String]) {
  var messages = prompt[...]
  var text = ""
  if case .system(let content, _)? = messages.first {
    text += "\(content)\n\n"
    messages = messages.dropFirst()
  }

  for message in messages {
    switch message {
    case .system(let content, _):
      throw InvalidPromptError(prompt: content, message: "Unexpected system message in prompt: \(content)")
    case .user(let parts, _):
      let userMessage = parts.compactMap { part -> String? in
        if case .text(let textPart) = part { return textPart.text }
        return nil
      }.joined()
      text += "\(user):\n\(userMessage)\n\n"
    case .assistant(let parts, _):
      let assistantMessage = try parts.compactMap { part -> String? in
        switch part {
        case .text(let textPart): return textPart.text
        case .toolCall: throw UnsupportedFunctionalityError(functionality: "tool-call messages")
        default: return nil
        }
      }.joined()
      text += "\(assistant):\n\(assistantMessage)\n\n"
    case .tool:
      throw UnsupportedFunctionalityError(functionality: "tool messages")
    }
  }

  text += "\(assistant):\n"
  return (text, ["\n\(user):"])
}

/// Configuration for an OpenAI-compatible completion model.
public struct OpenAICompatibleCompletionConfig: Sendable {
  public var provider: String
  public var headers: @Sendable () throws -> [String: String]
  public var url: @Sendable (_ path: String) -> String
  public var httpClient: (any HTTPClient)?
  public var includeUsage: Bool
  public var supportedUrls: [String: [String]]
  public var failedResponseHandler: ResponseHandler<APICallError>

  public init(
    provider: String,
    headers: @escaping @Sendable () throws -> [String: String],
    url: @escaping @Sendable (_ path: String) -> String,
    httpClient: (any HTTPClient)? = nil,
    includeUsage: Bool = false,
    supportedUrls: [String: [String]] = [:],
    failedResponseHandler: @escaping ResponseHandler<APICallError> = defaultOpenAICompatibleFailedResponseHandler
  ) {
    self.provider = provider
    self.headers = headers
    self.url = url
    self.httpClient = httpClient
    self.includeUsage = includeUsage
    self.supportedUrls = supportedUrls
    self.failedResponseHandler = failedResponseHandler
  }
}

/// A legacy completions model (`POST /completions`).
/// Mirrors upstream `OpenAICompatibleCompletionLanguageModel`.
public struct OpenAICompatibleCompletionLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: OpenAICompatibleCompletionConfig

  public init(modelId: String, config: OpenAICompatibleCompletionConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { config.supportedUrls }
  }

  private var providerOptionsName: String {
    String(config.provider.split(separator: ".").first ?? "").trimmingCharacters(in: .whitespaces)
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    var warnings: [SharedV4Warning] = []
    let rawName = providerOptionsName
    let camelName = toCamelCase(rawName)
    warnIfDeprecatedProviderOptionsKey(rawName, options.providerOptions, warnings: &warnings)
    let completionOptions =
      try mergedProviderOptions([rawName, camelName], options.providerOptions, as: OpenAICompatibleCompletionOptions.self)
      ?? OpenAICompatibleCompletionOptions()

    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.tools?.isEmpty == false { warnings.append(.unsupported(feature: "tools")) }
    if options.toolChoice != nil { warnings.append(.unsupported(feature: "toolChoice")) }
    if let responseFormat = options.responseFormat, responseFormat != .text {
      warnings.append(.unsupported(feature: "responseFormat", details: "JSON response format is not supported."))
    }

    let converted = try convertToOpenAICompatibleCompletionPrompt(options.prompt)
    let stop = converted.stopSequences + (options.stopSequences ?? [])

    var args =
      jsonObject([
        "model": .string(modelId),
        "echo": .optional(completionOptions.echo),
        "logit_bias": completionOptions.logitBias.map { .object($0.mapValues { .number($0) }) },
        "suffix": .optional(completionOptions.suffix),
        "user": .optional(completionOptions.user),
        "max_tokens": .optional(options.maxOutputTokens),
        "temperature": .optional(options.temperature),
        "top_p": .optional(options.topP),
        "frequency_penalty": .optional(options.frequencyPenalty),
        "presence_penalty": .optional(options.presencePenalty),
        "seed": .optional(options.seed),
      ]).objectValue ?? [:]
    for key in [rawName, camelName] {
      args.merge(options.providerOptions?[key] ?? [:]) { _, new in new }
    }
    args["prompt"] = .string(converted.prompt)
    args["stop"] = stop.isEmpty ? nil : .array(stop.map(JSONValue.string))
    return (args, warnings)
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: config.url("/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(args),
      failedResponseHandler: config.failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAICompatibleCompletionResponse.self),
      httpClient: config.httpClient)

    let body = response.value
    guard let choice = body.choices?.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }
    let text = choice.text ?? ""
    return LanguageModelV4GenerateResult(
      content: text.isEmpty ? [] : [.text(LanguageModelV4Text(text: text))],
      finishReason: LanguageModelV4FinishReason(
        unified: mapOpenAICompatibleFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertOpenAICompatibleCompletionUsage(body.usage, raw: response.rawValue?["usage"]),
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
    if config.includeUsage {
      body["stream_options"] = ["include_usage": true]
    }

    let response = try await postJsonToApi(
      url: config.url("/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: config.failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(OpenAICompatibleCompletionResponse.self),
      httpClient: config.httpClient)

    let chunks = response.value
    let includeRawChunks = options.includeRawChunks == true
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      continuation.yield(.streamStart(warnings: warnings))
      var isFirstChunk = true
      var finishReason = LanguageModelV4FinishReason(unified: .other)
      var usage: OpenAICompatibleCompletionUsage?
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
            continuation.yield(.error(ProviderStreamError(message: error.message, type: error.type, code: error.code, data: raw)))
            continue
          }
          if isFirstChunk {
            isFirstChunk = false
            continuation.yield(
              .responseMetadata(createLanguageModelResponseMetadata(id: value.id, model: value.model, created: value.created)))
            continuation.yield(.textStart(id: "0"))
          }
          if let chunkUsage = value.usage {
            usage = chunkUsage
            rawUsage = raw["usage"]
          }
          guard let choice = value.choices?.first else { continue }
          if let reason = choice.finish_reason {
            finishReason = LanguageModelV4FinishReason(unified: mapOpenAICompatibleFinishReason(reason), raw: reason)
          }
          if let text = choice.text {
            continuation.yield(.textDelta(id: "0", delta: text))
          }
        }
        if !isFirstChunk { continuation.yield(.textEnd(id: "0")) }
        continuation.yield(
          .finish(usage: convertOpenAICompatibleCompletionUsage(usage, raw: rawUsage), finishReason: finishReason))
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
