import AISDKProviderUtils
import Foundation

/// Approximate user location for web search. Mirrors upstream `userLocation`.
public struct OpenAIUserLocation: Sendable, Equatable {
  public var country: String?
  public var city: String?
  public var region: String?
  public var timezone: String?

  public init(country: String? = nil, city: String? = nil, region: String? = nil, timezone: String? = nil) {
    self.country = country
    self.city = city
    self.region = region
    self.timezone = timezone
  }

  var json: JSONValue {
    jsonObject([
      "type": "approximate", "country": .optional(country), "city": .optional(city), "region": .optional(region),
      "timezone": .optional(timezone),
    ])
  }
}

/// OpenAI's built-in Responses API tools. Mirrors upstream `openaiTools`.
///
/// ```swift
/// let result = try await generateText(
///   model: openai("gpt-5.4"), prompt: "What happened today?",
///   tools: ["web_search": OpenAITools.webSearch()])
/// ```
public enum OpenAITools {
  private static let emptyObject: JSONSchema = ["type": "object", "properties": [:]]

  private static func provider(
    _ id: String, args: [String: JSONValue?], inputSchema: JSONSchema = emptyObject, outputSchema: JSONSchema? = nil,
    isProviderExecuted: Bool, supportsDeferredResults: Bool = false, execute: Tool.Execute? = nil
  ) -> Tool {
    var tool = providerTool(
      id: id, args: args.compactMapValues { $0 }, inputSchema: inputSchema, isProviderExecuted: isProviderExecuted,
      supportsDeferredResults: supportsDeferredResults, execute: execute)
    tool.outputSchema = outputSchema
    return tool
  }

  private static func strings(_ values: [String]?) -> JSONValue? {
    values.map { .array($0.map(JSONValue.string)) }
  }

  /// Web search, executed by OpenAI. Mirrors upstream `openai.tools.webSearch`.
  public static func webSearch(
    externalWebAccess: Bool? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
    searchContextSize: String? = nil, userLocation: OpenAIUserLocation? = nil
  ) -> Tool {
    let filters: JSONValue? =
      allowedDomains == nil && blockedDomains == nil
      ? nil : jsonObject(["allowedDomains": strings(allowedDomains), "blockedDomains": strings(blockedDomains)])
    return provider(
      "openai.web_search",
      args: [
        "externalWebAccess": externalWebAccess.map(JSONValue.bool), "filters": filters,
        "searchContextSize": searchContextSize.map(JSONValue.string), "userLocation": userLocation?.json,
      ], isProviderExecuted: true)
  }

  /// The preview web search tool, executed by OpenAI. Mirrors upstream `openai.tools.webSearchPreview`.
  public static func webSearchPreview(searchContextSize: String? = nil, userLocation: OpenAIUserLocation? = nil) -> Tool {
    provider(
      "openai.web_search_preview",
      args: ["searchContextSize": searchContextSize.map(JSONValue.string), "userLocation": userLocation?.json],
      isProviderExecuted: true)
  }

  /// Vector store search, executed by OpenAI. Mirrors upstream `openai.tools.fileSearch`.
  ///
  /// - Parameter filters: A comparison (`key`, `type`, `value`) or compound (`type`, `filters`) filter.
  public static func fileSearch(
    vectorStoreIds: [String], maxNumResults: Int? = nil, ranker: String? = nil, scoreThreshold: Double? = nil,
    filters: JSONValue? = nil
  ) -> Tool {
    let ranking: JSONValue? =
      ranker == nil && scoreThreshold == nil
      ? nil : jsonObject(["ranker": .optional(ranker), "scoreThreshold": .optional(scoreThreshold)])
    return provider(
      "openai.file_search",
      args: [
        "vectorStoreIds": strings(vectorStoreIds), "maxNumResults": maxNumResults.map { .number(Double($0)) },
        "ranking": ranking, "filters": filters,
      ], isProviderExecuted: true)
  }

  /// The container a code interpreter runs in.
  public enum CodeInterpreterContainer: Sendable, Equatable {
    /// An existing container ID.
    case id(String)
    /// A new container with the given files.
    case auto(fileIds: [String]? = nil)
  }

  /// Python execution in a sandbox, executed by OpenAI. Mirrors upstream `openai.tools.codeInterpreter`.
  public static func codeInterpreter(container: CodeInterpreterContainer? = nil) -> Tool {
    let containerValue: JSONValue? =
      switch container {
      case .id(let id)?: .string(id)
      case .auto(let fileIds)?: jsonObject(["fileIds": strings(fileIds)])
      case nil: nil
      }
    return provider(
      "openai.code_interpreter", args: ["container": containerValue],
      inputSchema: ["type": "object", "properties": ["code": ["type": ["string", "null"]], "containerId": ["type": "string"]]],
      isProviderExecuted: true)
  }

  /// Image generation, executed by OpenAI. Mirrors upstream `openai.tools.imageGeneration`.
  public static func imageGeneration(
    action: String? = nil, background: String? = nil, inputFidelity: String? = nil, inputImageMaskFileId: String? = nil,
    inputImageMaskUrl: String? = nil, model: String? = nil, moderation: String? = nil, outputCompression: Int? = nil,
    outputFormat: String? = nil, partialImages: Int? = nil, quality: String? = nil, size: String? = nil
  ) -> Tool {
    let mask: JSONValue? =
      inputImageMaskFileId == nil && inputImageMaskUrl == nil
      ? nil : jsonObject(["fileId": .optional(inputImageMaskFileId), "imageUrl": .optional(inputImageMaskUrl)])
    return provider(
      "openai.image_generation",
      args: [
        "action": action.map(JSONValue.string), "background": background.map(JSONValue.string),
        "inputFidelity": inputFidelity.map(JSONValue.string), "inputImageMask": mask, "model": model.map(JSONValue.string),
        "moderation": moderation.map(JSONValue.string), "outputCompression": outputCompression.map { .number(Double($0)) },
        "outputFormat": outputFormat.map(JSONValue.string), "partialImages": partialImages.map { .number(Double($0)) },
        "quality": quality.map(JSONValue.string), "size": size.map(JSONValue.string),
      ], isProviderExecuted: true)
  }

  /// A remote MCP server or connector, called by OpenAI. Mirrors upstream `openai.tools.mcp`.
  ///
  /// - Parameters:
  ///   - allowedTools: A list of tool names, or `{readOnly, toolNames}`.
  ///   - requireApproval: `"always"`, `"never"`, or `{never: {toolNames}}`. Defaults to `"never"`.
  public static func mcp(
    serverLabel: String, serverUrl: String? = nil, connectorId: String? = nil, allowedTools: JSONValue? = nil,
    authorization: String? = nil, headers: [String: String]? = nil, requireApproval: JSONValue? = nil,
    serverDescription: String? = nil
  ) -> Tool {
    provider(
      "openai.mcp",
      args: [
        "serverLabel": .string(serverLabel), "serverUrl": serverUrl.map(JSONValue.string),
        "connectorId": connectorId.map(JSONValue.string), "allowedTools": allowedTools,
        "authorization": authorization.map(JSONValue.string), "headers": headers.map { .object($0.mapValues(JSONValue.string)) },
        "requireApproval": requireApproval, "serverDescription": serverDescription.map(JSONValue.string),
      ], isProviderExecuted: true)
  }

  /// Shell commands on the local machine, executed by your code. Mirrors upstream `openai.tools.localShell`.
  public static func localShell(execute: Tool.Execute? = nil) -> Tool {
    provider(
      "openai.local_shell", args: [:],
      inputSchema: [
        "type": "object",
        "properties": [
          "action": [
            "type": "object",
            "properties": [
              "type": ["const": "exec"], "command": ["type": "array", "items": ["type": "string"]],
              "timeoutMs": ["type": "number"], "user": ["type": "string"], "workingDirectory": ["type": "string"],
              "env": ["type": "object", "additionalProperties": ["type": "string"]],
            ],
            "required": ["type", "command"],
          ]
        ],
        "required": ["action"],
      ], outputSchema: ["type": "object", "properties": ["output": ["type": "string"]], "required": ["output"]],
      isProviderExecuted: false, execute: execute)
  }

  /// Shell commands, executed locally by your code or in an OpenAI container.
  /// Mirrors upstream `openai.tools.shell`.
  ///
  /// - Parameter environment: `{type: "containerAuto", ...}`, `{type: "containerReference", containerId}`,
  ///   or `{type: "local", skills}`. Container environments run on OpenAI.
  public static func shell(environment: JSONValue? = nil, execute: Tool.Execute? = nil) -> Tool {
    provider(
      "openai.shell", args: ["environment": environment],
      inputSchema: [
        "type": "object",
        "properties": [
          "action": [
            "type": "object",
            "properties": [
              "commands": ["type": "array", "items": ["type": "string"]], "timeoutMs": ["type": "number"],
              "maxOutputLength": ["type": "number"],
            ],
            "required": ["commands"],
          ]
        ],
        "required": ["action"],
      ], isProviderExecuted: false, execute: execute)
  }

  /// File patches (create, update, delete), applied by your code. Mirrors upstream `openai.tools.applyPatch`.
  public static func applyPatch(execute: Tool.Execute? = nil) -> Tool {
    provider(
      "openai.apply_patch", args: [:],
      inputSchema: [
        "type": "object",
        "properties": [
          "callId": ["type": "string"],
          "operation": [
            "type": "object",
            "properties": [
              "type": ["enum": ["create_file", "delete_file", "update_file"]], "path": ["type": "string"],
              "diff": ["type": "string"],
            ],
            "required": ["type", "path"],
          ],
        ],
        "required": ["callId", "operation"],
      ],
      outputSchema: [
        "type": "object", "properties": ["status": ["enum": ["completed", "failed"]], "output": ["type": "string"]],
        "required": ["status"],
      ], isProviderExecuted: false, execute: execute)
  }

  /// Computer use actions, performed by your code. Mirrors upstream `openai.tools.computer`.
  public static func computer(execute: Tool.Execute? = nil) -> Tool {
    provider(
      "openai.computer", args: [:],
      inputSchema: [
        "type": "object",
        "properties": [
          "actions": ["type": "array", "items": ["type": "object"]],
          "pendingSafetyChecks": ["type": "array", "items": ["type": "object"]],
          "status": ["enum": ["in_progress", "completed", "incomplete"]],
        ],
        "required": ["actions", "pendingSafetyChecks", "status"],
      ], isProviderExecuted: false, execute: execute)
  }

  /// A free-form custom tool whose input is plain text, optionally constrained
  /// by a grammar. Mirrors upstream `openai.tools.customTool`.
  ///
  /// - Parameter format: `{type: "text"}` or `{type: "grammar", syntax: "regex" | "lark", definition}`.
  public static func customTool(
    description: String? = nil, async: Bool? = nil, format: JSONValue? = nil, execute: Tool.Execute? = nil
  ) -> Tool {
    provider(
      "openai.custom",
      args: ["description": description.map(JSONValue.string), "async": async.map(JSONValue.bool), "format": format],
      inputSchema: ["type": "string"], isProviderExecuted: false, execute: execute)
  }

  /// Lets the model search deferred tools. Mirrors upstream `openai.tools.toolSearch`.
  ///
  /// - Parameter execution: `server` (default) or `client`.
  public static func toolSearch(
    execution: String? = nil, description: String? = nil, parameters: JSONObject? = nil, execute: Tool.Execute? = nil
  ) -> Tool {
    provider(
      "openai.tool_search",
      args: [
        "execution": execution.map(JSONValue.string), "description": description.map(JSONValue.string),
        "parameters": parameters.map(JSONValue.object),
      ],
      inputSchema: ["type": "object", "properties": ["arguments": [:], "call_id": ["type": ["string", "null"]]]],
      isProviderExecuted: false, execute: execute)
  }

  /// Lets the model call your function tools from generated code, executed by
  /// OpenAI. Mirrors upstream `openai.tools.programmaticToolCalling`.
  ///
  /// Function tools that the program may call need
  /// `providerOptions: ["openai": ["allowedCallers": ["direct", "programmatic"]]]`.
  public static func programmaticToolCalling() -> Tool {
    provider(
      "openai.programmatic_tool_calling", args: [:],
      inputSchema: [
        "type": "object", "properties": ["code": ["type": "string"], "fingerprint": ["type": "string"]],
        "required": ["code", "fingerprint"],
      ], isProviderExecuted: true, supportsDeferredResults: true)
  }
}
