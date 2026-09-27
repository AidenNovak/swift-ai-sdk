import AISDKProviderUtils
import Foundation

/// Configuration for a DeepSeek chat model. Mirrors upstream `DeepSeekChatConfig`.
public struct DeepSeekChatConfig: Sendable {
  public var provider: String
  public var headers: @Sendable () throws -> [String: String]
  public var url: @Sendable (_ path: String) -> String
  public var httpClient: (any HTTPClient)?
  public var supportsAssistantPrefixCompletion: Bool
  public var supportsStrictToolCalls: Bool
  public var supportsPenaltySampling: Bool
  /// `false` disables sending the `thinking` parameter entirely.
  public var supportsThinking: Bool
  public var supportsStructuredOutputs: Bool
  public var generateId: IdGenerator

  public init(
    provider: String,
    headers: @escaping @Sendable () throws -> [String: String],
    url: @escaping @Sendable (_ path: String) -> String,
    httpClient: (any HTTPClient)? = nil,
    supportsAssistantPrefixCompletion: Bool = false,
    supportsStrictToolCalls: Bool = false,
    supportsPenaltySampling: Bool = false,
    supportsThinking: Bool = true,
    supportsStructuredOutputs: Bool = false,
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId
  ) {
    self.provider = provider
    self.headers = headers
    self.url = url
    self.httpClient = httpClient
    self.supportsAssistantPrefixCompletion = supportsAssistantPrefixCompletion
    self.supportsStrictToolCalls = supportsStrictToolCalls
    self.supportsPenaltySampling = supportsPenaltySampling
    self.supportsThinking = supportsThinking
    self.supportsStructuredOutputs = supportsStructuredOutputs
    self.generateId = generateId
  }
}

/// A DeepSeek chat completions model. Mirrors upstream `DeepSeekChatLanguageModel`.
public struct DeepSeekChatLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: DeepSeekChatConfig

  public init(modelId: String, config: DeepSeekChatConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { ["image/*": ["^https?://.*$"]] }
  }

  private var providerOptionsName: String {
    String(config.provider.split(separator: ".").first ?? "deepseek").trimmingCharacters(in: .whitespaces)
  }

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message })
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    let deepseekOptions =
      try parseProviderOptions(
        provider: providerOptionsName, providerOptions: options.providerOptions, as: DeepSeekChatOptions.self)
      ?? DeepSeekChatOptions()
    try deepseekOptions.validate()

    let converted = try convertToDeepSeekChatMessages(
      prompt: options.prompt,
      responseFormat: options.responseFormat,
      modelId: modelId,
      providerOptionsName: providerOptionsName,
      supportsAssistantPrefixCompletion: config.supportsAssistantPrefixCompletion,
      supportsStructuredOutputs: config.supportsStructuredOutputs)
    var warnings = converted.warnings

    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.seed != nil { warnings.append(.unsupported(feature: "seed")) }
    if !config.supportsPenaltySampling && options.frequencyPenalty != nil {
      warnings.append(
        .deprecated(
          setting: "frequencyPenalty",
          message:
            "frequencyPenalty is deprecated by DeepSeek and has been omitted. Remove frequencyPenalty from the request."))
    }
    if !config.supportsPenaltySampling && options.presencePenalty != nil {
      warnings.append(
        .deprecated(
          setting: "presencePenalty",
          message:
            "presencePenalty is deprecated by DeepSeek and has been omitted. Remove presencePenalty from the request."))
    }

    let preparedTools = try prepareDeepSeekTools(
      tools: options.tools, toolChoice: options.toolChoice, supportsStrictToolCalls: config.supportsStrictToolCalls)

    let thinking = resolveDeepSeekThinking(
      modelId: modelId, supportsThinking: config.supportsThinking, thinkingType: deepseekOptions.thinking?.type,
      reasoningEffort: deepseekOptions.reasoningEffort, reasoning: options.reasoning, warnings: &warnings)
    let sampling = deepSeekSampling(
      temperature: options.temperature, topP: options.topP, isThinkingEnabled: thinking.isEnabled,
      warnings: &warnings)

    var responseFormat: JSONValue?
    if case .json(let schema, let name, let description)? = options.responseFormat {
      if config.supportsStructuredOutputs, let schema {
        responseFormat = [
          "type": "json_schema",
          "json_schema": jsonObject([
            "schema": schema.value,
            "strict": .bool(deepseekOptions.strictJsonSchema ?? true),
            "name": .string(name ?? "response"),
            "description": .optional(description),
          ]),
        ]
      } else {
        responseFormat = ["type": "json_object"]
      }
    }

    let wantsLogprobs = deepseekOptions.logprobs == true || deepseekOptions.topLogprobs != nil
    let args = jsonObject([
      "model": .string(modelId),
      "logprobs": wantsLogprobs ? true : nil,
      "top_logprobs": .optional(deepseekOptions.topLogprobs),
      "max_tokens": .optional(options.maxOutputTokens),
      "temperature": .optional(sampling.temperature),
      "top_p": .optional(sampling.topP),
      "frequency_penalty": config.supportsPenaltySampling ? .optional(options.frequencyPenalty) : nil,
      "presence_penalty": config.supportsPenaltySampling ? .optional(options.presencePenalty) : nil,
      "response_format": responseFormat,
      "stop": .optional(options.stopSequences),
      "messages": .array(converted.messages),
      "tools": preparedTools.tools,
      "tool_choice": preparedTools.toolChoice,
      "thinking": thinking.type.map { ["type": .string($0)] },
      "user_id": .optional(deepseekOptions.userId),
      "reasoning_effort": .optional(thinking.effort),
    ])

    return (args.objectValue ?? [:], warnings + preparedTools.warnings)
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: config.url("/chat/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(args),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekChatResponse.self),
      httpClient: config.httpClient)

    let body = response.value
    guard let choice = body.choices.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }

    var content: [LanguageModelV4Content] = []
    if let reasoning = choice.message.reasoning_content, !reasoning.isEmpty {
      content.append(.reasoning(LanguageModelV4Reasoning(text: reasoning)))
    }
    for toolCall in choice.message.tool_calls ?? [] {
      content.append(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCall.id.flatMap { $0.isEmpty ? nil : $0 } ?? config.generateId(),
            toolName: toolCall.function.name,
            input: toolCall.function.arguments)))
    }
    if let text = choice.message.content, !text.isEmpty {
      content.append(.text(LanguageModelV4Text(text: text)))
    }

    let metadata = jsonObject([
      "promptCacheHitTokens": .optional(body.usage?.prompt_cache_hit_tokens),
      "promptCacheMissTokens": .optional(body.usage?.prompt_cache_miss_tokens),
      "responseObject": .optional(body.object),
      "choiceIndex": .optional(choice.index),
      "messageRole": .optional(choice.message.role),
      "toolCallTypes": choice.message.tool_calls.map { .array($0.compactMap(\.type).map(JSONValue.string)) },
      "logprobs": choice.logprobs.flatMap { $0.isNull ? nil : $0 },
      "systemFingerprint": .optional(body.system_fingerprint),
    ])

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapDeepSeekFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertDeepSeekUsage(body.usage, raw: response.rawValue?["usage"]),
      providerMetadata: [providerOptionsName: metadata.objectValue ?? [:]],
      request: LanguageModelV4RequestInfo(body: .object(args)),
      response: LanguageModelV4ResponseInfo(
        metadata: createLanguageModelResponseMetadata(id: body.id, model: body.model, created: body.created),
        headers: response.responseHeaders,
        body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings) = try getArgs(options)
    var body = args
    body["stream"] = true
    body["stream_options"] = ["include_usage": true]

    let response = try await postJsonToApi(
      url: config.url("/chat/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(DeepSeekChatChunk.self),
      httpClient: config.httpClient)

    let chunks = response.value
    let providerOptionsName = providerOptionsName
    let includeRawChunks = options.includeRawChunks == true
    let generateId = config.generateId

    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      let state = DeepSeekStreamState(providerOptionsName: providerOptionsName)
      let tracker = StreamingToolCallTracker(generateId: generateId) { continuation.yield($0) }
      continuation.yield(.streamStart(warnings: warnings))
      do {
        for try await chunk in chunks {
          state.process(chunk, includeRawChunks: includeRawChunks, tracker: tracker) { continuation.yield($0) }
        }
        state.finish(tracker: tracker) { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }

    return LanguageModelV4StreamResult(
      stream: stream, request: LanguageModelV4RequestInfo(body: .object(body)),
      responseHeaders: response.responseHeaders)
  }
}

/// Mutable state for converting DeepSeek chunks into stream parts.
private final class DeepSeekStreamState {
  let providerOptionsName: String
  var finishReason = LanguageModelV4FinishReason(unified: .other)
  var usage: DeepSeekTokenUsage?
  var rawUsage: JSONValue?
  var systemFingerprint: String?
  var isFirstChunk = true
  var isActiveReasoning = false
  var isActiveText = false
  var responseObject: String?
  var choiceIndex: Int?
  var messageRole: String?
  var toolCallTypes: [Int: String] = [:]
  var contentLogprobs: [JSONValue] = []
  var reasoningLogprobs: [JSONValue] = []

  init(providerOptionsName: String) {
    self.providerOptionsName = providerOptionsName
  }

  func process(
    _ chunk: ParseResult<DeepSeekChatChunk>, includeRawChunks: Bool, tracker: StreamingToolCallTracker,
    emit: (LanguageModelV4StreamPart) -> Void
  ) {
    if includeRawChunks {
      emit(.raw(rawValue: chunk.rawValue ?? .null))
    }

    guard case .success(let value, let rawValue) = chunk else {
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(.error(chunk.error ?? NoContentGeneratedError()))
      return
    }

    if let error = value.error {
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(.error(createDeepSeekStreamError(error, data: rawValue)))
      return
    }

    if isFirstChunk {
      isFirstChunk = false
      emit(.responseMetadata(createLanguageModelResponseMetadata(id: value.id, model: value.model, created: value.created)))
    }

    if let chunkUsage = value.usage {
      usage = chunkUsage
      rawUsage = rawValue["usage"]
    }
    if let object = value.object { responseObject = object }
    if let fingerprint = value.system_fingerprint { systemFingerprint = fingerprint }

    guard let choice = value.choices?.first else { return }
    if let index = choice.index { choiceIndex = index }
    if let reason = choice.finish_reason {
      finishReason = LanguageModelV4FinishReason(unified: mapDeepSeekFinishReason(reason), raw: reason)
    }
    contentLogprobs += choice.logprobs?.content ?? []
    reasoningLogprobs += choice.logprobs?.reasoning_content ?? []

    guard let delta = choice.delta else { return }
    if let role = delta.role { messageRole = role }

    if let reasoning = delta.reasoning_content, !reasoning.isEmpty {
      if !isActiveReasoning {
        emit(.reasoningStart(id: "reasoning-0"))
        isActiveReasoning = true
      }
      emit(.reasoningDelta(id: "reasoning-0", delta: reasoning))
    }

    if let content = delta.content, !content.isEmpty {
      if !isActiveText {
        emit(.textStart(id: "txt-0"))
        isActiveText = true
      }
      if isActiveReasoning {
        emit(.reasoningEnd(id: "reasoning-0"))
        isActiveReasoning = false
      }
      emit(.textDelta(id: "txt-0", delta: content))
    }

    if let toolCalls = delta.tool_calls, !toolCalls.isEmpty {
      if isActiveReasoning {
        emit(.reasoningEnd(id: "reasoning-0"))
        isActiveReasoning = false
      }
      for toolCallDelta in toolCalls {
        if let type = toolCallDelta.type, let index = toolCallDelta.index {
          toolCallTypes[index] = type
        }
        do {
          try tracker.processDelta(toolCallDelta)
        } catch {
          emit(.error(error))
        }
      }
    }
  }

  func finish(tracker: StreamingToolCallTracker, emit: (LanguageModelV4StreamPart) -> Void) {
    if isActiveReasoning { emit(.reasoningEnd(id: "reasoning-0")) }
    if isActiveText { emit(.textEnd(id: "txt-0")) }
    tracker.flush()

    let logprobs: JSONValue? =
      contentLogprobs.isEmpty && reasoningLogprobs.isEmpty
      ? nil
      : jsonObject([
        "content": contentLogprobs.isEmpty ? nil : .array(contentLogprobs),
        "reasoning_content": reasoningLogprobs.isEmpty ? nil : .array(reasoningLogprobs),
      ])

    let metadata = jsonObject([
      "promptCacheHitTokens": .optional(usage?.prompt_cache_hit_tokens),
      "promptCacheMissTokens": .optional(usage?.prompt_cache_miss_tokens),
      "responseObject": .optional(responseObject),
      "choiceIndex": .optional(choiceIndex),
      "messageRole": .optional(messageRole),
      "toolCallTypes": toolCallTypes.isEmpty
        ? nil : .array(toolCallTypes.sorted { $0.key < $1.key }.map { .string($0.value) }),
      "logprobs": logprobs,
      "systemFingerprint": .optional(systemFingerprint),
    ])

    emit(
      .finish(
        usage: convertDeepSeekUsage(usage, raw: rawUsage),
        finishReason: finishReason,
        providerMetadata: [providerOptionsName: metadata.objectValue ?? [:]]))
  }
}

/// Classifies a DeepSeek stream error. Mirrors upstream `createDeepSeekStreamError`.
func createDeepSeekStreamError(_ error: DeepSeekErrorDetail, data: JSONValue?) -> ProviderStreamError {
  let (statusCode, isRetryable) = deepSeekStreamErrorMetadata(type: error.type, code: error.code)
  return ProviderStreamError(
    message: error.message, type: error.type, code: error.code, statusCode: statusCode, isRetryable: isRetryable,
    data: data)
}

private func deepSeekStreamErrorMetadata(type: String?, code: JSONValue?) -> (Int?, Bool?) {
  let codeString = code?.stringValue
  if codeString == "insufficient_quota" || type == "insufficient_quota" {
    return (429, false)
  }

  let explicitStatus: Int? =
    if let number = code?.intValue {
      number
    } else if let codeString, codeString.count == 3, let number = Int(codeString) {
      number
    } else {
      nil
    }
  if let explicitStatus, (400...599).contains(explicitStatus) {
    return (explicitStatus, APICallError.defaultIsRetryable(statusCode: explicitStatus))
  }

  for discriminator in [codeString, type] {
    switch discriminator {
    case "rate_limit_exceeded", "rate_limit_error": return (429, true)
    case "server_error", "api_error", "internal_server_error": return (500, true)
    case "overloaded_error", "service_unavailable": return (503, true)
    case "timeout", "timeout_error": return (504, true)
    case "authentication_error", "invalid_api_key": return (401, false)
    case "permission_error": return (403, false)
    case "not_found_error", "model_not_found": return (404, false)
    case "bad_request", "context_length_exceeded", "invalid_request_error": return (400, false)
    default: continue
    }
  }
  return (nil, nil)
}
