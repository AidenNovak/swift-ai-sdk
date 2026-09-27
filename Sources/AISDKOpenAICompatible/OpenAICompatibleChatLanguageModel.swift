import AISDKProviderUtils
import Foundation

/// Configuration for an OpenAI-compatible chat model. Mirrors upstream `OpenAICompatibleChatConfig`.
public struct OpenAICompatibleChatConfig: Sendable {
  public var provider: String
  public var headers: @Sendable () throws -> [String: String]
  public var url: @Sendable (_ path: String) -> String
  public var httpClient: (any HTTPClient)?
  /// Sends `stream_options.include_usage` when streaming.
  public var includeUsage: Bool
  /// Sends JSON schemas as `response_format.json_schema`.
  public var supportsStructuredOutputs: Bool
  public var supportedUrls: [String: [String]]
  /// Rewrites the request body before it is sent, e.g. for proxies.
  public var transformRequestBody: (@Sendable (JSONObject) -> JSONObject)?
  public var metadataExtractor: (any OpenAICompatibleMetadataExtractor)?
  /// Converts usage for providers whose token accounting differs from OpenAI's.
  public var convertUsage: (@Sendable (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage)?
  public var failedResponseHandler: ResponseHandler<APICallError>
  public var generateId: IdGenerator

  public init(
    provider: String,
    headers: @escaping @Sendable () throws -> [String: String],
    url: @escaping @Sendable (_ path: String) -> String,
    httpClient: (any HTTPClient)? = nil,
    includeUsage: Bool = false,
    supportsStructuredOutputs: Bool = false,
    supportedUrls: [String: [String]] = [:],
    transformRequestBody: (@Sendable (JSONObject) -> JSONObject)? = nil,
    metadataExtractor: (any OpenAICompatibleMetadataExtractor)? = nil,
    convertUsage: (@Sendable (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage)? = nil,
    failedResponseHandler: @escaping ResponseHandler<APICallError> = defaultOpenAICompatibleFailedResponseHandler,
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId
  ) {
    self.provider = provider
    self.headers = headers
    self.url = url
    self.httpClient = httpClient
    self.includeUsage = includeUsage
    self.supportsStructuredOutputs = supportsStructuredOutputs
    self.supportedUrls = supportedUrls
    self.transformRequestBody = transformRequestBody
    self.metadataExtractor = metadataExtractor
    self.convertUsage = convertUsage
    self.failedResponseHandler = failedResponseHandler
    self.generateId = generateId
  }
}

/// A chat model for any API that implements OpenAI's `/chat/completions`.
/// Mirrors upstream `OpenAICompatibleChatLanguageModel`.
public struct OpenAICompatibleChatLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: OpenAICompatibleChatConfig

  public init(modelId: String, config: OpenAICompatibleChatConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }
  public var supportsStructuredOutputs: Bool { config.supportsStructuredOutputs }

  public var supportedUrls: [String: [String]] {
    get async throws { config.supportedUrls }
  }

  var providerOptionsName: String {
    String(config.provider.split(separator: ".").first ?? "").trimmingCharacters(in: .whitespaces)
  }

  private func convertUsage(_ usage: OpenAICompatibleTokenUsage?, raw: JSONValue?) -> LanguageModelV4Usage {
    config.convertUsage?(usage, raw) ?? convertOpenAICompatibleChatUsage(usage, raw: raw)
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (
    args: JSONObject, warnings: [SharedV4Warning], metadataKey: String
  ) {
    var warnings: [SharedV4Warning] = []
    let providerOptions = options.providerOptions
    let rawName = providerOptionsName
    let camelName = toCamelCase(rawName)

    if providerOptions?["openai-compatible"] != nil {
      warnings.append(.deprecated(setting: "providerOptions key 'openai-compatible'", message: "Use 'openaiCompatible' instead."))
    }
    warnIfDeprecatedProviderOptionsKey(rawName, providerOptions, warnings: &warnings)

    let compatibleOptions =
      try mergedProviderOptions(
        ["openai-compatible", "openaiCompatible", rawName, camelName], providerOptions,
        as: OpenAICompatibleChatOptions.self) ?? OpenAICompatibleChatOptions()
    let strictJsonSchema = compatibleOptions.strictJsonSchema ?? true

    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }

    var responseFormat: JSONValue?
    if case .json(let schema, let name, let description)? = options.responseFormat {
      if let schema, config.supportsStructuredOutputs {
        responseFormat = [
          "type": "json_schema",
          "json_schema": jsonObject([
            "schema": schema.value,
            "strict": .bool(strictJsonSchema),
            "name": .string(name ?? "response"),
            "description": .optional(description),
          ]),
        ]
      } else {
        if schema != nil {
          warnings.append(
            .unsupported(
              feature: "responseFormat",
              details: "JSON response format schema is only supported with structuredOutputs"))
        }
        responseFormat = ["type": "json_object"]
      }
    }

    let prepared = prepareOpenAICompatibleTools(tools: options.tools, toolChoice: options.toolChoice)
    let metadataKey = resolveProviderOptionsKey(rawName, providerOptions)

    var passthrough: JSONObject = [:]
    for key in [rawName, camelName] {
      for (name, value) in providerOptions?[key] ?? [:] where !OpenAICompatibleChatOptions.knownKeys.contains(name) {
        passthrough[name] = value
      }
    }

    let reasoningEffort: String? =
      compatibleOptions.reasoningEffort ?? (isCustomReasoning(options.reasoning) ? options.reasoning?.rawValue : nil)

    var args =
      jsonObject([
        "model": .string(modelId),
        "user": .optional(compatibleOptions.user),
        "max_tokens": .optional(options.maxOutputTokens),
        "temperature": .optional(options.temperature),
        "top_p": .optional(options.topP),
        "frequency_penalty": .optional(options.frequencyPenalty),
        "presence_penalty": .optional(options.presencePenalty),
        "response_format": responseFormat,
        "stop": .optional(options.stopSequences),
        "seed": .optional(options.seed),
      ]).objectValue ?? [:]
    args.merge(passthrough) { _, new in new }
    let tail = jsonObject([
      "reasoning_effort": .optional(reasoningEffort),
      "verbosity": .optional(compatibleOptions.textVerbosity),
      "messages": .array(try convertToOpenAICompatibleChatMessages(options.prompt, providerOptionsKey: metadataKey)),
      "tools": prepared.tools,
      "tool_choice": prepared.toolChoice,
    ]).objectValue ?? [:]
    args.merge(tail) { _, new in new }

    return (args, warnings + prepared.warnings, metadataKey)
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings, metadataKey) = try getArgs(options)
    let body = config.transformRequestBody?(args) ?? args
    let response = try await postJsonToApi(
      url: config.url("/chat/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: config.failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAICompatibleChatResponse.self),
      httpClient: config.httpClient)

    let responseBody = response.value
    guard let choice = responseBody.choices.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }

    var content = convertOpenAICompatibleContent(choice.message.content)
    if let reasoning = choice.message.reasoning_content ?? choice.message.reasoning, !reasoning.isEmpty {
      content.append(.reasoning(LanguageModelV4Reasoning(text: reasoning)))
    }
    for toolCall in choice.message.tool_calls ?? [] {
      let thoughtSignature = toolCall.extra_content?["google"]?["thought_signature"]?.stringValue
      content.append(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCall.id.flatMap { $0.isEmpty ? nil : $0 } ?? config.generateId(),
            toolName: toolCall.function.name,
            input: toolCall.function.arguments,
            providerMetadata: thoughtSignature.map { [metadataKey: ["thoughtSignature": .string($0)]] })))
    }

    var providerMetadata: SharedV4ProviderMetadata = [metadataKey: [:]]
    if let extracted = try await config.metadataExtractor?.extractMetadata(parsedBody: response.rawValue ?? .null) {
      providerMetadata.merge(extracted) { _, new in new }
    }
    addPredictionTokens(responseBody.usage, to: &providerMetadata, key: metadataKey)

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapOpenAICompatibleFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertUsage(responseBody.usage, raw: response.rawValue?["usage"]),
      providerMetadata: providerMetadata,
      request: LanguageModelV4RequestInfo(body: .object(body)),
      response: LanguageModelV4ResponseInfo(
        metadata: createLanguageModelResponseMetadata(
          id: responseBody.id, model: responseBody.model, created: responseBody.created),
        headers: response.responseHeaders,
        body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings, metadataKey) = try getArgs(options)
    var streamArgs = args
    streamArgs["stream"] = true
    if config.includeUsage {
      streamArgs["stream_options"] = ["include_usage": true]
    }
    let body = config.transformRequestBody?(streamArgs) ?? streamArgs

    let response = try await postJsonToApi(
      url: config.url("/chat/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: config.failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(OpenAICompatibleChatChunk.self),
      httpClient: config.httpClient)

    let chunks = response.value
    let includeRawChunks = options.includeRawChunks == true
    let generateId = config.generateId
    let convertUsage: @Sendable (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage = {
      [config] usage, raw in config.convertUsage?(usage, raw) ?? convertOpenAICompatibleChatUsage(usage, raw: raw)
    }
    let metadataExtractor = config.metadataExtractor

    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      let state = OpenAICompatibleStreamState(
        metadataKey: metadataKey, metadataExtractor: metadataExtractor?.createStreamExtractor())
      let tracker = StreamingToolCallTracker(
        generateId: generateId,
        extractMetadata: { delta in
          delta.extraContent?["google"]?["thought_signature"]?.stringValue.map {
            [metadataKey: ["thoughtSignature": .string($0)]]
          }
        },
        emit: { continuation.yield($0) })
      continuation.yield(.streamStart(warnings: warnings))
      do {
        for try await chunk in chunks {
          state.process(chunk, includeRawChunks: includeRawChunks, tracker: tracker) { continuation.yield($0) }
        }
        state.finish(tracker: tracker, convertUsage: convertUsage) { continuation.yield($0) }
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

private func addPredictionTokens(
  _ usage: OpenAICompatibleTokenUsage?, to metadata: inout SharedV4ProviderMetadata, key: String
) {
  if let accepted = usage?.completion_tokens_details?.accepted_prediction_tokens {
    metadata[key, default: [:]]["acceptedPredictionTokens"] = .number(Double(accepted))
  }
  if let rejected = usage?.completion_tokens_details?.rejected_prediction_tokens {
    metadata[key, default: [:]]["rejectedPredictionTokens"] = .number(Double(rejected))
  }
}

/// A tool call delta held back until its `function.name` arrives; some
/// providers send the first delta without it.
private struct PendingToolCall {
  var id: String?
  var bufferedArguments = ""
  var extraContent: JSONValue?
}

/// Mutable state for converting chat chunks into stream parts.
private final class OpenAICompatibleStreamState {
  let metadataKey: String
  let metadataExtractor: (any OpenAICompatibleStreamMetadataExtractor)?
  var finishReason: LanguageModelV4FinishReason?
  var usage: OpenAICompatibleTokenUsage?
  var rawUsage: JSONValue?
  var metadataExtracted = false
  var isActiveReasoning = false
  var isActiveText = false
  var pendingToolCalls: [Int: PendingToolCall] = [:]
  var pendingOrder: [Int] = []
  var forwardedToolCallIndices: Set<Int> = []

  init(metadataKey: String, metadataExtractor: (any OpenAICompatibleStreamMetadataExtractor)?) {
    self.metadataKey = metadataKey
    self.metadataExtractor = metadataExtractor
  }

  func process(
    _ chunk: ParseResult<OpenAICompatibleChatChunk>, includeRawChunks: Bool, tracker: StreamingToolCallTracker,
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
    metadataExtractor?.processChunk(rawValue)

    if let error = value.error {
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(.error(ProviderStreamError(message: error.message, type: error.type, code: error.code, data: rawValue)))
      return
    }

    if !metadataExtracted {
      let metadata = createLanguageModelResponseMetadata(id: value.id, model: value.model, created: value.created)
      if metadata.id != nil || metadata.modelId != nil || metadata.timestamp != nil {
        metadataExtracted = true
        emit(.responseMetadata(metadata))
      }
    }

    if let chunkUsage = value.usage {
      usage = chunkUsage
      rawUsage = rawValue["usage"]
    }

    guard let choice = value.choices?.first else { return }
    if let reason = choice.finish_reason {
      finishReason = LanguageModelV4FinishReason(unified: mapOpenAICompatibleFinishReason(reason), raw: reason)
    }
    guard let delta = choice.delta else { return }

    if let reasoning = delta.reasoning_content ?? delta.reasoning, !reasoning.isEmpty {
      emitReasoning(reasoning, emit)
    }
    for part in convertOpenAICompatibleContent(delta.content) {
      switch part {
      case .reasoning(let reasoning): emitReasoning(reasoning.text, emit)
      case .text(let text): emitText(text.text, emit)
      default: break
      }
    }

    if let toolCalls = delta.tool_calls, !toolCalls.isEmpty {
      endReasoning(emit)
      for toolCallDelta in toolCalls {
        do {
          try processToolCallDelta(toolCallDelta, tracker: tracker)
        } catch {
          emit(.error(error))
        }
      }
    }
  }

  private func processToolCallDelta(_ delta: StreamingToolCallDelta, tracker: StreamingToolCallTracker) throws {
    guard let index = delta.index, !forwardedToolCallIndices.contains(index) else {
      try tracker.processDelta(delta)
      return
    }
    var pending = pendingToolCalls[index] ?? {
      pendingOrder.append(index)
      return PendingToolCall()
    }()
    if pending.id == nil { pending.id = delta.id }
    if pending.extraContent == nil { pending.extraContent = delta.extraContent }
    pending.bufferedArguments += delta.function?.arguments ?? ""

    guard let name = delta.function?.name else {
      pendingToolCalls[index] = pending
      return
    }
    pendingToolCalls[index] = nil
    pendingOrder.removeAll { $0 == index }
    forwardedToolCallIndices.insert(index)
    try tracker.processDelta(
      StreamingToolCallDelta(
        index: index, id: pending.id, function: .init(name: name, arguments: pending.bufferedArguments),
        extraContent: pending.extraContent))
  }

  private func emitReasoning(_ delta: String, _ emit: (LanguageModelV4StreamPart) -> Void) {
    if isActiveText {
      emit(.textEnd(id: "txt-0"))
      isActiveText = false
    }
    if !isActiveReasoning {
      emit(.reasoningStart(id: "reasoning-0"))
      isActiveReasoning = true
    }
    emit(.reasoningDelta(id: "reasoning-0", delta: delta))
  }

  private func emitText(_ delta: String, _ emit: (LanguageModelV4StreamPart) -> Void) {
    endReasoning(emit)
    if !isActiveText {
      emit(.textStart(id: "txt-0"))
      isActiveText = true
    }
    emit(.textDelta(id: "txt-0", delta: delta))
  }

  private func endReasoning(_ emit: (LanguageModelV4StreamPart) -> Void) {
    if isActiveReasoning {
      emit(.reasoningEnd(id: "reasoning-0"))
      isActiveReasoning = false
    }
  }

  func finish(
    tracker: StreamingToolCallTracker,
    convertUsage: (OpenAICompatibleTokenUsage?, JSONValue?) -> LanguageModelV4Usage,
    emit: (LanguageModelV4StreamPart) -> Void
  ) {
    endReasoning(emit)
    if isActiveText { emit(.textEnd(id: "txt-0")) }

    for index in pendingOrder {
      guard let pending = pendingToolCalls[index] else { continue }
      do {
        try tracker.processDelta(
          StreamingToolCallDelta(index: index, id: pending.id, function: .init(arguments: pending.bufferedArguments)))
      } catch {
        emit(.error(error))
      }
    }
    pendingToolCalls.removeAll()
    tracker.flush()

    if finishReason == nil {
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(.error(InvalidResponseDataError(data: nil, message: "Response stream ended without a finish reason.")))
    }

    var providerMetadata: SharedV4ProviderMetadata = [metadataKey: [:]]
    if let extracted = metadataExtractor?.buildMetadata() {
      providerMetadata.merge(extracted) { _, new in new }
    }
    addPredictionTokens(usage, to: &providerMetadata, key: metadataKey)

    emit(
      .finish(
        usage: convertUsage(usage, rawUsage),
        finishReason: finishReason ?? LanguageModelV4FinishReason(unified: .error),
        providerMetadata: providerMetadata))
  }
}
