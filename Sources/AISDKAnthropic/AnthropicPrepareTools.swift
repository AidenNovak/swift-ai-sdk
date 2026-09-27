import AISDKProviderUtils
import Foundation

/// Provider tool IDs and the tool names Anthropic uses for them.
let anthropicProviderToolNames: [String: String] = [
  "anthropic.code_execution_20250522": "code_execution",
  "anthropic.code_execution_20250825": "code_execution",
  "anthropic.code_execution_20260120": "code_execution",
  "anthropic.computer_20241022": "computer",
  "anthropic.computer_20250124": "computer",
  "anthropic.computer_20251124": "computer",
  "anthropic.computer_toolset_20260801": "computer",
  "anthropic.text_editor_20241022": "str_replace_editor",
  "anthropic.text_editor_20250124": "str_replace_editor",
  "anthropic.text_editor_20250429": "str_replace_based_edit_tool",
  "anthropic.text_editor_20250728": "str_replace_based_edit_tool",
  "anthropic.bash_20241022": "bash",
  "anthropic.bash_20250124": "bash",
  "anthropic.memory_20250818": "memory",
  "anthropic.web_search_20250305": "web_search",
  "anthropic.web_search_20260209": "web_search",
  "anthropic.web_search_20260318": "web_search",
  "anthropic.web_fetch_20250910": "web_fetch",
  "anthropic.web_fetch_20260209": "web_fetch",
  "anthropic.web_fetch_20260318": "web_fetch",
  "anthropic.tool_search_regex_20251119": "tool_search_tool_regex",
  "anthropic.tool_search_bm25_20251119": "tool_search_tool_bm25",
  "anthropic.advisor_20260301": "advisor",
]

private func compactObject(_ fields: [String: JSONValue?]) -> JSONValue {
  .object(fields.compactMapValues { $0 })
}

private func providerToolDefinition(_ tool: LanguageModelV4ProviderTool, betas: inout Set<String>) -> JSONValue? {
  let args = tool.args
  let web: [String: JSONValue?] = [
    "max_uses": args["maxUses"], "allowed_domains": args["allowedDomains"], "blocked_domains": args["blockedDomains"],
  ]
  let display: [String: JSONValue?] = [
    "display_width_px": args["displayWidthPx"], "display_height_px": args["displayHeightPx"],
    "display_number": args["displayNumber"],
  ]

  switch tool.id {
  case "anthropic.code_execution_20250522":
    betas.insert("code-execution-2025-05-22")
    return ["type": "code_execution_20250522", "name": "code_execution"]
  case "anthropic.code_execution_20250825":
    betas.insert("code-execution-2025-08-25")
    return ["type": "code_execution_20250825", "name": "code_execution"]
  case "anthropic.code_execution_20260120":
    return ["type": "code_execution_20260120", "name": "code_execution"]
  case "anthropic.computer_20241022":
    betas.insert("computer-use-2024-10-22")
    return compactObject(display.merging(["name": "computer", "type": "computer_20241022"]) { _, b in b })
  case "anthropic.computer_20250124":
    betas.insert("computer-use-2025-01-24")
    return compactObject(display.merging(["name": "computer", "type": "computer_20250124"]) { _, b in b })
  case "anthropic.computer_20251124":
    betas.insert("computer-use-2025-11-24")
    return compactObject(
      display.merging(["name": "computer", "type": "computer_20251124", "enable_zoom": args["enableZoom"]]) { _, b in b })
  case "anthropic.computer_toolset_20260801":
    let configs = args["configs"]?.objectValue?.mapValues { config -> JSONValue in
      jsonObject(["enabled": config["enabled"], "defer_loading": config["deferLoading"]])
    }
    return jsonObject(["type": "computer_toolset_20260801", "configs": configs.map(JSONValue.object)])
  case "anthropic.text_editor_20250124":
    betas.insert("computer-use-2025-01-24")
    return ["name": "str_replace_editor", "type": "text_editor_20250124"]
  case "anthropic.text_editor_20241022":
    betas.insert("computer-use-2024-10-22")
    return ["name": "str_replace_editor", "type": "text_editor_20241022"]
  case "anthropic.text_editor_20250429":
    betas.insert("computer-use-2025-01-24")
    return ["name": "str_replace_based_edit_tool", "type": "text_editor_20250429"]
  case "anthropic.text_editor_20250728":
    return jsonObject([
      "name": "str_replace_based_edit_tool", "type": "text_editor_20250728", "max_characters": args["maxCharacters"],
    ])
  case "anthropic.bash_20250124":
    betas.insert("computer-use-2025-01-24")
    return ["name": "bash", "type": "bash_20250124"]
  case "anthropic.bash_20241022":
    betas.insert("computer-use-2024-10-22")
    return ["name": "bash", "type": "bash_20241022"]
  case "anthropic.memory_20250818":
    betas.insert("context-management-2025-06-27")
    return ["name": "memory", "type": "memory_20250818"]
  case "anthropic.web_fetch_20250910", "anthropic.web_fetch_20260209", "anthropic.web_fetch_20260318":
    let version = String(tool.id.dropFirst("anthropic.".count))
    if version == "web_fetch_20250910" { betas.insert("web-fetch-2025-09-10") }
    if version == "web_fetch_20260209" { betas.insert("code-execution-web-tools-2026-02-09") }
    var fields = web
    fields["type"] = .string(version)
    fields["name"] = "web_fetch"
    fields["citations"] = args["citations"]
    fields["max_content_tokens"] = args["maxContentTokens"]
    if version == "web_fetch_20260318" {
      fields["use_cache"] = args["useCache"]
      fields["response_inclusion"] = args["responseInclusion"]
    }
    return compactObject(fields)
  case "anthropic.web_search_20250305", "anthropic.web_search_20260209", "anthropic.web_search_20260318":
    let version = String(tool.id.dropFirst("anthropic.".count))
    if version == "web_search_20260209" { betas.insert("code-execution-web-tools-2026-02-09") }
    var fields = web
    fields["type"] = .string(version)
    fields["name"] = "web_search"
    fields["user_location"] = args["userLocation"]
    if version == "web_search_20260318" { fields["response_inclusion"] = args["responseInclusion"] }
    return compactObject(fields)
  case "anthropic.tool_search_regex_20251119":
    return ["type": "tool_search_tool_regex_20251119", "name": "tool_search_tool_regex"]
  case "anthropic.tool_search_bm25_20251119":
    return ["type": "tool_search_tool_bm25_20251119", "name": "tool_search_tool_bm25"]
  case "anthropic.advisor_20260301":
    betas.insert("advisor-tool-2026-03-01")
    return jsonObject([
      "type": "advisor_20260301", "name": "advisor", "model": args["model"], "max_uses": args["maxUses"],
      "max_tokens": args["maxTokens"], "caching": args["caching"],
    ])
  default:
    return nil
  }
}

/// Converts tools and tool choice to the Anthropic format. Mirrors upstream `prepareTools`.
func prepareAnthropicTools(
  tools: [LanguageModelV4Tool],
  toolChoice: LanguageModelV4ToolChoice?,
  disableParallelToolUse: Bool?,
  validator: CacheControlValidator,
  supportsStructuredOutput: Bool,
  supportsStrictTools: Bool,
  eagerInputStreaming: Bool,
  rejectsForcedToolUse: Bool
) -> (tools: [JSONValue]?, toolChoice: JSONValue?, warnings: [SharedV4Warning], betas: Set<String>) {
  var warnings: [SharedV4Warning] = []
  var betas = Set<String>()
  guard !tools.isEmpty else { return (nil, nil, warnings, betas) }

  var anthropicTools: [JSONValue] = []
  for tool in tools {
    switch tool {
    case .function(let function):
      let cacheControl = validator.cacheControl(function.providerOptions, type: "tool definition")
      let anthropicOptions = function.providerOptions?["anthropic"]
      let eager = anthropicOptions?["eagerInputStreaming"]?.boolValue ?? eagerInputStreaming
      let allowedCallers = anthropicOptions?["allowedCallers"]
      if !supportsStrictTools, let strict = function.strict {
        warnings.append(
          .unsupported(
            feature: "strict",
            details:
              "Tool '\(function.name)' has strict: \(strict), but strict mode is not supported by this provider. The strict property will be ignored."
          ))
      }
      anthropicTools.append(
        jsonObject([
          "name": .string(function.name),
          "description": .optional(function.description),
          "input_schema": function.inputSchema.value,
          "cache_control": cacheControl,
          "eager_input_streaming": eager ? true : nil,
          "strict": supportsStrictTools ? .optional(function.strict) : nil,
          "defer_loading": anthropicOptions?["deferLoading"],
          "allowed_callers": allowedCallers,
          "input_examples": function.inputExamples.map { .array($0.map(JSONValue.object)) },
        ]))
      if supportsStructuredOutput { betas.insert("structured-outputs-2025-11-13") }
      if function.inputExamples != nil || allowedCallers != nil { betas.insert("advanced-tool-use-2025-11-20") }
    case .provider(let providerTool):
      if let definition = providerToolDefinition(providerTool, betas: &betas) {
        anthropicTools.append(definition)
      } else {
        warnings.append(.unsupported(feature: "provider-defined tool \(providerTool.id)"))
      }
    }
  }

  let parallel: JSONValue? = .optional(disableParallelToolUse)
  switch toolChoice {
  case nil:
    let choice: JSONValue? =
      disableParallelToolUse == true ? ["type": "auto", "disable_parallel_tool_use": true] : nil
    return (anthropicTools, choice, warnings, betas)
  case .some(.auto):
    return (anthropicTools, jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas)
  case .some(.required):
    if rejectsForcedToolUse {
      warnings.append(
        .unsupported(
          feature: "toolChoice",
          details:
            "toolChoice 'required' is not supported by this model because it rejects forced tool use. Using 'auto' instead. Instruct the model to use a tool in the prompt and verify that a tool call was made."
        ))
      return (anthropicTools, jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas)
    }
    return (anthropicTools, jsonObject(["type": "any", "disable_parallel_tool_use": parallel]), warnings, betas)
  case .some(.none):
    return (nil, nil, warnings, betas)
  case .some(.tool(let name)):
    if rejectsForcedToolUse {
      warnings.append(
        .unsupported(
          feature: "toolChoice",
          details:
            "toolChoice 'tool' is not supported by this model because it rejects forced tool use. Only the '\(name)' tool is sent with 'auto' tool choice. Instruct the model to use the tool in the prompt and verify that a tool call was made."
        ))
      return (
        anthropicTools.filter { $0["name"]?.stringValue == name },
        jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas
      )
    }
    return (
      anthropicTools,
      jsonObject(["type": "tool", "name": .string(name), "disable_parallel_tool_use": parallel]),
      warnings, betas
    )
  }
}

/// Whether a dynamic-filtering web tool is used without a code execution
/// tool; its code execution calls are then dynamic. Mirrors upstream
/// `hasDynamicFilteringWebToolWithoutCodeExecution`.
func hasDynamicFilteringWebToolWithoutCodeExecution(_ tools: [JSONValue]?) -> Bool {
  var hasDynamicFilteringWebTool = false
  for tool in tools ?? [] {
    switch tool["type"]?.stringValue {
    case "web_fetch_20260209", "web_fetch_20260318", "web_search_20260209", "web_search_20260318":
      hasDynamicFilteringWebTool = true
    case "code_execution_20250522", "code_execution_20250825", "code_execution_20260120":
      return false
    default:
      continue
    }
  }
  return hasDynamicFilteringWebTool
}
