import AISDKProviderUtils
import Foundation

/// Configuration for an Anthropic Messages model. Mirrors upstream `AnthropicLanguageModelConfig`.
public struct AnthropicMessagesConfig: Sendable {
  public var provider: String
  public var baseURL: String
  public var headers: @Sendable () throws -> [String: String]
  public var httpClient: (any HTTPClient)?
  public var supportedUrls: [String: [String]]
  public var generateId: IdGenerator
  public var supportsNativeStructuredOutput: Bool
  public var supportsStrictTools: Bool

  public init(
    provider: String,
    baseURL: String,
    headers: @escaping @Sendable () throws -> [String: String],
    httpClient: (any HTTPClient)? = nil,
    supportedUrls: [String: [String]] = [:],
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    supportsNativeStructuredOutput: Bool = true,
    supportsStrictTools: Bool = true
  ) {
    self.provider = provider
    self.baseURL = baseURL
    self.headers = headers
    self.httpClient = httpClient
    self.supportedUrls = supportedUrls
    self.generateId = generateId
    self.supportsNativeStructuredOutput = supportsNativeStructuredOutput
    self.supportsStrictTools = supportsStrictTools
  }
}

/// An Anthropic Messages API model. Mirrors upstream `AnthropicLanguageModel`.
///
/// Also works with Anthropic-compatible endpoints such as DeepSeek's
/// (`baseURL: "https://api.deepseek.com/anthropic/v1"`).
public struct AnthropicMessagesLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: AnthropicMessagesConfig

  public init(modelId: String, config: AnthropicMessagesConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { config.supportedUrls }
  }

  private var providerOptionsName: String {
    String(config.provider.split(separator: ".").first ?? "anthropic")
  }

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: AnthropicErrorData.self, errorToMessage: { $0.error.message })
  }

  struct PreparedRequest {
    var args: JSONObject
    var warnings: [SharedV4Warning]
    var betas: Set<String>
    var usesJsonResponseTool: Bool
  }

  func prepareRequest(_ options: LanguageModelV4CallOptions, stream: Bool) throws -> PreparedRequest {
    var warnings: [SharedV4Warning] = []
    if options.frequencyPenalty != nil { warnings.append(.unsupported(feature: "frequencyPenalty")) }
    if options.presencePenalty != nil { warnings.append(.unsupported(feature: "presencePenalty")) }
    if options.seed != nil { warnings.append(.unsupported(feature: "seed")) }

    var temperature = options.temperature
    var topK = options.topK
    var topP = options.topP
    if let value = temperature, value > 1 {
      warnings.append(
        .unsupported(feature: "temperature", details: "\(formatNumber(value)) exceeds anthropic maximum of 1.0. clamped to 1.0"))
      temperature = 1
    } else if let value = temperature, value < 0 {
      warnings.append(
        .unsupported(feature: "temperature", details: "\(formatNumber(value)) is below anthropic minimum of 0. clamped to 0"))
      temperature = 0
    }

    if case .json(nil, _, _)? = options.responseFormat {
      warnings.append(
        .unsupported(
          feature: "responseFormat", details: "JSON response format requires a schema. The response format is ignored."))
    }

    var anthropicOptions =
      (try parseProviderOptions(provider: "anthropic", providerOptions: options.providerOptions, as: AnthropicOptions.self)
      ?? AnthropicOptions())
    if providerOptionsName != "anthropic" {
      anthropicOptions = anthropicOptions.merging(
        try parseProviderOptions(
          provider: providerOptionsName, providerOptions: options.providerOptions, as: AnthropicOptions.self))
    }

    let capabilities = AnthropicModelCapabilities.forModel(modelId)
    if !capabilities.isKnownModel && options.maxOutputTokens == nil {
      warnings.append(
        .compatibility(
          feature: "maxOutputTokens",
          details:
            "The model \"\(modelId)\" is unknown. The max output tokens have been limited to \(capabilities.maxOutputTokens). Set maxOutputTokens explicitly to override this limit."
        ))
    }
    if capabilities.rejectsSamplingParameters {
      if temperature != nil {
        warnings.append(
          .unsupported(feature: "temperature", details: "temperature is not supported by \(modelId) and will be ignored"))
        temperature = nil
      }
      if topK != nil {
        warnings.append(.unsupported(feature: "topK", details: "topK is not supported by \(modelId) and will be ignored"))
        topK = nil
      }
      if topP != nil {
        warnings.append(.unsupported(feature: "topP", details: "topP is not supported by \(modelId) and will be ignored"))
        topP = nil
      }
    }

    let isAnthropicModel = capabilities.isKnownModel || modelId.contains("claude-")
    let supportsStructuredOutput = config.supportsNativeStructuredOutput && capabilities.supportsStructuredOutput
    let supportsStrictTools = config.supportsStrictTools && capabilities.supportsStructuredOutput
    let structuredOutputMode = anthropicOptions.structuredOutputMode ?? "auto"
    var useStructuredOutput =
      structuredOutputMode == "outputFormat" || (structuredOutputMode == "auto" && supportsStructuredOutput)

    var jsonSchema: JSONSchema?
    if case .json(let schema?, _, _)? = options.responseFormat {
      jsonSchema = schema
    }
    if !useStructuredOutput && capabilities.rejectsForcedToolUse && supportsStructuredOutput && jsonSchema != nil {
      warnings.append(
        .unsupported(
          feature: "providerOptions.anthropic.structuredOutputMode",
          details:
            "structuredOutputMode 'jsonTool' is not supported by \(modelId) because it rejects forced tool use. Using 'outputFormat' instead."
        ))
      useStructuredOutput = true
    }
    let jsonResponseTool: LanguageModelV4FunctionTool? =
      (jsonSchema != nil && !useStructuredOutput)
      ? LanguageModelV4FunctionTool(name: "json", description: "Respond with a JSON object.", inputSchema: jsonSchema!)
      : nil

    let validator = CacheControlValidator()
    let converted = try convertToAnthropicPrompt(
      prompt: options.prompt, sendReasoning: anthropicOptions.sendReasoning ?? true, warnings: &warnings,
      validator: validator)
    var betas = converted.betas

    if let reasoning = options.reasoning, isCustomReasoning(reasoning), anthropicOptions.effort == nil {
      let resolved = resolveReasoning(reasoning, capabilities: capabilities, warnings: &warnings)
      if anthropicOptions.thinking == nil { anthropicOptions.thinking = resolved.thinking }
      if let effort = resolved.effort, anthropicOptions.thinking?.type != "disabled" {
        anthropicOptions.effort = effort
      }
    }

    if capabilities.rejectsThinkingDisabled, let thinking = anthropicOptions.thinking {
      if thinking.type == "disabled" {
        warnings.append(
          .unsupported(
            feature: "providerOptions.anthropic.thinking",
            details:
              "thinking cannot be disabled for \(modelId); it always uses adaptive thinking. The thinking setting has been removed. Lower 'effort' to reduce thinking."
          ))
        anthropicOptions.thinking = nil
      } else if thinking.type == "enabled" {
        warnings.append(
          .unsupported(
            feature: "providerOptions.anthropic.thinking",
            details:
              "budget-based thinking is not supported by \(modelId); it always uses adaptive thinking. Using adaptive thinking instead. Use 'effort' to control how much the model thinks."
          ))
        anthropicOptions.thinking = AnthropicOptions.Thinking(type: "adaptive")
      }
    }

    if capabilities.rejectsThinkingDisabledAboveHighEffort, anthropicOptions.thinking?.type == "disabled",
      let effort = anthropicOptions.effort, effort == "xhigh" || effort == "max"
    {
      warnings.append(
        .unsupported(
          feature: "providerOptions.anthropic.effort",
          details:
            "effort '\(effort)' is not supported by \(modelId) when thinking is disabled. The effort has been lowered to 'high'."
        ))
      anthropicOptions.effort = "high"
    }

    let thinkingType = anthropicOptions.thinking?.type
    let isThinking = thinkingType == "enabled" || thinkingType == "adaptive"
    var thinkingBudget = thinkingType == "enabled" ? anthropicOptions.thinking?.budgetTokens : nil
    let thinkingDisplay = thinkingType == "adaptive" ? anthropicOptions.thinking?.display : nil
    let maxTokens = options.maxOutputTokens ?? capabilities.maxOutputTokens

    if isThinking, thinkingType == "enabled", thinkingBudget == nil {
      warnings.append(
        .compatibility(
          feature: "extended thinking",
          details: "thinking budget is required when thinking is enabled. using default budget of 1024 tokens."))
      thinkingBudget = 1024
    }

    var maxTokensArg = maxTokens
    if isThinking {
      if temperature != nil {
        temperature = nil
        warnings.append(
          .unsupported(feature: "temperature", details: "temperature is not supported when thinking is enabled"))
      }
      if topK != nil {
        topK = nil
        warnings.append(.unsupported(feature: "topK", details: "topK is not supported when thinking is enabled"))
      }
      if topP != nil {
        topP = nil
        warnings.append(.unsupported(feature: "topP", details: "topP is not supported when thinking is enabled"))
      }
      maxTokensArg = maxTokens + (thinkingBudget ?? 0)
    } else if isAnthropicModel, topP != nil, temperature != nil {
      warnings.append(
        .unsupported(feature: "topP", details: "topP is not supported when temperature is set. topP is ignored."))
      topP = nil
    }

    if capabilities.isKnownModel && maxTokensArg > capabilities.maxOutputTokens {
      if options.maxOutputTokens != nil {
        warnings.append(
          .unsupported(
            feature: "maxOutputTokens",
            details:
              "\(maxTokensArg) (maxOutputTokens + thinkingBudget) is greater than \(modelId) \(capabilities.maxOutputTokens) max output tokens. The max output tokens have been limited to \(capabilities.maxOutputTokens)."
          ))
      }
      maxTokensArg = capabilities.maxOutputTokens
    }

    let sendThinking = isThinking || thinkingType == "disabled"
    let outputFormat: JSONValue? =
      useStructuredOutput && jsonSchema != nil ? ["type": "json_schema", "schema": jsonSchema!.value] : nil
    let outputConfig: JSONValue? =
      anthropicOptions.effort != nil || outputFormat != nil
      ? jsonObject(["effort": .optional(anthropicOptions.effort), "format": outputFormat]) : nil
    if thinkingDisplay == "updates" { betas.insert("thinking-display-updates-2026-08-18") }

    let tools = try prepareAnthropicTools(
      tools: jsonResponseTool.map { (options.tools ?? []) + [.function($0)] } ?? (options.tools ?? []),
      toolChoice: jsonResponseTool != nil ? .required : options.toolChoice,
      disableParallelToolUse: jsonResponseTool != nil ? true : anthropicOptions.disableParallelToolUse,
      validator: validator,
      supportsStructuredOutput: jsonResponseTool != nil ? false : supportsStructuredOutput,
      supportsStrictTools: supportsStrictTools,
      eagerInputStreaming: stream && (anthropicOptions.toolStreaming ?? true),
      rejectsForcedToolUse: capabilities.rejectsForcedToolUse)
    warnings += tools.warnings
    betas.formUnion(tools.betas)
    betas.formUnion(anthropicOptions.anthropicBeta ?? [])

    let args = jsonObject([
      "model": .string(modelId),
      "max_tokens": .optional(maxTokensArg),
      "temperature": .optional(temperature),
      "top_k": .optional(topK),
      "top_p": .optional(topP),
      "stop_sequences": .optional(options.stopSequences),
      "thinking": sendThinking
        ? jsonObject([
          "type": .optional(thinkingType), "budget_tokens": .optional(thinkingBudget),
          "display": .optional(thinkingDisplay),
        ]) : nil,
      "output_config": outputConfig,
      "service_tier": .optional(anthropicOptions.serviceTier),
      "cache_control": anthropicOptions.cacheControl,
      "metadata": anthropicOptions.metadata?.userId.map { ["user_id": .string($0)] },
      "system": converted.prompt.system.map(JSONValue.array),
      "messages": .array(converted.prompt.messages),
      "tools": tools.tools,
      "tool_choice": tools.toolChoice,
      "stream": stream ? true : nil,
    ])

    return PreparedRequest(
      args: args.objectValue ?? [:], warnings: warnings + validator.warnings, betas: betas,
      usesJsonResponseTool: jsonResponseTool != nil)
  }

  private func resolveReasoning(
    _ reasoning: LanguageModelV4ReasoningEffort, capabilities: AnthropicModelCapabilities,
    warnings: inout [SharedV4Warning]
  ) -> (thinking: AnthropicOptions.Thinking?, effort: String?) {
    if reasoning == .none {
      if capabilities.rejectsThinkingDisabled {
        warnings.append(
          .compatibility(
            feature: "reasoning",
            details:
              "reasoning 'none' is not supported by \(modelId); it always uses adaptive thinking. Using effort 'low' to minimize thinking instead."
          ))
        return (nil, "low")
      }
      return (AnthropicOptions.Thinking(type: "disabled"), nil)
    }
    if capabilities.supportsAdaptiveThinking {
      let effort = mapReasoningToProviderEffort(
        reasoning: reasoning,
        effortMap: [
          .minimal: "low", .low: "low", .medium: "medium", .high: "high",
          .xhigh: capabilities.supportsXhighEffort ? "xhigh" : "max",
        ],
        warnings: &warnings)
      return (AnthropicOptions.Thinking(type: "adaptive", display: "summarized"), effort)
    }
    let budget = mapReasoningToProviderBudget(
      reasoning: reasoning, maxOutputTokens: capabilities.maxOutputTokens,
      maxReasoningBudget: capabilities.maxOutputTokens, warnings: &warnings)
    return (budget.map { AnthropicOptions.Thinking(type: "enabled", budgetTokens: $0) }, nil)
  }

  private func headers(betas: Set<String>, requestHeaders: [String: String]?) throws -> [String: String] {
    var allBetas = betas
    let configHeaders = try config.headers()
    for source in [configHeaders, requestHeaders ?? [:]] {
      for (name, value) in source where name.lowercased() == "anthropic-beta" {
        for beta in value.lowercased().split(separator: ",") {
          let trimmed = beta.trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty { allBetas.insert(trimmed) }
        }
      }
    }
    return combineHeaders(
      configHeaders, requestHeaders,
      allBetas.isEmpty ? [:] : ["anthropic-beta": allBetas.sorted().joined(separator: ",")])
  }

  private var messagesURL: String { "\(config.baseURL)/messages" }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let request = try prepareRequest(options, stream: false)
    let response = try await postJsonToApi(
      url: messagesURL,
      headers: try headers(betas: request.betas, requestHeaders: options.headers),
      body: .object(request.args),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(AnthropicMessagesResponse.self),
      httpClient: config.httpClient)

    let body = response.value
    var content: [LanguageModelV4Content] = []
    var isJsonResponseFromTool = false

    for block in body.content {
      switch block.type {
      case "text":
        guard !request.usesJsonResponseTool else { continue }
        let webCitations = (block.citations ?? []).filter { $0["type"] == "web_search_result_location" }
        content.append(
          .text(
            LanguageModelV4Text(
              text: block.text ?? "",
              providerMetadata: webCitations.isEmpty ? nil : ["anthropic": ["citations": .array(webCitations)]])))
        for citation in block.citations ?? [] {
          if let source = citationSource(citation) { content.append(.source(source)) }
        }
      case "thinking":
        content.append(
          .reasoning(
            LanguageModelV4Reasoning(
              text: block.thinking ?? "",
              providerMetadata: ["anthropic": jsonObject(["signature": .optional(block.signature)]).objectValue ?? [:]])))
      case "redacted_thinking":
        content.append(
          .reasoning(
            LanguageModelV4Reasoning(text: "", providerMetadata: ["anthropic": ["redactedData": .string(block.data ?? "")]])))
      case "tool_use":
        if request.usesJsonResponseTool && block.name == "json" {
          isJsonResponseFromTool = true
          content.append(.text(LanguageModelV4Text(text: (block.input ?? [:]).jsonString())))
        } else {
          content.append(
            .toolCall(
              LanguageModelV4ToolCall(
                toolCallId: block.id ?? config.generateId(), toolName: block.name ?? "",
                input: (block.input ?? [:]).jsonString())))
        }
      default:
        continue
      }
    }

    let rawUsage = response.rawValue?["usage"]?.objectValue
    let metadata = jsonObject([
      "usage": rawUsage.map(JSONValue.object) ?? .null,
      "stopSequence": .optional(body.stop_sequence) ?? .null,
    ])

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapAnthropicStopReason(body.stop_reason, isJsonResponseFromTool: isJsonResponseFromTool),
        raw: body.stop_reason),
      usage: convertAnthropicUsage(body.usage, raw: rawUsage),
      providerMetadata: providerMetadata(metadata.objectValue ?? [:]),
      request: LanguageModelV4RequestInfo(body: .object(request.args)),
      response: LanguageModelV4ResponseInfo(
        metadata: LanguageModelV4ResponseMetadata(id: body.id, modelId: body.model),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: request.warnings)
  }

  private func providerMetadata(_ metadata: JSONObject) -> SharedV4ProviderMetadata {
    var result: SharedV4ProviderMetadata = ["anthropic": metadata]
    if providerOptionsName != "anthropic" { result[providerOptionsName] = metadata }
    return result
  }

  private func citationSource(_ citation: JSONValue) -> LanguageModelV4Source? {
    switch citation["type"]?.stringValue {
    case "web_search_result_location":
      guard let url = citation["url"]?.stringValue else { return nil }
      return .url(
        id: config.generateId(), url: url, title: citation["title"]?.stringValue,
        providerMetadata: citation["encrypted_index"].map { ["anthropic": ["encryptedIndex": $0]] })
    default:
      return nil
    }
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let request = try prepareRequest(options, stream: true)
    let url = messagesURL
    let response = try await postJsonToApi(
      url: url,
      headers: try headers(betas: request.betas, requestHeaders: options.headers),
      body: .object(request.args),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(AnthropicStreamEvent.self),
      httpClient: config.httpClient)

    var iterator = response.value.makeAsyncIterator()
    var buffered: [ParseResult<AnthropicStreamEvent>] = []
    // A stream that opens with an error is surfaced as an `APICallError`
    // so that retries apply, as upstream does.
    while let first = try await iterator.next() {
      if case .success(let event, let raw) = first, event.type == "error", let error = event.error {
        let streamError = createAnthropicStreamError(type: error.type, message: error.message, data: raw)
        throw APICallError(
          message: error.message, url: url, requestBodyValues: .object(request.args),
          statusCode: streamError.statusCode, responseHeaders: response.responseHeaders,
          isRetryable: streamError.isRetryable, data: raw)
      }
      buffered.append(first)
      if case .success(let event, _) = first, event.type == "ping" { continue }
      break
    }

    let state = AnthropicStreamState(
      usesJsonResponseTool: request.usesJsonResponseTool, includeRawChunks: options.includeRawChunks == true,
      generateId: config.generateId, providerOptionsName: providerOptionsName)
    let warnings = request.warnings
    let remaining = iterator
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      var iterator = remaining
      continuation.yield(.streamStart(warnings: warnings))
      do {
        for chunk in buffered {
          state.process(chunk) { continuation.yield($0) }
        }
        while let chunk = try await iterator.next() {
          state.process(chunk) { continuation.yield($0) }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }

    return LanguageModelV4StreamResult(
      stream: stream, request: LanguageModelV4RequestInfo(body: .object(request.args)),
      responseHeaders: response.responseHeaders)
  }
}

private func formatNumber(_ value: Double) -> String {
  value.rounded() == value ? String(Int(value)) : String(value)
}

/// Converts Anthropic stream events into stream parts.
private final class AnthropicStreamState: @unchecked Sendable {
  enum Block {
    case text(citations: [JSONValue])
    case reasoning
    case toolCall(id: String, name: String, input: String)
  }

  let usesJsonResponseTool: Bool
  let includeRawChunks: Bool
  let generateId: IdGenerator
  let providerOptionsName: String
  var blocks: [Int: Block] = [:]
  var blockType: String?
  var isJsonResponseFromTool = false
  var usage = AnthropicUsage()
  var rawUsage: JSONObject = [:]
  var finishReason = LanguageModelV4FinishReason(unified: .other)
  var stopSequence: String?

  init(usesJsonResponseTool: Bool, includeRawChunks: Bool, generateId: @escaping IdGenerator, providerOptionsName: String) {
    self.usesJsonResponseTool = usesJsonResponseTool
    self.includeRawChunks = includeRawChunks
    self.generateId = generateId
    self.providerOptionsName = providerOptionsName
  }

  func process(_ chunk: ParseResult<AnthropicStreamEvent>, emit: (LanguageModelV4StreamPart) -> Void) {
    if includeRawChunks { emit(.raw(rawValue: chunk.rawValue ?? .null)) }
    guard case .success(let event, let raw) = chunk else {
      emit(.error(chunk.error ?? NoContentGeneratedError()))
      return
    }

    switch event.type {
    case "ping":
      return

    case "message_start":
      guard let message = event.message else { return }
      if let messageUsage = message.usage {
        usage.input_tokens = messageUsage.input_tokens
        usage.cache_read_input_tokens = messageUsage.cache_read_input_tokens ?? 0
        usage.cache_creation_input_tokens = messageUsage.cache_creation_input_tokens ?? 0
        rawUsage = raw["message"]?["usage"]?.objectValue ?? [:]
      }
      if let stopReason = message.stop_reason {
        finishReason = LanguageModelV4FinishReason(
          unified: mapAnthropicStopReason(stopReason, isJsonResponseFromTool: isJsonResponseFromTool), raw: stopReason)
      }
      emit(.responseMetadata(LanguageModelV4ResponseMetadata(id: message.id, modelId: message.model)))
      for block in message.content ?? [] where block.type == "tool_use" {
        let id = block.id ?? generateId()
        let input = (block.input ?? [:]).jsonString()
        emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: block.name ?? "")))
        emit(.toolInputDelta(id: id, delta: input))
        emit(.toolInputEnd(id: id))
        emit(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: block.name ?? "", input: input)))
      }

    case "content_block_start":
      guard let index = event.index, let block = event.content_block else { return }
      blockType = block.type
      let id = String(index)
      switch block.type {
      case "text":
        guard !usesJsonResponseTool else { return }
        blocks[index] = .text(citations: [])
        emit(.textStart(id: id))
      case "thinking":
        blocks[index] = .reasoning
        emit(.reasoningStart(id: id))
      case "redacted_thinking":
        blocks[index] = .reasoning
        emit(.reasoningStart(id: id, providerMetadata: ["anthropic": ["redactedData": .string(block.data ?? "")]]))
      case "tool_use":
        if usesJsonResponseTool && block.name == "json" {
          isJsonResponseFromTool = true
          blocks[index] = .text(citations: [])
          emit(.textStart(id: id))
        } else {
          let toolId = block.id ?? generateId()
          let initialInput = (block.input?.objectValue?.isEmpty == false) ? block.input!.jsonString() : ""
          blocks[index] = .toolCall(id: toolId, name: block.name ?? "", input: initialInput)
          emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolId, toolName: block.name ?? "")))
          if !initialInput.isEmpty { emit(.toolInputDelta(id: toolId, delta: initialInput)) }
        }
      default:
        return
      }

    case "content_block_delta":
      guard let index = event.index, let delta = event.delta else { return }
      let id = String(index)
      switch delta.type {
      case "text_delta":
        guard !usesJsonResponseTool, let text = delta.text else { return }
        emit(.textDelta(id: id, delta: text))
      case "thinking_delta":
        emit(.reasoningDelta(id: id, delta: delta.thinking ?? ""))
      case "signature_delta":
        if blockType == "thinking", let signature = delta.signature {
          emit(.reasoningDelta(id: id, delta: "", providerMetadata: ["anthropic": ["signature": .string(signature)]]))
        }
      case "input_json_delta":
        guard let partial = delta.partial_json, !partial.isEmpty else { return }
        if isJsonResponseFromTool {
          if case .text? = blocks[index] { emit(.textDelta(id: id, delta: partial)) }
        } else if case .toolCall(let toolId, let name, let input)? = blocks[index] {
          emit(.toolInputDelta(id: toolId, delta: partial))
          blocks[index] = .toolCall(id: toolId, name: name, input: input + partial)
        }
      case "citations_delta":
        guard let citation = delta.citation else { return }
        if case .text(let citations)? = blocks[index], citation["type"] == "web_search_result_location" {
          blocks[index] = .text(citations: citations + [citation])
        }
        if citation["type"] == "web_search_result_location", let url = citation["url"]?.stringValue {
          emit(.source(.url(id: generateId(), url: url, title: citation["title"]?.stringValue)))
        }
      default:
        return
      }

    case "content_block_stop":
      guard let index = event.index, let block = blocks[index] else {
        blockType = nil
        return
      }
      let id = String(index)
      switch block {
      case .text(let citations):
        emit(.textEnd(id: id, providerMetadata: citations.isEmpty ? nil : ["anthropic": ["citations": .array(citations)]]))
      case .reasoning:
        emit(.reasoningEnd(id: id))
      case .toolCall(let toolId, let name, let input):
        emit(.toolInputEnd(id: toolId))
        emit(.toolCall(LanguageModelV4ToolCall(toolCallId: toolId, toolName: name, input: input.isEmpty ? "{}" : input)))
      }
      blocks.removeValue(forKey: index)
      blockType = nil

    case "message_delta":
      if let deltaUsage = event.usage {
        if let input = deltaUsage.input_tokens { usage.input_tokens = input }
        usage.output_tokens = deltaUsage.output_tokens
        if let details = deltaUsage.output_tokens_details { usage.output_tokens_details = details }
        if let cacheRead = deltaUsage.cache_read_input_tokens { usage.cache_read_input_tokens = cacheRead }
        if let cacheCreation = deltaUsage.cache_creation_input_tokens {
          usage.cache_creation_input_tokens = cacheCreation
        }
        if let iterations = deltaUsage.iterations { usage.iterations = iterations }
        for (key, value) in raw["usage"]?.objectValue ?? [:] { rawUsage[key] = value }
      }
      finishReason = LanguageModelV4FinishReason(
        unified: mapAnthropicStopReason(event.delta?.stop_reason, isJsonResponseFromTool: isJsonResponseFromTool),
        raw: event.delta?.stop_reason)
      stopSequence = event.delta?.stop_sequence

    case "message_stop":
      let metadata: JSONObject = [
        "usage": .object(rawUsage),
        "stopSequence": stopSequence.map(JSONValue.string) ?? .null,
      ]
      var providerMetadata: SharedV4ProviderMetadata = ["anthropic": metadata]
      if providerOptionsName != "anthropic" { providerMetadata[providerOptionsName] = metadata }
      emit(.finish(usage: convertAnthropicUsage(usage, raw: rawUsage), finishReason: finishReason, providerMetadata: providerMetadata))

    case "error":
      if let error = event.error {
        emit(.error(createAnthropicStreamError(type: error.type, message: error.message, data: raw)))
      }

    default:
      return
    }
  }
}
