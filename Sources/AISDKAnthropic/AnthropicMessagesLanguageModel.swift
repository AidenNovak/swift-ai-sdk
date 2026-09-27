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
  /// Builds the request URL from the base URL and whether the call streams,
  /// e.g. for Bedrock or Vertex. Defaults to `{baseURL}/messages`.
  public var buildRequestURL: (@Sendable (String, Bool) -> String)?
  /// Adjusts the request body, e.g. to move betas into the body.
  public var transformRequestBody: (@Sendable (JSONObject, Set<String>) -> JSONObject)?

  public init(
    provider: String,
    baseURL: String,
    headers: @escaping @Sendable () throws -> [String: String],
    httpClient: (any HTTPClient)? = nil,
    supportedUrls: [String: [String]] = [:],
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    supportsNativeStructuredOutput: Bool = true,
    supportsStrictTools: Bool = true,
    buildRequestURL: (@Sendable (String, Bool) -> String)? = nil,
    transformRequestBody: (@Sendable (JSONObject, Set<String>) -> JSONObject)? = nil
  ) {
    self.provider = provider
    self.baseURL = baseURL
    self.headers = headers
    self.httpClient = httpClient
    self.supportedUrls = supportedUrls
    self.generateId = generateId
    self.supportsNativeStructuredOutput = supportsNativeStructuredOutput
    self.supportsStrictTools = supportsStrictTools
    self.buildRequestURL = buildRequestURL
    self.transformRequestBody = transformRequestBody
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
    String(config.provider.split(separator: ".", maxSplits: 1).first ?? "anthropic")
  }

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: AnthropicErrorData.self, errorToMessage: { $0.error.message })
  }

  struct PreparedRequest {
    var args: JSONObject
    var warnings: [SharedV4Warning]
    var betas: Set<String>
    var usesJsonResponseTool: Bool
    var toolNameMapping: ToolNameMapping
    var usedCustomProviderKey: Bool
  }

  // MARK: - Request

  func prepareRequest(_ options: LanguageModelV4CallOptions, stream: Bool, userSuppliedBetas: Set<String> = [])
    throws -> PreparedRequest
  {
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

    var (anthropicOptions, usedCustomProviderKey) = try parseAnthropicOptions(
      providerOptions: options.providerOptions, providerOptionsName: providerOptionsName)

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
    if jsonResponseTool != nil && anthropicOptions.disableParallelToolUse == false {
      warnings.append(
        .unsupported(
          feature: "providerOptions.anthropic.disableParallelToolUse",
          details:
            "`disableParallelToolUse: false` is ignored when using the JSON response tool. Parallel tool use is disabled to ensure a single coherent JSON tool call."
        ))
    }

    let contextManagement = anthropicOptions.contextManagement
    let compaction = anthropicOptions.compaction
    if contextManagement != nil && compaction != nil {
      throw InvalidArgumentError(
        argument: "providerOptions",
        message: "Anthropic provider options `compaction` and `contextManagement` cannot be used together.")
    }

    let validator = CacheControlValidator()
    let toolNameMapping = ToolNameMapping(tools: options.tools, providerToolNames: anthropicProviderToolNames)
    var toolsetNames: [String: String] = [:]
    for case .provider(let tool) in options.tools ?? [] where tool.id == "anthropic.computer_toolset_20260801" {
      toolsetNames[tool.name] = "computer"
    }
    let converted = try convertToAnthropicPrompt(
      prompt: options.prompt, sendReasoning: anthropicOptions.sendReasoning ?? true, warnings: &warnings,
      validator: validator, toolNameMapping: toolNameMapping, toolsetNames: toolsetNames)
    var betas = converted.betas

    if let reasoning = options.reasoning, isCustomReasoning(reasoning), anthropicOptions.effort == nil,
      let resolved = resolveReasoning(reasoning, capabilities: capabilities, warnings: &warnings)
    {
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
    let blockBinding = anthropicOptions.thinking?.blockBinding
    let sendThinking = isThinking || thinkingType == "disabled" || blockBinding != nil
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

    let thinking: JSONValue? =
      sendThinking
      ? jsonObject([
        "type": .optional(thinkingType), "budget_tokens": .optional(thinkingBudget),
        "display": .optional(thinkingDisplay),
        "block_binding": blockBinding.map { ["prefix_mismatch_behavior": .string($0.prefixMismatchBehavior)] },
      ]) : nil

    let outputFormat: JSONValue? =
      useStructuredOutput && jsonSchema != nil
      ? ["type": "json_schema", "schema": sanitizeJsonSchema(jsonSchema!.value)] : nil
    let taskBudget: JSONValue? = anthropicOptions.taskBudget.map { budget in
      jsonObject([
        "type": .string(budget.type), "total": .number(Double(budget.total)), "remaining": .optional(budget.remaining),
      ])
    }
    let outputConfig: JSONValue? =
      anthropicOptions.effort != nil || taskBudget != nil || outputFormat != nil
      ? jsonObject(["effort": .optional(anthropicOptions.effort), "task_budget": taskBudget, "format": outputFormat])
      : nil

    let fallbacks: JSONValue? =
      if let value = anthropicOptions.fallbacks, value == "default" || (value.arrayValue?.isEmpty == false) {
        value
      } else {
        nil
      }

    let mcpServers: JSONValue? =
      (anthropicOptions.mcpServers?.isEmpty == false)
      ? .array(
        anthropicOptions.mcpServers!.map { server in
          jsonObject([
            "type": .string(server.type), "name": .string(server.name), "url": .string(server.url),
            "authorization_token": .optional(server.authorizationToken),
            "tool_configuration": server.toolConfiguration.map { configuration in
              jsonObject([
                "allowed_tools": .optional(configuration.allowedTools), "enabled": .optional(configuration.enabled),
              ])
            },
          ])
        }) : nil

    var container: JSONValue?
    if let options = anthropicOptions.container {
      if let skills = options.skills, !skills.isEmpty {
        container = jsonObject([
          "id": .optional(options.id),
          "skills": .array(
            try skills.map { skill in
              let skillId =
                skill.type == "custom"
                ? try resolveProviderReference(skill.providerReference ?? [:], provider: "anthropic") : skill.skillId
              return jsonObject([
                "type": .string(skill.type), "skill_id": .optional(skillId), "version": .optional(skill.version),
              ])
            }),
        ])
      } else {
        container = .optional(options.id)
      }
    }

    let safeguards: JSONValue? =
      (anthropicOptions.safeguards?.isEmpty == false)
      ? .array(
        anthropicOptions.safeguards!.map { safeguard in
          jsonObject([
            "type": .string(safeguard.type), "classifier_context": safeguard.classifierContext.map(JSONValue.object),
          ])
        }) : nil

    let contextManagementArg: JSONValue? = contextManagement.map { management in
      ["edits": .array(management.edits.compactMap { contextManagementEdit($0, warnings: &warnings) })]
    }

    let tools = prepareAnthropicTools(
      tools: jsonResponseTool.map { (options.tools ?? []) + [.function($0)] } ?? (options.tools ?? []),
      toolChoice: jsonResponseTool != nil ? .required : options.toolChoice,
      disableParallelToolUse: jsonResponseTool != nil ? true : anthropicOptions.disableParallelToolUse,
      validator: validator,
      supportsStructuredOutput: jsonResponseTool != nil ? false : supportsStructuredOutput,
      supportsStrictTools: supportsStrictTools,
      eagerInputStreaming: stream && (anthropicOptions.toolStreaming ?? true),
      rejectsForcedToolUse: capabilities.rejectsForcedToolUse)

    if mcpServers != nil { betas.insert("mcp-client-2025-04-04") }
    if safeguards != nil { betas.insert("dangerous-tool-use-2026-09-03") }
    if compaction != nil { betas.insert("compact-2026-09-04") }
    if let contextManagement {
      betas.insert("context-management-2025-06-27")
      if contextManagement.edits.contains(where: { $0["type"] == "compact_20260112" }) {
        betas.insert("compact-2026-01-12")
      }
    }
    if anthropicOptions.container?.skills?.isEmpty == false {
      betas.formUnion(["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"])
      let hasCodeExecution = (options.tools ?? []).contains { tool in
        if case .provider(let provider) = tool {
          return provider.id == "anthropic.code_execution_20250825" || provider.id == "anthropic.code_execution_20260120"
        }
        return false
      }
      if !hasCodeExecution {
        warnings.append(.other(message: "code execution tool is required when using skills"))
      }
    }
    if anthropicOptions.taskBudget != nil { betas.insert("task-budgets-2026-03-13") }
    if anthropicOptions.speed == "fast" { betas.insert("fast-mode-2026-02-01") }
    if thinkingDisplay == "updates" { betas.insert("thinking-display-updates-2026-08-18") }
    if blockBinding != nil { betas.insert("thinking-binding-controls-2026-08-01") }
    if anthropicOptions.fallbacks == "default" {
      betas.insert("server-side-fallback-2026-07-01")
    } else if fallbacks != nil {
      betas.insert("server-side-fallback-2026-06-01")
    }

    let args = jsonObject([
      "model": .string(modelId),
      "max_tokens": .optional(maxTokensArg),
      "temperature": .optional(temperature),
      "top_k": .optional(topK),
      "top_p": .optional(topP),
      "stop_sequences": .optional(options.stopSequences),
      "thinking": thinking,
      "output_config": outputConfig,
      "speed": .optional(anthropicOptions.speed),
      "service_tier": .optional(anthropicOptions.serviceTier),
      "inference_geo": .optional(anthropicOptions.inferenceGeo),
      "fallbacks": fallbacks,
      "cache_control": anthropicOptions.cacheControl,
      "metadata": anthropicOptions.metadata?.userId.map { ["user_id": .string($0)] },
      "mcp_servers": mcpServers,
      "container": container,
      "system": converted.prompt.system.map(JSONValue.array),
      "messages": .array(converted.prompt.messages),
      "safeguards": safeguards,
      "compaction": compaction.map { jsonObject(["type": .string($0.type), "instructions": .optional($0.instructions)]) },
      "context_management": contextManagementArg,
      "tools": tools.tools.map(JSONValue.array),
      "tool_choice": tools.toolChoice,
      "stream": stream ? true : nil,
    ])

    return PreparedRequest(
      args: args.objectValue ?? [:],
      warnings: warnings + tools.warnings + validator.warnings,
      betas: betas.union(tools.betas).union(userSuppliedBetas).union(anthropicOptions.anthropicBeta ?? []),
      usesJsonResponseTool: jsonResponseTool != nil,
      toolNameMapping: toolNameMapping,
      usedCustomProviderKey: usedCustomProviderKey)
  }

  private func contextManagementEdit(_ edit: JSONObject, warnings: inout [SharedV4Warning]) -> JSONValue? {
    let type = edit["type"]?.stringValue ?? ""
    switch type {
    case "clear_tool_uses_20250919":
      return jsonObject([
        "type": .string(type), "trigger": edit["trigger"], "keep": edit["keep"], "clear_at_least": edit["clearAtLeast"],
        "clear_tool_inputs": edit["clearToolInputs"], "exclude_tools": edit["excludeTools"],
      ])
    case "clear_thinking_20251015":
      return jsonObject(["type": .string(type), "keep": edit["keep"]])
    case "compact_20260112":
      return jsonObject([
        "type": .string(type), "trigger": edit["trigger"], "pause_after_compaction": edit["pauseAfterCompaction"],
        "instructions": edit["instructions"],
      ])
    default:
      warnings.append(.other(message: "Unknown context management strategy: \(type)"))
      return nil
    }
  }

  private func resolveReasoning(
    _ reasoning: LanguageModelV4ReasoningEffort, capabilities: AnthropicModelCapabilities,
    warnings: inout [SharedV4Warning]
  ) -> (thinking: AnthropicOptions.Thinking?, effort: String?)? {
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
    return budget.map { (AnthropicOptions.Thinking(type: "enabled", budgetTokens: $0), nil) }
  }

  private func userSuppliedBetas(_ requestHeaders: [String: String]?) throws -> Set<String> {
    var betas = Set<String>()
    for source in [try config.headers(), requestHeaders ?? [:]] {
      for (name, value) in source where name.lowercased() == "anthropic-beta" {
        for beta in value.lowercased().split(separator: ",") {
          let trimmed = beta.trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty { betas.insert(trimmed) }
        }
      }
    }
    return betas
  }

  private func headers(betas: Set<String>, requestHeaders: [String: String]?) throws -> [String: String] {
    combineHeaders(
      try config.headers(), requestHeaders,
      betas.isEmpty ? [:] : ["anthropic-beta": betas.sorted().joined(separator: ",")])
  }

  private func requestURL(stream: Bool) -> String {
    config.buildRequestURL?(config.baseURL, stream) ?? "\(config.baseURL)/messages"
  }

  private func requestBody(_ args: JSONObject, betas: Set<String>) -> JSONValue {
    .object(config.transformRequestBody?(args, betas) ?? args)
  }

  /// Documents in the prompt that citations can refer to. Mirrors upstream `extractCitationDocuments`.
  private func citationDocuments(_ prompt: LanguageModelV4Prompt) -> [AnthropicCitationDocument] {
    prompt.flatMap { message -> [AnthropicCitationDocument] in
      guard case .user(let parts, _) = message else { return [] }
      return parts.compactMap { part in
        guard case .file(let file) = part, file.mediaType == "application/pdf" || file.mediaType == "text/plain",
          file.providerOptions?["anthropic"]?["citations"]?["enabled"]?.boolValue == true
        else { return nil }
        return AnthropicCitationDocument(
          title: file.filename ?? "Untitled Document", filename: file.filename, mediaType: file.mediaType)
      }
    }
  }

  // MARK: - Generate

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let request = try prepareRequest(options, stream: false, userSuppliedBetas: try userSuppliedBetas(options.headers))
    let response = try await postJsonToApi(
      url: requestURL(stream: false),
      headers: try headers(betas: request.betas, requestHeaders: options.headers),
      body: requestBody(request.args, betas: request.betas),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(JSONValue.self),
      httpClient: config.httpClient)

    let body = response.value
    let markCodeExecutionDynamic = hasDynamicFilteringWebToolWithoutCodeExecution(request.args["tools"]?.arrayValue)
    let toolNameMapping = request.toolNameMapping
    var converter = AnthropicContentConverter(
      toolNameMapping: toolNameMapping, generateId: config.generateId,
      citationDocuments: citationDocuments(options.prompt))
    var content: [LanguageModelV4Content] = []
    var isJsonResponseFromTool = false

    for block in body["content"]?.arrayValue ?? [] {
      switch block["type"]?.stringValue {
      case "text":
        guard !request.usesJsonResponseTool else { continue }
        let citations = (block["citations"]?.arrayValue ?? []).map(normalizeCitation)
        let webCitations = citations.filter { $0["type"] == "web_search_result_location" }
        content.append(
          .text(
            LanguageModelV4Text(
              text: block["text"]?.stringValue ?? "",
              providerMetadata: webCitations.isEmpty ? nil : ["anthropic": ["citations": .array(webCitations)]])))
        for citation in citations {
          if let source = createCitationSource(
            citation, documents: converter.citationDocuments, generateId: config.generateId)
          {
            content.append(.source(source))
          }
        }
      case "thinking":
        content.append(
          .reasoning(
            LanguageModelV4Reasoning(
              text: block["thinking"]?.stringValue ?? "",
              providerMetadata: ["anthropic": jsonObject(["signature": block["signature"]]).objectValue ?? [:]])))
      case "redacted_thinking":
        content.append(
          .reasoning(
            LanguageModelV4Reasoning(
              text: "", providerMetadata: ["anthropic": ["redactedData": block["data"] ?? .null]])))
      case "container_upload":
        content.append(
          .custom(
            LanguageModelV4CustomContent(
              kind: "anthropic.container_upload", providerMetadata: ["anthropic": ["fileId": block["file_id"] ?? .null]])))
      case "compaction":
        guard let text = block["content"]?.stringValue, !text.isEmpty else { continue }
        content.append(
          .text(
            LanguageModelV4Text(
              text: text,
              providerMetadata: [
                "anthropic": jsonObject([
                  "type": "compaction", "signature": block["signature"].flatMap { $0.isNull ? nil : $0 },
                ]).objectValue ?? [:]
              ])))
      case "tool_use":
        let name = block["name"]?.stringValue ?? ""
        if request.usesJsonResponseTool && name == "json" {
          isJsonResponseFromTool = true
          content.append(.text(LanguageModelV4Text(text: (block["input"] ?? .null).jsonString())))
        } else if let toolset = block["toolset_name"]?.stringValue {
          var metadata: JSONObject = ["toolsetName": .string(toolset)]
          if let caller = anthropicCallerInfo(block["caller"]) { metadata["caller"] = caller }
          content.append(
            .toolCall(
              LanguageModelV4ToolCall(
                toolCallId: block["id"]?.stringValue ?? "", toolName: toolNameMapping.toCustomToolName(toolset),
                input: toolsetMemberInput(memberName: name, input: block["input"]).jsonString(),
                providerMetadata: ["anthropic": metadata])))
        } else {
          content.append(
            .toolCall(
              LanguageModelV4ToolCall(
                toolCallId: block["id"]?.stringValue ?? "", toolName: name,
                input: (block["input"] ?? .null).jsonString(), providerMetadata: anthropicCallerMetadata(block["caller"]))))
        }
      case "server_tool_use":
        if let call = serverToolCall(
          block, toolNameMapping: toolNameMapping, markCodeExecutionDynamic: markCodeExecutionDynamic,
          converter: &converter)
        {
          content.append(.toolCall(call))
        }
      default:
        if let parts = converter.convert(block) {
          content += parts
        }
      }
    }

    let usageJSON = body["usage"]?.objectValue ?? [:]
    let rawUsage = normalizeRawUsage(usageJSON)
    let usage = (try? JSONValue.object(usageJSON).decode(as: AnthropicUsage.self)) ?? AnthropicUsage()
    let metadata = jsonObject([
      "usage": .object(rawUsage),
      "stopSequence": body["stop_sequence"] ?? .null,
      "stopDetails": anthropicStopDetailsMetadata(body["stop_details"]),
      "inputTransformations": normalizeInputTransformations(body["input_transformations"]),
      "safeguardResults": normalizeSafeguardResults(body["safeguard_results"]),
      "iterations": anthropicIterationsMetadata(usageJSON["iterations"]),
      "container": anthropicContainerMetadata(body["container"]),
      "contextManagement": anthropicContextManagementMetadata(body["context_management"]) ?? .null,
    ])
    let stopReason = body["stop_reason"]?.stringValue

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapAnthropicStopReason(stopReason, isJsonResponseFromTool: isJsonResponseFromTool), raw: stopReason),
      usage: convertAnthropicUsage(usage, raw: rawUsage),
      providerMetadata: providerMetadata(metadata.objectValue ?? [:], usedCustomProviderKey: request.usedCustomProviderKey),
      request: LanguageModelV4RequestInfo(body: .object(request.args)),
      response: LanguageModelV4ResponseInfo(
        metadata: LanguageModelV4ResponseMetadata(id: body["id"]?.stringValue, modelId: body["model"]?.stringValue),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: request.warnings)
  }

  func providerMetadata(_ metadata: JSONObject, usedCustomProviderKey: Bool) -> SharedV4ProviderMetadata {
    var result: SharedV4ProviderMetadata = ["anthropic": metadata]
    if usedCustomProviderKey && providerOptionsName != "anthropic" { result[providerOptionsName] = metadata }
    return result
  }

  // MARK: - Stream

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let request = try prepareRequest(options, stream: true, userSuppliedBetas: try userSuppliedBetas(options.headers))
    let url = requestURL(stream: true)
    let response = try await postJsonToApi(
      url: url,
      headers: try headers(betas: request.betas, requestHeaders: options.headers),
      body: requestBody(request.args, betas: request.betas),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(JSONValue.self),
      httpClient: config.httpClient)

    let state = AnthropicStreamState(
      usesJsonResponseTool: request.usesJsonResponseTool, includeRawChunks: options.includeRawChunks == true,
      generateId: config.generateId, toolNameMapping: request.toolNameMapping,
      citationDocuments: citationDocuments(options.prompt),
      markCodeExecutionDynamic: hasDynamicFilteringWebToolWithoutCodeExecution(request.args["tools"]?.arrayValue),
      providerMetadata: { providerMetadata($0, usedCustomProviderKey: request.usedCustomProviderKey) })

    // A stream that opens with an error is surfaced as an `APICallError`
    // so that retries apply, as upstream does.
    var iterator = response.value.makeAsyncIterator()
    var firstParts: [LanguageModelV4StreamPart] = []
    while let chunk = try await iterator.next() {
      state.process(chunk) { firstParts.append($0) }
      if let error = firstParts.lazy.compactMap({ part -> ProviderStreamError? in
        if case .error(let error as ProviderStreamError) = part { error } else { nil }
      }).first {
        throw APICallError(
          message: error.message, url: url, requestBodyValues: .object(request.args),
          statusCode: error.statusCode ?? 500, responseHeaders: response.responseHeaders,
          responseBody: error.data?.jsonString(), isRetryable: error.isRetryable ?? false, data: error.data)
      }
      if firstParts.contains(where: { if case .raw = $0 { false } else { true } }) { break }
    }

    let warnings = request.warnings
    let remaining = iterator
    let buffered = firstParts
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      var iterator = remaining
      continuation.yield(.streamStart(warnings: warnings))
      for part in buffered { continuation.yield(part) }
      do {
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

/// A provider-executed tool call from a `server_tool_use` block. Mirrors the
/// `server_tool_use` case of upstream `doGenerate`.
func serverToolCall(
  _ block: JSONValue, toolNameMapping: ToolNameMapping, markCodeExecutionDynamic: Bool,
  converter: inout AnthropicContentConverter
) -> LanguageModelV4ToolCall? {
  let id = block["id"]?.stringValue ?? ""
  let name = block["name"]?.stringValue ?? ""
  let caller = anthropicCallerMetadata(block["caller"])
  let input = block["input"] ?? .null
  switch name {
  case "text_editor_code_execution", "bash_code_execution":
    var object = input.objectValue ?? [:]
    object["type"] = .string(name)
    return LanguageModelV4ToolCall(
      toolCallId: id, toolName: toolNameMapping.toCustomToolName("code_execution"), input: JSONValue.object(object).jsonString(),
      providerExecuted: true, dynamic: markCodeExecutionDynamic ? true : nil, providerMetadata: caller)
  case "web_search", "code_execution", "web_fetch":
    var serialized = input
    if name == "code_execution", var object = input.objectValue, object["code"] != nil, object["type"] == nil {
      object["type"] = "programmatic-tool-call"
      serialized = .object(object)
    }
    return LanguageModelV4ToolCall(
      toolCallId: id, toolName: toolNameMapping.toCustomToolName(name), input: serialized.jsonString(),
      providerExecuted: true, dynamic: markCodeExecutionDynamic && name == "code_execution" ? true : nil,
      providerMetadata: caller)
  case "tool_search_tool_regex", "tool_search_tool_bm25":
    converter.serverToolCalls[id] = name
    return LanguageModelV4ToolCall(
      toolCallId: id, toolName: toolNameMapping.toCustomToolName(name), input: input.jsonString(),
      providerExecuted: true, providerMetadata: caller)
  case "advisor":
    return LanguageModelV4ToolCall(
      toolCallId: id, toolName: toolNameMapping.toCustomToolName("advisor"), input: input.jsonString(),
      providerExecuted: true, providerMetadata: caller)
  default:
    return nil
  }
}

private func formatNumber(_ value: Double) -> String {
  value.rounded() == value ? String(Int(value)) : String(value)
}
