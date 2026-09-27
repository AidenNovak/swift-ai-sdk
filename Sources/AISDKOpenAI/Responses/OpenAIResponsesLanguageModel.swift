import AISDKProviderUtils
import Foundation

private let openaiProviderToolNames: [String: String] = [
  "openai.code_interpreter": "code_interpreter",
  "openai.computer": "computer",
  "openai.file_search": "file_search",
  "openai.image_generation": "image_generation",
  "openai.local_shell": "local_shell",
  "openai.shell": "shell",
  "openai.web_search": "web_search",
  "openai.web_search_preview": "web_search_preview",
  "openai.mcp": "mcp",
  "openai.apply_patch": "apply_patch",
  "openai.tool_search": "tool_search",
  "openai.programmatic_tool_calling": "programmatic_tool_calling",
]

/// Everything `doGenerate` and `doStream` need from request preparation.
struct OpenAIResponsesRequest {
  var args: JSONObject
  var warnings: [SharedV4Warning]
  var webSearchToolName: String?
  var store: Bool?
  var toolNameMapping: ToolNameMapping
  var providerOptionsName: String
  var isShellProviderExecuted: Bool
}

/// Maps MCP approval request IDs in the prompt to the tool call IDs the SDK
/// generated for them. Mirrors upstream `extractApprovalRequestIdToToolCallIdMapping`.
func extractApprovalRequestIdToToolCallIdMapping(_ prompt: LanguageModelV4Prompt) -> [String: String] {
  var mapping: [String: String] = [:]
  for case .assistant(let content, _) in prompt {
    for case .toolCall(let call) in content {
      if let approvalRequestId = call.providerOptions?["openai"]?["approvalRequestId"]?.stringValue {
        mapping[approvalRequestId] = call.toolCallId
      }
    }
  }
  return mapping
}

private func mapComputerAction(_ action: JSONValue) -> JSONValue {
  switch action["type"]?.stringValue {
  case "click":
    return jsonObject(["type": "click", "button": action["button"], "x": action["x"], "y": action["y"], "keys": action["keys"]])
  case "double_click":
    return jsonObject(["type": "double_click", "x": action["x"], "y": action["y"], "keys": action["keys"]])
  case "drag":
    return jsonObject(["type": "drag", "path": action["path"], "keys": action["keys"]])
  case "move":
    return jsonObject(["type": "move", "x": action["x"], "y": action["y"], "keys": action["keys"]])
  case "scroll":
    return jsonObject([
      "type": "scroll", "x": action["x"], "y": action["y"], "scrollX": action["scroll_x"], "scrollY": action["scroll_y"],
      "keys": action["keys"],
    ])
  default:
    return action
  }
}

/// Mirrors upstream `mapComputerCallInput`.
func mapComputerCallInput(_ item: JSONValue) -> JSONValue {
  let actions = item["actions"]?.arrayValue ?? item["action"].flatMap { $0 == .null ? nil : [$0] } ?? []
  let safetyChecks = (item["pending_safety_checks"]?.arrayValue ?? []).map {
    jsonObject([
      "id": $0["id"], "code": $0["code"].flatMap { $0 == .null ? nil : $0 },
      "message": $0["message"].flatMap { $0 == .null ? nil : $0 },
    ])
  }
  return [
    "actions": .array(actions.map(mapComputerAction)), "pendingSafetyChecks": .array(safetyChecks),
    "status": item["status"] ?? .null,
  ]
}

/// Mirrors upstream `mapWebSearchOutput`.
func mapWebSearchOutput(_ action: JSONValue?) -> JSONValue {
  guard let action, action != .null else { return [:] }
  switch action["type"]?.stringValue {
  case "search":
    var output: JSONObject = [
      "action": jsonObject([
        "type": "search", "query": action["query"].flatMap { $0 == .null ? nil : $0 },
        "queries": action["queries"].flatMap { $0 == .null ? nil : $0 },
      ])
    ]
    if let sources = action["sources"], sources != .null { output["sources"] = sources }
    return .object(output)
  case "open_page":
    return ["action": ["type": "openPage", "url": action["url"] ?? .null]]
  case "find_in_page":
    return ["action": ["type": "findInPage", "url": action["url"] ?? .null, "pattern": action["pattern"] ?? .null]]
  default:
    return [:]
  }
}

/// Source content for a Responses annotation, or `nil` for unknown types.
func openAIResponsesSource(_ annotation: JSONValue, id: String, providerOptionsName: String) -> LanguageModelV4Source? {
  switch annotation["type"]?.stringValue {
  case "url_citation":
    return .url(id: id, url: annotation["url"]?.stringValue ?? "", title: annotation["title"]?.stringValue)
  case "file_citation":
    return .document(
      id: id, mediaType: "text/plain", title: annotation["filename"]?.stringValue ?? "",
      filename: annotation["filename"]?.stringValue,
      providerMetadata: [
        providerOptionsName: jsonObject([
          "type": "file_citation", "fileId": annotation["file_id"], "index": annotation["index"],
        ]).objectValue ?? [:]
      ])
  case "container_file_citation":
    return .document(
      id: id, mediaType: "text/plain", title: annotation["filename"]?.stringValue ?? "",
      filename: annotation["filename"]?.stringValue,
      providerMetadata: [
        providerOptionsName: jsonObject([
          "type": "container_file_citation", "fileId": annotation["file_id"], "containerId": annotation["container_id"],
        ]).objectValue ?? [:]
      ])
  case "file_path":
    return .document(
      id: id, mediaType: "application/octet-stream", title: annotation["file_id"]?.stringValue ?? "",
      filename: annotation["file_id"]?.stringValue,
      providerMetadata: [
        providerOptionsName: jsonObject(["type": "file_path", "fileId": annotation["file_id"], "index": annotation["index"]])
          .objectValue ?? [:]
      ])
  default:
    return nil
  }
}

private func contextManagementJSON(_ entries: [OpenAIResponsesOptions.ContextManagement]) -> JSONValue {
  .array(
    entries.map { entry -> JSONValue in
      var object: JSONObject = [:]
      object["type"] = .string(entry.type)
      object["compact_threshold"] = .number(entry.compactThreshold)
      return .object(object)
    })
}

/// Mirrors upstream `getConfigurationUpdateUnsupportedReason`.
private func configurationUpdateUnsupportedReason(
  _ capabilities: OpenAILanguageModelCapabilities, _ options: OpenAIResponsesOptions?
) -> String? {
  if !capabilities.supportsConfigurationUpdate {
    return "reasoningEffortUpdate is only supported by GPT-6 and later models"
  }
  if options?.reasoningMode == "pro" || options?.contextManagement != nil || options?.truncation == "auto" {
    return
      "reasoningEffortUpdate requires standard reasoning mode without automatic compaction or automatic truncation"
  }
  return nil
}

/// An OpenAI Responses API model (`POST /responses`). This is the default
/// OpenAI model. Mirrors upstream `OpenAIResponsesLanguageModel`.
public struct OpenAIResponsesLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: OpenAIConfig

  public init(modelId: String, config: OpenAIConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { config.provider }

  public var supportedUrls: [String: [String]] {
    get async throws { ["image/*": ["^https?://.*$"], "application/pdf": ["^https?://.*$"]] }
  }

  // swiftlint:disable:next function_body_length
  func prepareRequest(_ options: LanguageModelV4CallOptions) throws -> OpenAIResponsesRequest {
    var warnings: [SharedV4Warning] = []
    let capabilities = getOpenAILanguageModelCapabilities(modelId)

    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.seed != nil { warnings.append(.unsupported(feature: "seed")) }
    if options.presencePenalty != nil { warnings.append(.unsupported(feature: "presencePenalty")) }
    if options.frequencyPenalty != nil { warnings.append(.unsupported(feature: "frequencyPenalty")) }
    if options.stopSequences != nil { warnings.append(.unsupported(feature: "stopSequences")) }

    let providerOptionsName = config.provider.contains("azure") ? "azure" : "openai"
    var openaiOptions = try parseProviderOptions(
      provider: providerOptionsName, providerOptions: options.providerOptions, as: OpenAIResponsesOptions.self)
    if openaiOptions == nil, providerOptionsName != "openai" {
      openaiOptions = try parseProviderOptions(
        provider: "openai", providerOptions: options.providerOptions, as: OpenAIResponsesOptions.self)
    }
    try openaiOptions?.validate()

    var reasoningEffort =
      openaiOptions?.reasoningEffort ?? (isCustomReasoning(options.reasoning) ? options.reasoning?.rawValue : nil)
    if let effort = reasoningEffort, let supported = capabilities.supportedReasoningEfforts, !supported.contains(effort) {
      warnings.append(
        .unsupported(
          feature: "reasoningEffort",
          details: "\(modelId) only supports the following reasoning efforts: \(supported.joined(separator: ", "))"))
      reasoningEffort = nil
    }
    let reasoningSummary: String? =
      openaiOptions?.reasoningSummary ?? (reasoningEffort != nil && reasoningEffort != "none" ? "detailed" : nil)
    let isReasoningModel = openaiOptions?.forceReasoning ?? capabilities.isReasoningModel

    if openaiOptions?.conversation != nil, openaiOptions?.previousResponseId != nil {
      warnings.append(
        .unsupported(feature: "conversation", details: "conversation and previousResponseId cannot be used together"))
    }

    let tools = options.tools
    let toolNameMapping = ToolNameMapping(tools: tools, providerToolNames: openaiProviderToolNames)
    func openAIToolName(_ id: String) -> String? {
      for case .provider(let tool) in tools ?? [] where tool.id == id { return tool.name }
      return nil
    }

    let prepared = try prepareOpenAIResponsesTools(
      tools: tools, toolChoice: options.toolChoice, allowedTools: openaiOptions?.allowedTools,
      toolNameMapping: toolNameMapping, supportsAsyncToolCalling: capabilities.supportsAsyncToolCalling)

    let updateUnsupportedReason = configurationUpdateUnsupportedReason(capabilities, openaiOptions)
    var converted = try convertToOpenAIResponsesInput(
      options.prompt,
      options: OpenAIResponsesInputOptions(
        toolNameMapping: toolNameMapping,
        systemMessageMode: openaiOptions?.systemMessageMode
          ?? (isReasoningModel ? .developer : capabilities.systemMessageMode),
        providerOptionsName: providerOptionsName,
        explicitMessageItemType: config.explicitMessageItemType,
        fileIdPrefixes: config.fileIdPrefixes,
        passThroughUnsupportedFiles: openaiOptions?.passThroughUnsupportedFiles ?? false,
        store: openaiOptions?.store ?? true,
        hasConversation: openaiOptions?.conversation != nil,
        hasPreviousResponseId: openaiOptions?.previousResponseId != nil,
        hasLocalShellTool: openAIToolName("openai.local_shell") != nil,
        hasShellTool: openAIToolName("openai.shell") != nil,
        hasApplyPatchTool: openAIToolName("openai.apply_patch") != nil,
        hasComputerTool: openAIToolName("openai.computer") != nil,
        toolSearchToolName: openAIToolName("openai.tool_search"),
        customProviderToolNames: prepared.customToolNames,
        outputSchemaToolNames: prepared.outputSchemaToolNames,
        configurationUpdateUnsupportedReason: updateUnsupportedReason))
    warnings += converted.warnings

    func updateEffortUnsupportedReason(_ effort: String?) -> String? {
      guard let effort, let supported = capabilities.supportedReasoningEfforts, !supported.contains(effort) else {
        return nil
      }
      return "\(modelId) only supports the following reasoning efforts: \(supported.joined(separator: ", "))"
    }

    for item in converted.input where item["type"]?.stringValue == "configuration_update" {
      if let reason = updateEffortUnsupportedReason(item["reasoning"]?["effort"]?.stringValue) {
        throw UnsupportedFunctionalityError(functionality: "Message-level reasoningEffortUpdate", message: reason)
      }
    }

    if let effortUpdate = openaiOptions?.reasoningEffortUpdate {
      if let reason = updateUnsupportedReason ?? updateEffortUnsupportedReason(effortUpdate) {
        warnings.append(.unsupported(feature: "reasoningEffortUpdate", details: reason))
      } else {
        let first = converted.input.first
        if first?["type"]?.stringValue != "configuration_update"
          || first?["reasoning"]?["effort"]?.stringValue != effortUpdate
        {
          converted.input.insert(["type": "configuration_update", "reasoning": ["effort": .string(effortUpdate)]], at: 0)
        }
      }
    }

    for index in converted.input.indices.dropFirst()
    where converted.input[index - 1]["type"]?.stringValue == "configuration_update"
      && converted.input[index]["type"]?.stringValue == "configuration_update"
    {
      throw UnsupportedFunctionalityError(functionality: "Adjacent reasoning effort configuration updates")
    }

    if openaiOptions?.compactionTrigger == true {
      converted.input.append(["type": "compaction_trigger"])
    }

    var responseFormatSchema: JSONSchema?
    if case .json(let schema?, _, _)? = options.responseFormat {
      let normalized = try normalizeOpenAIJsonSchema(schema)
      warnings += normalized.warnings
      responseFormatSchema = normalized.schema
    }

    var include = openaiOptions?.include
    func addInclude(_ key: String) {
      if include == nil {
        include = [key]
      } else if include?.contains(key) == false {
        include?.append(key)
      }
    }

    let topLogprobs: Int? =
      switch openaiOptions?.logprobs {
      case .top(let count)?: count
      case .enabled(true)?: OPENAI_RESPONSES_TOP_LOGPROBS_MAX
      default: nil
      }
    if let topLogprobs, topLogprobs > 0 { addInclude("message.output_text.logprobs") }

    let webSearchToolName: String? = {
      for case .provider(let tool) in tools ?? []
      where tool.id == "openai.web_search" || tool.id == "openai.web_search_preview" {
        return tool.name
      }
      return nil
    }()
    if webSearchToolName != nil, config.supportsWebSearchSourcesInclude, openaiOptions?.includeWebSearchSources != false {
      addInclude("web_search_call.action.sources")
    }
    if openAIToolName("openai.code_interpreter") != nil { addInclude("code_interpreter_call.outputs") }

    let store = openaiOptions?.store
    if store == false && isReasoningModel { addInclude("reasoning.encrypted_content") }

    var text: JSONObject = [:]
    if case .json(_, let name, let description)? = options.responseFormat {
      text["format"] =
        responseFormatSchema.map {
          jsonObject([
            "type": "json_schema", "strict": .bool(openaiOptions?.strictJsonSchema ?? true),
            "name": .string(name ?? "response"), "description": .optional(description), "schema": $0.value,
          ])
        } ?? ["type": "json_object"]
    }
    if let verbosity = openaiOptions?.textVerbosity { text["verbosity"] = .string(verbosity) }

    var reasoning: JSONObject = [:]
    if isReasoningModel {
      if let reasoningEffort { reasoning["effort"] = .string(reasoningEffort) }
      if let reasoningSummary { reasoning["summary"] = .string(reasoningSummary) }
      if let mode = openaiOptions?.reasoningMode { reasoning["mode"] = .string(mode) }
      if let context = openaiOptions?.reasoningContext { reasoning["context"] = .string(context) }
    }

    var args: JSONObject =
      jsonObject([
        "model": .string(modelId),
        "input": .array(converted.input),
        "temperature": .optional(options.temperature),
        "top_p": .optional(options.topP),
        "max_output_tokens": .optional(options.maxOutputTokens),
        "text": text.isEmpty ? nil : .object(text),
        "conversation": .optional(openaiOptions?.conversation),
        "max_tool_calls": .optional(openaiOptions?.maxToolCalls),
        "metadata": openaiOptions?.metadata,
        "parallel_tool_calls": .optional(openaiOptions?.parallelToolCalls),
        "previous_response_id": .optional(openaiOptions?.previousResponseId),
        "store": .optional(store),
        "user": .optional(openaiOptions?.user),
        "instructions": .optional(openaiOptions?.instructions),
        "service_tier": .optional(openaiOptions?.serviceTier),
        "include": include.map { .array($0.map(JSONValue.string)) },
        "prompt_cache_key": .optional(openaiOptions?.promptCacheKey),
        "prompt_cache_options": openaiOptions?.promptCacheOptions.map {
          jsonObject(["mode": .optional($0.mode), "ttl": .optional($0.ttl)])
        },
        "prompt_cache_retention": .optional(openaiOptions?.promptCacheRetention),
        "safety_identifier": .optional(openaiOptions?.safetyIdentifier),
        "top_logprobs": .optional(topLogprobs),
        "truncation": .optional(openaiOptions?.truncation),
        "context_management": openaiOptions?.contextManagement.map(contextManagementJSON),
        "reasoning": reasoning.isEmpty ? nil : .object(reasoning),
      ]).objectValue ?? [:]

    if capabilities.supportsConfigurationUpdate, args.removeValue(forKey: "prompt_cache_retention") != nil {
      warnings.append(
        .unsupported(
          feature: "promptCacheRetention",
          details: "promptCacheRetention is not supported by GPT-6 and later models; use promptCacheOptions instead"))
    }

    if isReasoningModel {
      if !(reasoningEffort == "none" && capabilities.supportsNonReasoningParameters) {
        if args.removeValue(forKey: "temperature") != nil {
          warnings.append(.unsupported(feature: "temperature", details: "temperature is not supported for reasoning models"))
        }
        if args.removeValue(forKey: "top_p") != nil {
          warnings.append(.unsupported(feature: "topP", details: "topP is not supported for reasoning models"))
        }
        let includesLogprobs = include?.contains("message.output_text.logprobs") == true
        if capabilities.supportedReasoningEfforts != nil, args["top_logprobs"] != nil || includesLogprobs {
          args["top_logprobs"] = nil
          let filtered = (include ?? []).filter { $0 != "message.output_text.logprobs" }
          args["include"] = filtered.isEmpty ? nil : .array(filtered.map(JSONValue.string))
          warnings.append(.unsupported(feature: "logprobs", details: "logprobs is not supported for reasoning models"))
        }
      }
    } else {
      for (value, feature) in [
        (openaiOptions?.reasoningEffort, "reasoningEffort"), (openaiOptions?.reasoningSummary, "reasoningSummary"),
        (openaiOptions?.reasoningMode, "reasoningMode"), (openaiOptions?.reasoningContext, "reasoningContext"),
      ] where value != nil {
        warnings.append(.unsupported(feature: feature, details: "\(feature) is not supported for non-reasoning models"))
      }
    }

    if openaiOptions?.serviceTier == "flex", !capabilities.supportsFlexProcessing {
      warnings.append(
        .unsupported(feature: "serviceTier", details: "flex processing is only available for o3, o4-mini, and gpt-5 models"))
      args["service_tier"] = nil
    }
    if openaiOptions?.serviceTier == "priority" || openaiOptions?.serviceTier == "fast",
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

    var shellEnvironmentType: String?
    for case .provider(let tool) in tools ?? [] where tool.id == "openai.shell" {
      shellEnvironmentType = tool.args["environment"]?["type"]?.stringValue
    }

    if let tools = prepared.tools { args["tools"] = tools }
    if let toolChoice = prepared.toolChoice { args["tool_choice"] = toolChoice }

    return OpenAIResponsesRequest(
      args: args, warnings: warnings + prepared.warnings, webSearchToolName: webSearchToolName, store: store,
      toolNameMapping: toolNameMapping, providerOptionsName: providerOptionsName,
      isShellProviderExecuted: shellEnvironmentType == "containerAuto" || shellEnvironmentType == "containerReference")
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let request = try prepareRequest(options)
    let body = request.args
    let url = config.url("/responses")
    let approvalMapping = extractApprovalRequestIdToToolCallIdMapping(options.prompt)
    let name = request.providerOptionsName
    let mapping = request.toolNameMapping

    let response = try await postJsonToApi(
      url: url, headers: combineHeaders(try config.headers(), options.headers), body: .object(body),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(JSONValue.self), httpClient: config.httpClient)
    let value = response.value
    let rawBody = response.rawValue?.jsonString(sortedKeys: false)

    if let error = value["error"], error != .null {
      throw APICallError(
        message: error["message"]?.stringValue ?? "Responses API error", url: url, requestBodyValues: .object(body),
        statusCode: 400, responseHeaders: response.responseHeaders, responseBody: rawBody, isRetryable: false)
    }
    guard case .array(let output)? = value["output"] else {
      let detail = value["incomplete_details"]?["reason"]?.stringValue
      throw APICallError(
        message: detail.map { "Responses API returned no output (\($0))" } ?? "Responses API returned no output",
        url: url, requestBodyValues: .object(body), statusCode: 500, responseHeaders: response.responseHeaders,
        responseBody: rawBody, isRetryable: false)
    }

    var content: [LanguageModelV4Content] = []
    var logprobs: [JSONValue] = []
    let functionTools = (options.tools ?? []).compactMap { tool -> LanguageModelV4FunctionTool? in
      if case .function(let function) = tool { return function }
      return nil
    }
    let wantsLogprobs = options.providerOptions?[name]?["logprobs"].map { $0 != .bool(false) && $0 != .null } ?? false
    var hasFunctionCall = false
    var hostedToolSearchCallIds: [String] = []
    let webSearchName = mapping.toCustomToolName(request.webSearchToolName ?? "web_search")

    func itemMetadata(_ item: JSONValue) -> SharedV4ProviderMetadata {
      [name: ["itemId": item["id"] ?? .null]]
    }

    for part in output {
      let id = part["id"]?.stringValue ?? ""
      let callId = part["call_id"]?.stringValue
      switch part["type"]?.stringValue {
      case "reasoning":
        var summaries = part["summary"]?.arrayValue ?? []
        if summaries.isEmpty { summaries = [["type": "summary_text", "text": ""]] }
        for summary in summaries {
          content.append(
            .reasoning(
              LanguageModelV4Reasoning(
                text: summary["text"]?.stringValue ?? "",
                providerMetadata: [
                  name: ["itemId": .string(id), "reasoningEncryptedContent": part["encrypted_content"] ?? .null]
                ])))
        }

      case "image_generation_call":
        let toolName = mapping.toCustomToolName("image_generation")
        content.append(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: toolName, input: "{}", providerExecuted: true)))
        content.append(
          .toolResult(LanguageModelV4ToolResult(toolCallId: id, toolName: toolName, result: ["result": part["result"] ?? .null])))

      case "tool_search_call":
        let toolCallId = callId ?? id
        let isHosted = part["execution"]?.stringValue == "server"
        if isHosted { hostedToolSearchCallIds.append(toolCallId) }
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: toolCallId, toolName: mapping.toCustomToolName("tool_search"),
              input: jsonObject(["arguments": part["arguments"], "call_id": part["call_id"]]).jsonString(),
              providerExecuted: isHosted ? true : nil, providerMetadata: itemMetadata(part))))

      case "tool_search_output":
        let toolCallId = callId ?? (hostedToolSearchCallIds.isEmpty ? nil : hostedToolSearchCallIds.removeFirst()) ?? id
        content.append(
          .toolResult(
            LanguageModelV4ToolResult(
              toolCallId: toolCallId, toolName: mapping.toCustomToolName("tool_search"),
              result: ["tools": part["tools"] ?? []], providerMetadata: itemMetadata(part))))

      case "local_shell_call":
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("local_shell"),
              input: ["action": part["action"] ?? .null], providerMetadata: itemMetadata(part))))

      case "shell_call":
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("shell"),
              input: ["action": ["commands": part["action"]?["commands"] ?? []]],
              providerExecuted: request.isShellProviderExecuted ? true : nil, providerMetadata: itemMetadata(part))))

      case "shell_call_output":
        content.append(
          .toolResult(
            LanguageModelV4ToolResult(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("shell"),
              result: ["output": .array((part["output"]?.arrayValue ?? []).map(mapShellOutputItem))])))

      case "message":
        for contentPart in part["content"]?.arrayValue ?? [] {
          if wantsLogprobs, let partLogprobs = contentPart["logprobs"], partLogprobs != .null {
            logprobs.append(partLogprobs)
          }
          let annotations = contentPart["annotations"]?.arrayValue ?? []
          var metadata: JSONObject = ["itemId": .string(id)]
          if let phase = part["phase"], phase != .null { metadata["phase"] = phase }
          if !annotations.isEmpty { metadata["annotations"] = .array(annotations) }
          content.append(
            .text(LanguageModelV4Text(text: contentPart["text"]?.stringValue ?? "", providerMetadata: [name: metadata])))
          for annotation in annotations {
            if let source = openAIResponsesSource(annotation, id: config.generateId(), providerOptionsName: name) {
              content.append(.source(source))
            }
          }
        }

      case "function_call":
        hasFunctionCall = true
        let toolCallId = callId ?? id
        let toolName = part["name"]?.stringValue ?? ""
        let arguments = part["arguments"]?.stringValue ?? ""
        if let expanded = expandParallelToolCall(
          toolCallId: toolCallId, toolName: toolName, input: arguments, tools: functionTools, providerOptionsName: name,
          itemId: id)
        {
          content += expanded.map(LanguageModelV4Content.toolCall)
          break
        }
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: toolCallId, toolName: toolName, input: arguments,
              providerMetadata: [name: functionCallMetadata(part, async: nil)])))

      case "program":
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("programmatic_tool_calling"),
              input: ["code": part["code"] ?? .null, "fingerprint": part["fingerprint"] ?? .null], providerExecuted: true,
              providerMetadata: itemMetadata(part))))

      case "program_output":
        content.append(
          .toolResult(
            LanguageModelV4ToolResult(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("programmatic_tool_calling"),
              result: ["result": part["result"] ?? .null, "status": part["status"] ?? .null],
              providerMetadata: itemMetadata(part))))

      case "custom_tool_call":
        hasFunctionCall = true
        var metadata: JSONObject = ["itemId": .string(id)]
        if let async = part["async"], async != .null { metadata["async"] = async }
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName(part["name"]?.stringValue ?? ""),
              input: (part["input"] ?? .null).jsonString(), providerMetadata: [name: metadata])))

      case "web_search_call":
        content.append(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: webSearchName, input: "{}", providerExecuted: true)))
        content.append(
          .toolResult(LanguageModelV4ToolResult(toolCallId: id, toolName: webSearchName, result: mapWebSearchOutput(part["action"]))))

      case "mcp_call":
        let toolCallId = part["approval_request_id"]?.stringValue.map { approvalMapping[$0] ?? id } ?? id
        let toolName = "mcp.\(part["name"]?.stringValue ?? "")"
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: toolCallId, toolName: toolName, input: part["arguments"]?.stringValue ?? "",
              providerExecuted: true, dynamic: true)))
        content.append(
          .toolResult(
            LanguageModelV4ToolResult(
              toolCallId: toolCallId, toolName: toolName, result: mcpCallResult(part), providerMetadata: itemMetadata(part))))

      case "mcp_list_tools":
        break

      case "mcp_approval_request":
        let approvalRequestId = part["approval_request_id"]?.stringValue ?? id
        let dummyToolCallId = config.generateId()
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: dummyToolCallId, toolName: "mcp.\(part["name"]?.stringValue ?? "")",
              input: part["arguments"]?.stringValue ?? "", providerExecuted: true, dynamic: true)))
        content.append(
          .toolApprovalRequest(LanguageModelV4ToolApprovalRequest(approvalId: approvalRequestId, toolCallId: dummyToolCallId)))

      case "computer_call":
        guard let callId else {
          let toolName = mapping.toCustomToolName("computer_use")
          content.append(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: toolName, input: "", providerExecuted: true)))
          content.append(
            .toolResult(
              LanguageModelV4ToolResult(
                toolCallId: id, toolName: toolName,
                result: ["type": "computer_use_tool_result", "status": part["status"] ?? .null])))
          break
        }
        hasFunctionCall = true
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId, toolName: mapping.toCustomToolName("computer"),
              input: mapComputerCallInput(part).jsonString(), providerMetadata: itemMetadata(part))))

      case "file_search_call":
        let toolName = mapping.toCustomToolName("file_search")
        content.append(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: toolName, input: "{}", providerExecuted: true)))
        content.append(.toolResult(LanguageModelV4ToolResult(toolCallId: id, toolName: toolName, result: fileSearchResult(part))))

      case "code_interpreter_call":
        let toolName = mapping.toCustomToolName("code_interpreter")
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: id, toolName: toolName,
              input: ["code": part["code"] ?? .null, "containerId": part["container_id"] ?? .null], providerExecuted: true)))
        content.append(
          .toolResult(LanguageModelV4ToolResult(toolCallId: id, toolName: toolName, result: ["outputs": part["outputs"] ?? .null])))

      case "apply_patch_call":
        hasFunctionCall = true
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId ?? id, toolName: mapping.toCustomToolName("apply_patch"),
              input: ["callId": part["call_id"] ?? .null, "operation": part["operation"] ?? .null],
              providerMetadata: itemMetadata(part))))

      case "compaction":
        content.append(
          .custom(
            LanguageModelV4CustomContent(
              kind: "openai.compaction",
              providerMetadata: [
                name: ["type": "compaction", "itemId": .string(id), "encryptedContent": part["encrypted_content"] ?? .null]
              ])))

      default:
        break
      }
    }

    var metadata: JSONObject = ["responseId": value["id"] ?? .null]
    if !logprobs.isEmpty { metadata["logprobs"] = .array(logprobs) }
    if case .string? = value["service_tier"] { metadata["serviceTier"] = value["service_tier"] }
    if let context = value["reasoning"]?["context"], context != .null { metadata["reasoningContext"] = context }

    let incompleteReason = value["incomplete_details"]?["reason"]?.stringValue
    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: LanguageModelV4FinishReason(
        unified: mapOpenAIResponseFinishReason(incompleteReason, hasFunctionCall: hasFunctionCall), raw: incompleteReason),
      usage: convertOpenAIResponsesUsage(value["usage"]),
      providerMetadata: [name: metadata],
      request: LanguageModelV4RequestInfo(body: .object(body)),
      response: LanguageModelV4ResponseInfo(
        metadata: createLanguageModelResponseMetadata(
          id: value["id"]?.stringValue, model: value["model"]?.stringValue, created: value["created_at"]?.doubleValue),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: request.warnings)
  }
}

extension LanguageModelV4ToolCall {
  /// A tool call whose input is a JSON object, serialized with sorted keys.
  init(
    toolCallId: String, toolName: String, input: JSONValue, providerExecuted: Bool? = nil,
    providerMetadata: SharedV4ProviderMetadata? = nil
  ) {
    self.init(
      toolCallId: toolCallId, toolName: toolName, input: input.jsonString(), providerExecuted: providerExecuted,
      providerMetadata: providerMetadata)
  }
}

func functionCallMetadata(_ item: JSONValue, async fallbackAsync: JSONValue?) -> JSONObject {
  var metadata: JSONObject = ["itemId": item["id"] ?? .null]
  if let async = item["async"], async != .null {
    metadata["async"] = async
  } else if let fallbackAsync, fallbackAsync != .null {
    metadata["async"] = fallbackAsync
  }
  if let namespace = item["namespace"], namespace != .null { metadata["namespace"] = namespace }
  if let caller = item["caller"], caller != .null {
    metadata["caller"] =
      caller["type"]?.stringValue == "program" ? ["type": "program", "callerId": caller["caller_id"] ?? .null] : caller
  }
  return metadata
}

func mapShellOutputItem(_ item: JSONValue) -> JSONValue {
  let outcome: JSONValue =
    item["outcome"]?["type"]?.stringValue == "exit"
    ? ["type": "exit", "exitCode": item["outcome"]?["exit_code"] ?? .null] : ["type": "timeout"]
  return ["stdout": item["stdout"] ?? "", "stderr": item["stderr"] ?? "", "outcome": outcome]
}

func mcpCallResult(_ item: JSONValue) -> JSONValue {
  var result: JSONObject = [
    "type": "call", "serverLabel": item["server_label"] ?? .null, "name": item["name"] ?? .null,
    "arguments": item["arguments"] ?? .null,
  ]
  if let output = item["output"], output != .null { result["output"] = output }
  if let error = item["error"], error != .null { result["error"] = error }
  return .object(result)
}

private func fileSearchResultEntry(_ result: JSONValue) -> JSONValue {
  var entry: JSONObject = [:]
  entry["attributes"] = result["attributes"] ?? .object([:])
  entry["fileId"] = result["file_id"] ?? .null
  entry["filename"] = result["filename"] ?? .null
  entry["score"] = result["score"] ?? .null
  entry["text"] = result["text"] ?? .null
  return .object(entry)
}

func fileSearchResult(_ item: JSONValue) -> JSONValue {
  var results: JSONValue = .null
  if let entries = item["results"]?.arrayValue {
    results = .array(entries.map(fileSearchResultEntry))
  }
  var output: JSONObject = [:]
  output["queries"] = item["queries"] ?? .array([])
  output["results"] = results
  return .object(output)
}
