import AISDKProviderUtils
import Foundation

/// Provider options for OpenAI completion models. Mirrors upstream `OpenAILanguageModelCompletionOptions`.
public struct OpenAICompletionOptions: Codable, Sendable, Equatable {
  public var echo: Bool?
  public var logitBias: [String: Double]?
  public var suffix: String?
  public var user: String?
  public var logprobs: OpenAILogprobs?

  public init(
    echo: Bool? = nil, logitBias: [String: Double]? = nil, suffix: String? = nil, user: String? = nil,
    logprobs: OpenAILogprobs? = nil
  ) {
    self.echo = echo
    self.logitBias = logitBias
    self.suffix = suffix
    self.user = user
    self.logprobs = logprobs
  }
}

struct OpenAICompletionUsage: Decodable, Sendable {
  var prompt_tokens: Int?
  var completion_tokens: Int?
  var total_tokens: Int?
}

struct OpenAICompletionChunk: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    var text: String?
    var finish_reason: String?
    var logprobs: JSONValue?
  }

  var id: String?
  var created: Double?
  var model: String?
  var choices: [Choice]?
  var usage: OpenAICompletionUsage?
  var error: JSONValue?
}

/// Mirrors upstream `convertOpenAICompletionUsage`.
func convertOpenAICompletionUsage(_ usage: OpenAICompletionUsage?, raw: JSONValue?) -> LanguageModelV4Usage {
  guard let usage else { return LanguageModelV4Usage() }
  return LanguageModelV4Usage(
    inputTokens: .init(total: usage.prompt_tokens, noCache: usage.prompt_tokens ?? 0),
    outputTokens: .init(total: usage.completion_tokens, text: usage.completion_tokens ?? 0),
    raw: raw?.objectValue)
}

/// Renders a chat prompt as `user:` / `assistant:` text. Mirrors upstream
/// `convertToOpenAICompletionPrompt`.
func convertToOpenAICompletionPrompt(
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

/// An OpenAI legacy completions model (`POST /completions`).
/// Mirrors upstream `OpenAICompletionLanguageModel`.
public struct OpenAICompletionLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: OpenAIConfig

  public init(modelId: String, config: OpenAIConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { [:] }
  }

  private var providerOptionsName: String {
    String(config.provider.split(separator: ".").first ?? "openai").trimmingCharacters(in: .whitespaces)
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    var merged: [String: JSONValue] = options.providerOptions?["openai"] ?? [:]
    merged.merge(options.providerOptions?[providerOptionsName] ?? [:]) { _, new in new }
    let openaiOptions =
      try parseProviderOptions(provider: "openai", providerOptions: ["openai": merged], as: OpenAICompletionOptions.self)
      ?? OpenAICompletionOptions()

    var warnings: [SharedV4Warning] = []
    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.tools?.isEmpty == false { warnings.append(.unsupported(feature: "tools")) }
    if options.toolChoice != nil { warnings.append(.unsupported(feature: "toolChoice")) }
    if let responseFormat = options.responseFormat, responseFormat != .text {
      warnings.append(.unsupported(feature: "responseFormat", details: "JSON response format is not supported."))
    }

    let converted = try convertToOpenAICompletionPrompt(options.prompt)
    let stop = converted.stopSequences + (options.stopSequences ?? [])
    let logprobs: Int? =
      switch openaiOptions.logprobs {
      case .enabled(true)?: 0
      case .top(let count)?: count
      default: nil
      }

    let args = jsonObject([
      "model": .string(modelId),
      "echo": .optional(openaiOptions.echo),
      "logit_bias": openaiOptions.logitBias.map { .object($0.mapValues { .number($0) }) },
      "logprobs": .optional(logprobs),
      "suffix": .optional(openaiOptions.suffix),
      "user": .optional(openaiOptions.user),
      "max_tokens": .optional(options.maxOutputTokens),
      "temperature": .optional(options.temperature),
      "top_p": .optional(options.topP),
      "frequency_penalty": .optional(options.frequencyPenalty),
      "presence_penalty": .optional(options.presencePenalty),
      "seed": .optional(options.seed),
      "prompt": .string(converted.prompt),
      "stop": stop.isEmpty ? nil : .array(stop.map(JSONValue.string)),
    ])
    return (args.objectValue ?? [:], warnings)
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: config.url("/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(args),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAICompletionChunk.self),
      httpClient: config.httpClient)

    let body = response.value
    guard let choice = body.choices?.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }
    var metadata: [String: JSONValue] = [:]
    if let logprobs = choice.logprobs, !logprobs.isNull { metadata["logprobs"] = logprobs }

    return LanguageModelV4GenerateResult(
      content: [.text(LanguageModelV4Text(text: choice.text ?? ""))],
      finishReason: LanguageModelV4FinishReason(
        unified: mapOpenAIFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertOpenAICompletionUsage(body.usage, raw: response.rawValue?["usage"]),
      providerMetadata: ["openai": metadata],
      request: LanguageModelV4RequestInfo(body: .object(args)),
      response: LanguageModelV4ResponseInfo(
        metadata: getResponseMetadata(id: body.id, model: body.model, created: body.created),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings) = try getArgs(options)
    var body = args
    body["stream"] = true
    body["stream_options"] = ["include_usage": true]
    let url = config.url("/completions")

    let response = try await postJsonToApi(
      url: url,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(OpenAICompletionChunk.self),
      httpClient: config.httpClient)

    let chunks = try await throwIfOpenAIStreamErrorBeforeOutput(
      stream: response.value, getError: { $0.error },
      isOutputChunk: { chunk in chunk.error == nil && (chunk.choices ?? []).contains { !($0.text ?? "").isEmpty } },
      url: url, requestBodyValues: .object(body), responseHeaders: response.responseHeaders)

    let includeRawChunks = options.includeRawChunks == true
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      continuation.yield(.streamStart(warnings: warnings))
      var finishReason = LanguageModelV4FinishReason(unified: .other)
      var usage: OpenAICompletionUsage?
      var rawUsage: JSONValue?
      var isFirstChunk = true
      var metadata: [String: JSONValue] = [:]
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
            continuation.yield(.error(createOpenAIProviderStreamError(error) ?? ProviderStreamError(message: error.jsonString(), data: error)))
            continue
          }
          if isFirstChunk {
            isFirstChunk = false
            continuation.yield(
              .responseMetadata(getResponseMetadata(id: value.id, model: value.model, created: value.created)))
            continuation.yield(.textStart(id: "0"))
          }
          if let chunkUsage = value.usage {
            usage = chunkUsage
            rawUsage = raw["usage"]
          }
          guard let choice = value.choices?.first else { continue }
          if let reason = choice.finish_reason {
            finishReason = LanguageModelV4FinishReason(unified: mapOpenAIFinishReason(reason), raw: reason)
          }
          if let logprobs = choice.logprobs, !logprobs.isNull { metadata["logprobs"] = logprobs }
          if let text = choice.text, !text.isEmpty {
            continuation.yield(.textDelta(id: "0", delta: text))
          }
        }
        if !isFirstChunk { continuation.yield(.textEnd(id: "0")) }
        continuation.yield(
          .finish(
            usage: convertOpenAICompletionUsage(usage, raw: rawUsage), finishReason: finishReason,
            providerMetadata: ["openai": metadata]))
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

/// Provider options for OpenAI embedding models. Mirrors upstream `OpenAIEmbeddingModelOptions`.
public struct OpenAIEmbeddingOptions: Codable, Sendable, Equatable {
  /// Output dimensions. Only supported by `text-embedding-3` and later.
  public var dimensions: Int?
  public var user: String?

  public init(dimensions: Int? = nil, user: String? = nil) {
    self.dimensions = dimensions
    self.user = user
  }
}

private struct OpenAIEmbeddingResponse: Decodable, Sendable {
  struct Item: Decodable, Sendable {
    var embedding: [Double]
  }

  struct Usage: Decodable, Sendable {
    var prompt_tokens: Int
  }

  var data: [Item]
  var usage: Usage?
}

/// An OpenAI embedding model (`POST /embeddings`). Mirrors upstream `OpenAIEmbeddingModel`.
public struct OpenAIEmbeddingModel: EmbeddingModelV4 {
  public static let maxEmbeddingsPerCall = 2048

  public let modelId: String
  let config: OpenAIConfig

  public init(modelId: String, config: OpenAIConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }
  public var maxEmbeddingsPerCall: Int? { get async throws { Self.maxEmbeddingsPerCall } }
  public var supportsParallelCalls: Bool { get async throws { true } }

  public func doEmbed(_ options: EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result {
    if options.values.count > Self.maxEmbeddingsPerCall {
      throw TooManyEmbeddingValuesForCallError(
        provider: provider, modelId: modelId, maxEmbeddingsPerCall: Self.maxEmbeddingsPerCall, values: options.values)
    }
    let openaiOptions =
      try parseProviderOptions(provider: "openai", providerOptions: options.providerOptions, as: OpenAIEmbeddingOptions.self)
      ?? OpenAIEmbeddingOptions()

    let response = try await postJsonToApi(
      url: config.url("/embeddings"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: jsonObject([
        "model": .string(modelId),
        "input": .array(options.values.map(JSONValue.string)),
        "encoding_format": "float",
        "dimensions": .optional(openaiOptions.dimensions),
        "user": .optional(openaiOptions.user),
      ]),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAIEmbeddingResponse.self),
      httpClient: config.httpClient)

    return EmbeddingModelV4Result(
      embeddings: response.value.data.map(\.embedding),
      usage: response.value.usage.map { .init(tokens: $0.prompt_tokens) },
      response: .init(headers: response.responseHeaders, body: response.rawValue))
  }
}
