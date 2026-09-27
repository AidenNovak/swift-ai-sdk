import AISDKProviderUtils
import Foundation

/// Converts tools and tool choice to the Anthropic format. Mirrors the
/// function-tool path of upstream `prepareTools`.
///
/// Provider-defined Anthropic tools (web search, code execution, ...) are
/// reported as unsupported until they are ported.
func prepareAnthropicTools(
  tools: [LanguageModelV4Tool],
  toolChoice: LanguageModelV4ToolChoice?,
  disableParallelToolUse: Bool?,
  validator: CacheControlValidator,
  supportsStructuredOutput: Bool,
  supportsStrictTools: Bool,
  eagerInputStreaming: Bool,
  rejectsForcedToolUse: Bool
) throws -> (tools: JSONValue?, toolChoice: JSONValue?, warnings: [SharedV4Warning], betas: Set<String>) {
  var warnings: [SharedV4Warning] = []
  var betas = Set<String>()
  guard !tools.isEmpty else { return (nil, nil, warnings, betas) }

  var anthropicTools: [(name: String, value: JSONValue)] = []
  for tool in tools {
    switch tool {
    case .function(let function):
      let cacheControl = validator.cacheControl(function.providerOptions, type: "tool definition")
      let anthropicOptions = function.providerOptions?["anthropic"]
      let eager = anthropicOptions?["eagerInputStreaming"]?.boolValue ?? eagerInputStreaming
      if !supportsStrictTools && function.strict != nil {
        warnings.append(
          .unsupported(
            feature: "strict",
            details:
              "Tool '\(function.name)' has strict: \(function.strict!), but strict mode is not supported by this provider. The strict property will be ignored."
          ))
      }
      anthropicTools.append(
        (
          function.name,
          jsonObject([
            "name": .string(function.name),
            "description": .optional(function.description),
            "input_schema": function.inputSchema.value,
            "cache_control": cacheControl,
            "eager_input_streaming": eager ? true : nil,
            "strict": supportsStrictTools ? .optional(function.strict) : nil,
            "defer_loading": anthropicOptions?["deferLoading"],
            "input_examples": function.inputExamples.map { .array($0.map(JSONValue.object)) },
          ])
        ))
      if supportsStructuredOutput { betas.insert("structured-outputs-2025-11-13") }
      if function.inputExamples != nil { betas.insert("advanced-tool-use-2025-11-20") }
    case .provider(let providerTool):
      warnings.append(.unsupported(feature: "provider-defined tool \(providerTool.id)"))
    }
  }

  let toolValues = JSONValue.array(anthropicTools.map(\.value))
  let parallel: JSONValue? = .optional(disableParallelToolUse)

  switch toolChoice {
  case nil:
    let choice: JSONValue? =
      disableParallelToolUse == true ? ["type": "auto", "disable_parallel_tool_use": true] : nil
    return (toolValues, choice, warnings, betas)
  case .some(.auto):
    return (toolValues, jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas)
  case .some(.required):
    if rejectsForcedToolUse {
      warnings.append(
        .unsupported(
          feature: "toolChoice",
          details:
            "toolChoice 'required' is not supported by this model because it rejects forced tool use. Using 'auto' instead. Instruct the model to use a tool in the prompt and verify that a tool call was made."
        ))
      return (toolValues, jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas)
    }
    return (toolValues, jsonObject(["type": "any", "disable_parallel_tool_use": parallel]), warnings, betas)
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
        .array(anthropicTools.filter { $0.name == name }.map(\.value)),
        jsonObject(["type": "auto", "disable_parallel_tool_use": parallel]), warnings, betas
      )
    }
    return (
      toolValues,
      jsonObject(["type": "tool", "name": .string(name), "disable_parallel_tool_use": parallel]),
      warnings, betas
    )
  }
}
