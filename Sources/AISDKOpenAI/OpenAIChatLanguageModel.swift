import AISDKProviderUtils
import Foundation

/// Shared configuration for OpenAI models. Mirrors upstream `OpenAIConfig`.
public struct OpenAIConfig: Sendable {
  public var provider: String
  public var headers: @Sendable () throws -> [String: String]
  public var url: @Sendable (_ path: String) -> String
  public var httpClient: (any HTTPClient)?
  public var generateId: IdGenerator
  /// Base64 data starting with one of these prefixes is sent as a file ID
  /// (Responses API). Soft-deprecated; use provider references instead.
  public var fileIdPrefixes: [String]?
  /// Adds `type: "message"` to Responses API message items.
  public var explicitMessageItemType: Bool
  /// Whether the Responses API accepts `web_search_call.action.sources` in `include`.
  public var supportsWebSearchSourcesInclude: Bool

  public init(
    provider: String,
    headers: @escaping @Sendable () throws -> [String: String],
    url: @escaping @Sendable (_ path: String) -> String,
    httpClient: (any HTTPClient)? = nil,
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    fileIdPrefixes: [String]? = nil,
    explicitMessageItemType: Bool = false,
    supportsWebSearchSourcesInclude: Bool = true
  ) {
    self.provider = provider
    self.headers = headers
    self.url = url
    self.httpClient = httpClient
    self.generateId = generateId
    self.fileIdPrefixes = fileIdPrefixes
    self.explicitMessageItemType = explicitMessageItemType
    self.supportsWebSearchSourcesInclude = supportsWebSearchSourcesInclude
  }
}

/// An OpenAI Chat Completions model (`POST /chat/completions`).
/// Mirrors upstream `OpenAIChatLanguageModel`.
public struct OpenAIChatLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: OpenAIConfig

  public init(modelId: String, config: OpenAIConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { ["image/*": ["^https?://.*$"]] }
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    var warnings: [SharedV4Warning] = []
    let openaiOptions =
      try parseProviderOptions(provider: "openai", providerOptions: options.providerOptions, as: OpenAIChatOptions.self)
      ?? OpenAIChatOptions()
    try openaiOptions.validate()
    let capabilities = getOpenAILanguageModelCapabilities(modelId)

    var reasoningEffort =
      openaiOptions.reasoningEffort ?? (isCustomReasoning(options.reasoning) ? options.reasoning?.rawValue : nil)
    if let effort = reasoningEffort, let supported = capabilities.supportedReasoningEfforts, !supported.contains(effort) {
      warnings.append(
        .unsupported(
          feature: "reasoningEffort",
          details: "\(modelId) only supports the following reasoning efforts: \(supported.joined(separator: ", "))"))
      reasoningEffort = nil
    }

    let isReasoningModel = openaiOptions.forceReasoning ?? capabilities.isReasoningModel
    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }

    let converted = try convertToOpenAIChatMessages(
      options.prompt,
      systemMessageMode: openaiOptions.systemMessageMode
        ?? (isReasoningModel ? .developer : capabilities.systemMessageMode))
    warnings += converted.warnings

    var responseFormat: JSONValue?
    if case .json(let schema, let name, let description)? = options.responseFormat {
      if let schema {
        let normalized = try normalizeOpenAIJsonSchema(schema)
        warnings += normalized.warnings
        responseFormat = [
          "type": "json_schema",
          "json_schema": jsonObject([
            "schema": normalized.schema.value,
            "strict": .bool(openaiOptions.strictJsonSchema ?? true),
            "name": .string(name ?? "response"),
            "description": .optional(description),
          ]),
        ]
      } else {
        responseFormat = ["type": "json_object"]
      }
    }

    let logprobs: Bool? =
      switch openaiOptions.logprobs {
      case .enabled(true)?, .top?: true
      default: nil
      }
    let topLogprobs: Int? =
      switch openaiOptions.logprobs {
      case .top(let count)?: count
      case .enabled(true)?: 0
      default: nil
      }

    var args: JSONObject =
      jsonObject([
        "model": .string(modelId),
        "logit_bias": openaiOptions.logitBias.map { .object($0.mapValues { .number($0) }) },
        "logprobs": .optional(logprobs),
        "top_logprobs": .optional(topLogprobs),
        "user": .optional(openaiOptions.user),
        "parallel_tool_calls": .optional(openaiOptions.parallelToolCalls),
        "max_tokens": .optional(options.maxOutputTokens),
        "temperature": .optional(options.temperature),
        "top_p": .optional(options.topP),
        "frequency_penalty": .optional(options.frequencyPenalty),
        "presence_penalty": .optional(options.presencePenalty),
        "response_format": responseFormat,
        "stop": .optional(options.stopSequences),
        "seed": .optional(options.seed),
        "verbosity": .optional(openaiOptions.textVerbosity),
        "max_completion_tokens": .optional(openaiOptions.maxCompletionTokens),
        "store": .optional(openaiOptions.store),
        "metadata": openaiOptions.metadata.map { .object($0.mapValues { .string($0) }) },
        "prediction": openaiOptions.prediction,
        "reasoning_effort": .optional(reasoningEffort),
        "service_tier": .optional(openaiOptions.serviceTier),
        "prompt_cache_key": .optional(openaiOptions.promptCacheKey),
        "prompt_cache_options": openaiOptions.promptCacheOptions.map {
          jsonObject(["mode": .optional($0.mode), "ttl": .optional($0.ttl)])
        },
        "prompt_cache_retention": .optional(openaiOptions.promptCacheRetention),
        "safety_identifier": .optional(openaiOptions.safetyIdentifier),
        "messages": .array(converted.messages),
      ]).objectValue ?? [:]

    if capabilities.supportedReasoningEfforts != nil, args["prompt_cache_retention"] != nil {
      args["prompt_cache_retention"] = nil
      warnings.append(
        .unsupported(
          feature: "promptCacheRetention",
          details: "promptCacheRetention is not supported by GPT-6 and later models; use promptCacheOptions instead"))
    }

    func remove(_ key: String, _ warning: SharedV4Warning) {
      if args.removeValue(forKey: key) != nil { warnings.append(warning) }
    }

    if isReasoningModel {
      if reasoningEffort != "none" || !capabilities.supportsNonReasoningParameters {
        remove("temperature", .unsupported(feature: "temperature", details: "temperature is not supported for reasoning models"))
        remove("top_p", .unsupported(feature: "topP", details: "topP is not supported for reasoning models"))
        remove("logprobs", .other(message: "logprobs is not supported for reasoning models"))
      }
      remove(
        "frequency_penalty",
        .unsupported(feature: "frequencyPenalty", details: "frequencyPenalty is not supported for reasoning models"))
      remove(
        "presence_penalty",
        .unsupported(feature: "presencePenalty", details: "presencePenalty is not supported for reasoning models"))
      remove("logit_bias", .other(message: "logitBias is not supported for reasoning models"))
      remove("top_logprobs", .other(message: "topLogprobs is not supported for reasoning models"))
      if let maxTokens = args.removeValue(forKey: "max_tokens"), args["max_completion_tokens"] == nil {
        args["max_completion_tokens"] = maxTokens
      }
    } else if modelId.hasPrefix("gpt-4o-search-preview") || modelId.hasPrefix("gpt-4o-mini-search-preview") {
      remove(
        "temperature",
        .unsupported(
          feature: "temperature",
          details: "temperature is not supported for the search preview models and has been removed."))
    }

    if openaiOptions.serviceTier == "flex", !capabilities.supportsFlexProcessing {
      warnings.append(
        .unsupported(feature: "serviceTier", details: "flex processing is only available for o3, o4-mini, and gpt-5 models"))
      args["service_tier"] = nil
    }
    if openaiOptions.serviceTier == "priority" || openaiOptions.serviceTier == "fast",
      !capabilities.supportsPriorityProcessing
    {
      warnings.append(
        .unsupported(
          feature: "serviceTier",
          details:
            "priority processing is only available for supported models (gpt-4, gpt-5, gpt-5-mini, o3, o4-mini) and requires Enterprise access. gpt-5-nano is not supported"
        ))
      args["service_tier"] = nil
    }

    let prepared = try prepareOpenAIChatTools(tools: options.tools, toolChoice: options.toolChoice)
    if let tools = prepared.tools { args["tools"] = tools }
    if let toolChoice = prepared.toolChoice { args["tool_choice"] = toolChoice }
    return (args, warnings + prepared.warnings)
  }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (body, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: config.url("/chat/completions"),
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(OpenAIChatResponse.self),
      httpClient: config.httpClient)

    let responseBody = response.value
    guard let choice = responseBody.choices.first else {
      throw InvalidResponseDataError(data: response.rawValue, message: "Response did not contain any choices.")
    }

    var content: [LanguageModelV4Content] = []
    let text = (choice.message.content?.isEmpty == false) ? choice.message.content : choice.message.audio?.transcript
    if let text, !text.isEmpty {
      content.append(.text(LanguageModelV4Text(text: text)))
    }
    for toolCall in choice.message.tool_calls ?? [] {
      content.append(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCall.id.flatMap { $0.isEmpty ? nil : $0 } ?? config.generateId(),
            toolName: toolCall.function.name, input: toolCall.function.arguments)))
    }
    for annotation in choice.message.annotations ?? [] {
      content.append(
        .source(.url(id: config.generateId(), url: annotation.url_citation.url, title: annotation.url_citation.title)))
    }

    var metadata: [String: JSONValue] = [:]
    let details = responseBody.usage?.completion_tokens_details
    if let accepted = details?.accepted_prediction_tokens { metadata["acceptedPredictionTokens"] = .number(Double(accepted)) }
    if let rejected = details?.rejected_prediction_tokens { metadata["rejectedPredictionTokens"] = .number(Double(rejected)) }
    if let logprobs = choice.logprobs?.content, !logprobs.isNull { metadata["logprobs"] = logprobs }

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapOpenAIFinishReason(choice.finish_reason), raw: choice.finish_reason),
      usage: convertOpenAIChatUsage(responseBody.usage, raw: response.rawValue?["usage"]),
      providerMetadata: ["openai": metadata],
      request: LanguageModelV4RequestInfo(body: .object(body)),
      response: LanguageModelV4ResponseInfo(
        metadata: getResponseMetadata(
          id: responseBody.id, model: responseBody.model, created: responseBody.created),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings) = try getArgs(options)
    var body = args
    body["stream"] = true
    body["stream_options"] = ["include_usage": true]
    let url = config.url("/chat/completions")

    let response = try await postJsonToApi(
      url: url,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(OpenAIChatChunk.self),
      httpClient: config.httpClient)

    let chunks = try await throwIfOpenAIStreamErrorBeforeOutput(
      stream: response.value, getError: { $0.error }, isOutputChunk: { $0.isOutput }, url: url,
      requestBodyValues: .object(body), responseHeaders: response.responseHeaders)

    let includeRawChunks = options.includeRawChunks == true
    let generateId = config.generateId
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      let tracker = StreamingToolCallTracker(generateId: generateId, typeValidation: .ifPresent) {
        continuation.yield($0)
      }
      var finishReason = LanguageModelV4FinishReason(unified: .other)
      var usage: OpenAIChatUsage?
      var rawUsage: JSONValue?
      var metadataExtracted = false
      var isActiveText = false
      var metadata: [String: JSONValue] = [:]
      continuation.yield(.streamStart(warnings: warnings))

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

          if !metadataExtracted {
            let responseMetadata = getResponseMetadata(id: value.id, model: value.model, created: value.created)
            if !responseMetadata.isEmpty {
              metadataExtracted = true
              continuation.yield(.responseMetadata(responseMetadata))
            }
          }

          if let chunkUsage = value.usage {
            usage = chunkUsage
            rawUsage = raw["usage"]
            if let accepted = chunkUsage.completion_tokens_details?.accepted_prediction_tokens {
              metadata["acceptedPredictionTokens"] = .number(Double(accepted))
            }
            if let rejected = chunkUsage.completion_tokens_details?.rejected_prediction_tokens {
              metadata["rejectedPredictionTokens"] = .number(Double(rejected))
            }
          }

          guard let choice = value.choices?.first else { continue }
          if let reason = choice.finish_reason {
            finishReason = LanguageModelV4FinishReason(unified: mapOpenAIFinishReason(reason), raw: reason)
          }
          if let logprobs = choice.logprobs?.content, !logprobs.isNull { metadata["logprobs"] = logprobs }
          guard let delta = choice.delta else { continue }

          if let text = delta.content {
            if !isActiveText {
              continuation.yield(.textStart(id: "0"))
              isActiveText = true
            }
            continuation.yield(.textDelta(id: "0", delta: text))
          }
          for toolCallDelta in delta.tool_calls ?? [] {
            do {
              try tracker.processDelta(toolCallDelta)
            } catch {
              continuation.yield(.error(error))
            }
          }
          for annotation in delta.annotations ?? [] {
            continuation.yield(
              .source(.url(id: generateId(), url: annotation.url_citation.url, title: annotation.url_citation.title)))
          }
        }

        if isActiveText { continuation.yield(.textEnd(id: "0")) }
        tracker.flush()
        continuation.yield(
          .finish(
            usage: convertOpenAIChatUsage(usage, raw: rawUsage), finishReason: finishReason,
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
