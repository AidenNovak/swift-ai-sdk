import AISDKProviderUtils
import Foundation

private enum AllowedToolResolution: Equatable {
  case supported(JSONValue)
  case unsupported(String)
  case ambiguous
}

private func allowedToolKey(_ entry: JSONValue) -> String {
  let type = entry["type"]?.stringValue ?? ""
  switch type {
  case "mcp": return "mcp:\(entry["server_label"]?.stringValue ?? "")"
  case "function", "custom": return "\(type):\(entry["name"]?.stringValue ?? "")"
  default: return type
  }
}

private func isSameAllowedTool(_ a: AllowedToolResolution, _ b: AllowedToolResolution) -> Bool {
  switch (a, b) {
  case (.supported(let x), .supported(let y)): allowedToolKey(x) == allowedToolKey(y)
  case (.unsupported(let x), .unsupported(let y)): x == y
  default: false
  }
}

private func allowedToolResolution(_ tool: JSONValue) -> AllowedToolResolution {
  let type = tool["type"]?.stringValue ?? ""
  switch type {
  case "custom":
    return .supported(["type": "custom", "name": tool["name"] ?? .null])
  case "mcp":
    return .supported(["type": "mcp", "server_label": tool["server_label"] ?? .null])
  case "file_search", "web_search", "web_search_preview", "image_generation", "code_interpreter", "computer",
    "apply_patch", "shell", "local_shell", "programmatic_tool_calling":
    return .supported(["type": .string(type)])
  default:
    return .unsupported("OpenAI does not support \(type) tools in tool_choice.allowed_tools")
  }
}

private func resolveAsyncToolOption(
  _ value: Bool?, supportsAsyncToolCalling: Bool, toolName: String, warnings: inout [SharedV4Warning]
) -> Bool? {
  if value != true || supportsAsyncToolCalling { return value }
  warnings.append(
    .unsupported(
      feature: "async tool calling for \"\(toolName)\"",
      details: "Async tool calling is only supported by GPT-6 and later models."))
  return nil
}

private func requireArg<T>(_ value: T?, _ toolId: String, _ name: String) throws -> T {
  guard let value else {
    throw TypeValidationError(
      value: nil, cause: InvalidArgumentError(argument: name, message: "\(toolId) requires `\(name)`."))
  }
  return value
}

private func mapShellSkill(_ skill: JSONValue) throws -> JSONValue {
  if skill["type"]?.stringValue == "skillReference" {
    var reference: SharedV4ProviderReference = [:]
    for (key, value) in skill["providerReference"]?.objectValue ?? [:] {
      if let string = value.stringValue { reference[key] = string }
    }
    var object: JSONObject = [:]
    object["type"] = "skill_reference"
    object["skill_id"] = .string(try resolveProviderReference(reference, provider: "openai"))
    object["version"] = skill["version"] ?? "latest"
    return .object(object)
  }
  var source: JSONObject = [:]
  source["type"] = "base64"
  source["media_type"] = skill["source"]?["mediaType"] ?? .null
  source["data"] = skill["source"]?["data"] ?? .null
  var object: JSONObject = [:]
  object["type"] = "inline"
  object["name"] = skill["name"] ?? .null
  object["description"] = skill["description"] ?? .null
  object["source"] = .object(source)
  return .object(object)
}

private func mapShellEnvironment(_ environment: JSONValue) throws -> JSONValue {
  switch environment["type"]?.stringValue {
  case "containerReference":
    return ["type": "container_reference", "container_id": environment["containerId"] ?? .null]
  case "containerAuto":
    let networkPolicy: JSONValue? =
      switch environment["networkPolicy"] {
      case nil, .null?: nil
      case let policy? where policy["type"]?.stringValue == "disabled": ["type": "disabled"]
      case let policy?:
        jsonObject([
          "type": "allowlist", "allowed_domains": policy["allowedDomains"],
          "domain_secrets": policy["domainSecrets"],
        ])
      }
    let skills: JSONValue? = try environment["skills"]?.arrayValue.map { .array(try $0.map(mapShellSkill)) }
    return jsonObject([
      "type": "container_auto", "file_ids": environment["fileIds"], "memory_limit": environment["memoryLimit"],
      "network_policy": networkPolicy, "skills": skills,
    ])
  default:
    return jsonObject(["type": "local", "skills": environment["skills"]])
  }
}

/// Converts tools for the Responses API. Mirrors upstream `prepareResponsesTools`.
///
/// - Returns: The request tools and tool choice, plus the names of custom
///   tools and of function tools that declare an output schema.
func prepareOpenAIResponsesTools(
  tools: [LanguageModelV4Tool]?, toolChoice: LanguageModelV4ToolChoice?,
  allowedTools: OpenAIResponsesOptions.AllowedTools?, toolNameMapping: ToolNameMapping,
  supportsAsyncToolCalling: Bool = true
) throws -> (
  tools: JSONValue?, toolChoice: JSONValue?, warnings: [SharedV4Warning], customToolNames: Set<String>,
  outputSchemaToolNames: Set<String>
) {
  guard let tools, !tools.isEmpty else { return (nil, nil, [], [], []) }

  var warnings: [SharedV4Warning] = []
  var openaiTools: [JSONValue] = []
  var namespaceIndex: [String: Int] = [:]
  var customToolNames: Set<String> = []
  var outputSchemaToolNames: Set<String> = []
  var resolutions: [String: AllowedToolResolution] = [:]
  var aliases: [String: AllowedToolResolution] = [:]

  func record(_ name: String, _ resolution: AllowedToolResolution, canonicalName: String?) {
    resolutions[name] = resolution
    guard let canonicalName, canonicalName != name else { return }
    if let existing = aliases[canonicalName] {
      if existing != .ambiguous, !isSameAllowedTool(existing, resolution) { aliases[canonicalName] = .ambiguous }
    } else {
      aliases[canonicalName] = resolution
    }
  }

  for tool in tools {
    switch tool {
    case .function(let function):
      let options = function.providerOptions?["openai"]
      if options?["outputSchema"] != nil { outputSchemaToolNames.insert(function.name) }
      let normalizedInput = try normalizeOpenAIJsonSchema(function.inputSchema)
      let normalizedOutput = try options?["outputSchema"].map { try normalizeOpenAIJsonSchema(JSONSchema($0)) }
      warnings += normalizedInput.warnings + (normalizedOutput?.warnings ?? [])
      let async = resolveAsyncToolOption(
        options?["async"]?.boolValue, supportsAsyncToolCalling: supportsAsyncToolCalling, toolName: function.name,
        warnings: &warnings)
      let functionTool = jsonObject([
        "type": "function",
        "name": .string(function.name),
        "description": .optional(function.description),
        "parameters": normalizedInput.schema.value,
        "async": .optional(async),
        "strict": .bool(function.strict ?? false),
        "defer_loading": options?["deferLoading"],
        "allowed_callers": options?["allowedCallers"],
        "output_schema": normalizedOutput?.schema.value,
      ])

      let namespace = options?["namespace"]
      if let namespace, let name = namespace["name"]?.stringValue {
        let description = namespace["description"] ?? .null
        if let index = namespaceIndex[name] {
          guard openaiTools[index]["description"] == description else {
            throw UnsupportedFunctionalityError(functionality: "conflicting descriptions for OpenAI tool namespace \"\(name)\"")
          }
          var namespaceTool = openaiTools[index].objectValue ?? [:]
          namespaceTool["tools"] = .array((namespaceTool["tools"]?.arrayValue ?? []) + [functionTool])
          openaiTools[index] = .object(namespaceTool)
        } else {
          namespaceIndex[name] = openaiTools.count
          openaiTools.append(["type": "namespace", "name": .string(name), "description": description, "tools": [functionTool]])
        }
        record(
          function.name, .unsupported("tools inside an OpenAI tool namespace are not visible to tool_choice.allowed_tools"),
          canonicalName: nil)
      } else {
        openaiTools.append(functionTool)
        record(
          function.name,
          options?["deferLoading"]?.boolValue == true
            ? .unsupported("deferred tools are not visible to tool_choice.allowed_tools")
            : .supported(["type": "function", "name": .string(function.name)]),
          canonicalName: nil)
      }

    case .provider(let providerTool):
      let args = providerTool.args
      let countBefore = openaiTools.count
      switch providerTool.id {
      case "openai.file_search":
        let ranking = args["ranking"]
        openaiTools.append(
          jsonObject([
            "type": "file_search",
            "vector_store_ids": try requireArg(args["vectorStoreIds"], providerTool.id, "vectorStoreIds"),
            "max_num_results": args["maxNumResults"],
            "ranking_options": ranking.map {
              jsonObject(["ranker": $0["ranker"], "score_threshold": $0["scoreThreshold"]])
            },
            "filters": args["filters"],
          ]))
      case "openai.local_shell":
        openaiTools.append(["type": "local_shell"])
      case "openai.shell":
        openaiTools.append(jsonObject(["type": "shell", "environment": try args["environment"].map(mapShellEnvironment)]))
      case "openai.apply_patch":
        openaiTools.append(["type": "apply_patch"])
      case "openai.computer":
        openaiTools.append(["type": "computer"])
      case "openai.web_search_preview":
        openaiTools.append(
          jsonObject([
            "type": "web_search_preview", "search_context_size": args["searchContextSize"],
            "user_location": args["userLocation"],
          ]))
      case "openai.web_search":
        openaiTools.append(
          jsonObject([
            "type": "web_search",
            "filters": args["filters"].map {
              jsonObject(["allowed_domains": $0["allowedDomains"], "blocked_domains": $0["blockedDomains"]])
            },
            "external_web_access": args["externalWebAccess"],
            "search_context_size": args["searchContextSize"],
            "user_location": args["userLocation"],
          ]))
      case "openai.code_interpreter":
        let container: JSONValue =
          switch args["container"] {
          case .string(let id)?: .string(id)
          case let value?: jsonObject(["type": "auto", "file_ids": value["fileIds"]])
          case nil: ["type": "auto"]
          }
        openaiTools.append(["type": "code_interpreter", "container": container])
      case "openai.image_generation":
        openaiTools.append(
          jsonObject([
            "type": "image_generation", "action": args["action"], "background": args["background"],
            "input_fidelity": args["inputFidelity"],
            "input_image_mask": args["inputImageMask"].map {
              jsonObject(["file_id": $0["fileId"], "image_url": $0["imageUrl"]])
            },
            "model": args["model"], "moderation": args["moderation"], "partial_images": args["partialImages"],
            "quality": args["quality"], "output_compression": args["outputCompression"],
            "output_format": args["outputFormat"], "size": args["size"],
          ]))
      case "openai.mcp":
        guard args["serverUrl"] != nil || args["connectorId"] != nil else {
          throw TypeValidationError(
            value: .object(args),
            cause: InvalidArgumentError(argument: "serverUrl", message: "One of serverUrl or connectorId must be provided."))
        }
        let requireApproval: JSONValue =
          switch args["requireApproval"] {
          case .string(let value)?: .string(value)
          case let value? where value["never"] != nil:
            ["never": jsonObject(["tool_names": value["never"]?["toolNames"]])]
          default: "never"
          }
        let allowed: JSONValue? =
          switch args["allowedTools"] {
          case .array(let names)?: .array(names)
          case let value?: jsonObject(["read_only": value["readOnly"], "tool_names": value["toolNames"]])
          case nil: nil
          }
        openaiTools.append(
          jsonObject([
            "type": "mcp", "server_label": try requireArg(args["serverLabel"], providerTool.id, "serverLabel"),
            "allowed_tools": allowed, "authorization": args["authorization"], "connector_id": args["connectorId"],
            "headers": args["headers"], "require_approval": requireApproval,
            "server_description": args["serverDescription"], "server_url": args["serverUrl"],
          ]))
      case "openai.custom":
        let async = resolveAsyncToolOption(
          args["async"]?.boolValue, supportsAsyncToolCalling: supportsAsyncToolCalling, toolName: providerTool.name,
          warnings: &warnings)
        openaiTools.append(
          jsonObject([
            "type": "custom", "name": .string(providerTool.name), "description": args["description"],
            "async": async != nil ? args["async"] : nil, "format": args["format"],
          ]))
        customToolNames.insert(providerTool.name)
      case "openai.programmatic_tool_calling":
        openaiTools.append(["type": "programmatic_tool_calling"])
      case "openai.tool_search":
        openaiTools.append(
          jsonObject([
            "type": "tool_search", "execution": args["execution"], "description": args["description"],
            "parameters": args["parameters"],
          ]))
      default:
        break
      }
      if openaiTools.count > countBefore {
        record(
          providerTool.name, allowedToolResolution(openaiTools[countBefore]),
          canonicalName: toolNameMapping.toProviderToolName(providerTool.name))
      }
    }
  }

  if let allowedTools {
    var entries: [JSONValue] = []
    var dropped: [String] = []
    for name in allowedTools.toolNames {
      let direct = resolutions[name]
      let resolution = direct ?? aliases[name]
      if direct != nil, aliases[name] != nil {
        warnings.append(
          .unsupported(
            feature: "allowedTools entry \"\(name)\"",
            details:
              "this name is both a tool name and the provider tool name of another tool in this request; the tool with this name is allowed"
          ))
      }
      switch resolution {
      case .ambiguous?:
        warnings.append(
          .unsupported(
            feature: "allowedTools entry \"\(name)\"",
            details:
              "several tools in this request share this provider tool name; use the tool name from the tools for this request instead"
          ))
        dropped.append(name)
      case nil:
        warnings.append(
          .unsupported(
            feature: "allowedTools entry \"\(name)\"",
            details: "the tool is not part of the tools for this request and is sent as a function tool"))
        entries.append(["type": "function", "name": .string(toolNameMapping.toProviderToolName(name))])
      case .unsupported(let reason)?:
        warnings.append(
          .unsupported(
            feature: "allowedTools entry \"\(name)\"", details: "\(reason); the tool is removed from the allowed tools"))
        dropped.append(name)
      case .supported(let entry)?:
        entries.append(entry)
      }
    }
    guard !entries.isEmpty else {
      throw UnsupportedFunctionalityError(
        functionality: "allowedTools with only tools that cannot be allow-listed (\(dropped.joined(separator: ", ")))")
    }
    return (
      .array(openaiTools),
      ["type": "allowed_tools", "mode": .string(allowedTools.mode ?? "auto"), "tools": .array(entries)],
      warnings, customToolNames, outputSchemaToolNames
    )
  }

  let choice: JSONValue? =
    switch toolChoice {
    case nil: nil
    case .some(.auto): "auto"
    case .some(.none): "none"
    case .some(.required): "required"
    case .some(.tool(let name)):
      {
        let resolved = toolNameMapping.toProviderToolName(name)
        let builtIns: Set<String> = [
          "code_interpreter", "file_search", "image_generation", "web_search_preview", "web_search", "mcp",
          "apply_patch", "computer", "programmatic_tool_calling",
        ]
        if builtIns.contains(resolved) { return ["type": .string(resolved)] }
        if customToolNames.contains(resolved) { return ["type": "custom", "name": .string(resolved)] }
        return ["type": "function", "name": .string(resolved)]
      }()
    }
  return (.array(openaiTools), choice, warnings, customToolNames, outputSchemaToolNames)
}
