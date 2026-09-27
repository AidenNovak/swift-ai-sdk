import AISDKProviderUtils
import Foundation

/// The newest (stateless, modern-era) MCP protocol version.
public let MCP_LATEST_PROTOCOL_VERSION = "2026-07-28"
/// The newest session-based (legacy-era) MCP protocol version.
public let MCP_LATEST_LEGACY_PROTOCOL_VERSION = "2025-11-25"
/// Protocol versions this client accepts. Mirrors upstream `SUPPORTED_PROTOCOL_VERSIONS`.
public let MCP_SUPPORTED_PROTOCOL_VERSIONS = [
  MCP_LATEST_PROTOCOL_VERSION, MCP_LATEST_LEGACY_PROTOCOL_VERSION, "2025-06-18", "2025-03-26", "2024-11-05",
]

private func parseFailure(_ what: String, _ value: JSONValue) -> MCPClientError {
  MCPClientError(message: "Failed to parse server response", cause: MCPClientError(message: "\(what): \(value.jsonString())"))
}

private func requireString(_ object: JSONObject, _ key: String, _ what: String) throws -> String {
  guard let value = object[key]?.stringValue else { throw parseFailure("\(what).\(key) must be a string", .object(object)) }
  return value
}

private func optionalString(_ object: JSONObject, _ key: String, _ what: String) throws -> String? {
  switch object[key] {
  case nil: return nil
  case .string(let value)?: return value
  default: throw parseFailure("\(what).\(key) must be a string", .object(object))
  }
}

private func optionalObject(_ object: JSONObject, _ key: String, _ what: String) throws -> JSONObject? {
  switch object[key] {
  case nil: return nil
  case .object(let value)?: return value
  default: throw parseFailure("\(what).\(key) must be an object", .object(object))
  }
}

private func requireArray(_ object: JSONObject, _ key: String, _ what: String) throws -> [JSONValue] {
  guard case .array(let values)? = object[key] else { throw parseFailure("\(what).\(key) must be an array", .object(object)) }
  return values
}

/// Request bounds. Upstream's `signal` is replaced by task cancellation.
/// Mirrors upstream `RequestOptions`.
public struct MCPRequestOptions: Sendable, Equatable {
  public var timeout: Duration?
  public var maxTotalTimeout: Duration?

  public init(timeout: Duration? = nil, maxTotalTimeout: Duration? = nil) {
    self.timeout = timeout
    self.maxTotalTimeout = maxTotalTimeout
  }

  var effectiveTimeout: Duration? {
    guard let timeout else { return maxTotalTimeout }
    guard let maxTotalTimeout else { return timeout }
    return min(timeout, maxTotalTimeout)
  }
}

/// A client or server implementation description. Mirrors upstream `Configuration`.
public struct MCPImplementation: Sendable, Equatable {
  public var name: String
  public var version: String
  public var title: String?
  /// All fields, including ones this type does not model.
  public var raw: JSONObject

  public init(name: String, version: String, title: String? = nil) {
    self.name = name
    self.version = version
    self.title = title
    self.raw = jsonObject(["name": .string(name), "version": .string(version), "title": .optional(title)]).objectValue ?? [:]
  }

  init(json object: JSONObject) throws {
    name = try requireString(object, "name", "serverInfo")
    version = try requireString(object, "version", "serverInfo")
    title = try optionalString(object, "title", "serverInfo")
    raw = object
  }
}

/// The result of `initialize`. Mirrors upstream `InitializeResult`.
public struct MCPInitializeResult: Sendable, Equatable {
  public var protocolVersion: String
  /// Server capabilities, e.g. `tools`, `resources`, `prompts`, `completions`.
  public var capabilities: JSONObject
  public var serverInfo: MCPImplementation
  public var instructions: String?
  public var meta: JSONObject?

  public init(
    protocolVersion: String, capabilities: JSONObject, serverInfo: MCPImplementation, instructions: String? = nil,
    meta: JSONObject? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
    self.serverInfo = serverInfo
    self.instructions = instructions
    self.meta = meta
  }

  public init(json object: JSONObject) throws {
    protocolVersion = try requireString(object, "protocolVersion", "initialize")
    guard let capabilities = try optionalObject(object, "capabilities", "initialize") else {
      throw parseFailure("initialize.capabilities must be an object", .object(object))
    }
    self.capabilities = capabilities
    guard let serverInfo = try optionalObject(object, "serverInfo", "initialize") else {
      throw parseFailure("initialize.serverInfo must be an object", .object(object))
    }
    self.serverInfo = try MCPImplementation(json: serverInfo)
    instructions = try optionalString(object, "instructions", "initialize")
    meta = try optionalObject(object, "_meta", "initialize")
  }
}

/// A tool definition from `tools/list`. Mirrors upstream `MCPTool`.
public struct MCPToolDefinition: Sendable, Equatable {
  public var name: String
  public var title: String?
  public var description: String?
  public var inputSchema: JSONObject
  public var outputSchema: JSONObject?
  public var annotations: JSONObject?
  public var meta: JSONObject?

  public init(
    name: String, title: String? = nil, description: String? = nil, inputSchema: JSONObject = ["type": "object"],
    outputSchema: JSONObject? = nil, annotations: JSONObject? = nil, meta: JSONObject? = nil
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
    self.meta = meta
  }

  init(json value: JSONValue) throws {
    guard case .object(let object) = value else { throw parseFailure("tool must be an object", value) }
    name = try requireString(object, "name", "tool")
    title = try optionalString(object, "title", "tool")
    description = try optionalString(object, "description", "tool")
    guard let inputSchema = try optionalObject(object, "inputSchema", "tool") else {
      throw parseFailure("tool.inputSchema must be an object", value)
    }
    if let properties = inputSchema["properties"], properties.objectValue == nil {
      throw parseFailure("tool.inputSchema.properties must be an object", value)
    }
    self.inputSchema = inputSchema
    outputSchema = try optionalObject(object, "outputSchema", "tool")
    annotations = try optionalObject(object, "annotations", "tool")
    if let annotations {
      for key in ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] {
        if let hint = annotations[key], hint.boolValue == nil {
          throw parseFailure("tool.annotations.\(key) must be a boolean", value)
        }
      }
    }
    meta = try optionalObject(object, "_meta", "tool")
  }
}

/// The result of `tools/list`. Mirrors upstream `ListToolsResult`.
public struct MCPListToolsResult: Sendable, Equatable {
  public var tools: [MCPToolDefinition]
  public var nextCursor: String?

  public init(tools: [MCPToolDefinition], nextCursor: String? = nil) {
    self.tools = tools
    self.nextCursor = nextCursor
  }

  init(json object: JSONObject) throws {
    tools = try requireArray(object, "tools", "tools/list").map(MCPToolDefinition.init(json:))
    nextCursor = try optionalString(object, "nextCursor", "tools/list")
  }
}

private func validateContent(_ part: JSONValue) throws {
  guard case .object(let object) = part, let type = object["type"]?.stringValue else {
    throw parseFailure("content parts need a type", part)
  }
  switch type {
  case "text":
    _ = try requireString(object, "text", "text content")
  case "image":
    _ = try requireString(object, "mimeType", "image content")
    guard let data = object["data"]?.stringValue, Data(base64Encoded: data) != nil else {
      throw parseFailure("image content data must be base64", part)
    }
  case "resource":
    guard case .object(let resource)? = object["resource"] else { throw parseFailure("resource content needs resource", part) }
    try validateResourceContents(.object(resource))
  case "resource_link":
    _ = try requireString(object, "uri", "resource_link")
    _ = try requireString(object, "name", "resource_link")
  default:
    break
  }
}

private func validateResourceContents(_ value: JSONValue) throws {
  guard case .object(let object) = value else { throw parseFailure("resource contents must be an object", value) }
  _ = try requireString(object, "uri", "resource contents")
  if object["text"]?.stringValue != nil { return }
  guard let blob = object["blob"]?.stringValue, Data(base64Encoded: blob) != nil else {
    throw parseFailure("resource contents need text or base64 blob", value)
  }
}

/// The result of `tools/call`. Mirrors upstream `CallToolResult`, including
/// its normalization of structured-content-only results.
public struct MCPCallToolResult: Sendable, Equatable {
  /// The normalized result object, as returned to the model.
  public var json: JSONObject

  public var content: [JSONValue]? { json["content"]?.arrayValue }
  public var structuredContent: JSONValue? { json["structuredContent"] }
  public var isError: Bool { json["isError"]?.boolValue ?? false }
  /// The legacy `toolResult` payload of 2024-11-05 servers.
  public var toolResult: JSONValue? { json["toolResult"] }

  public init(json object: JSONObject) throws {
    if let resultType = object["resultType"], resultType.stringValue == nil {
      throw parseFailure("resultType must be a string", .object(object))
    }
    if let isError = object["isError"], isError.boolValue == nil {
      throw parseFailure("isError must be a boolean", .object(object))
    }
    if case .array(let content)? = object["content"] {
      try content.forEach(validateContent)
      var normalized = object
      normalized["isError"] = object["isError"] ?? false
      json = normalized
    } else if object["content"] == nil, let structured = object["structuredContent"], structured != .null {
      var normalized = object
      normalized["content"] = [["type": "text", "text": .string(structured.jsonString(sortedKeys: false))]]
      normalized["isError"] = object["isError"] ?? false
      json = normalized
    } else if object["content"] == nil, object["toolResult"] != nil {
      json = object
    } else {
      throw parseFailure("tools/call result needs content, structuredContent or toolResult", .object(object))
    }
  }
}

/// A resource from `resources/list`. Mirrors upstream `MCPResource`.
public struct MCPResource: Sendable, Equatable {
  public var uri: String
  public var name: String
  public var raw: JSONObject

  init(json value: JSONValue) throws {
    guard case .object(let object) = value else { throw parseFailure("resource must be an object", value) }
    uri = try requireString(object, "uri", "resource")
    name = try requireString(object, "name", "resource")
    raw = object
  }
}

/// The result of `resources/list`. Mirrors upstream `ListResourcesResult`.
public struct MCPListResourcesResult: Sendable, Equatable {
  public var resources: [MCPResource]
  public var nextCursor: String?

  init(json object: JSONObject) throws {
    resources = try requireArray(object, "resources", "resources/list").map(MCPResource.init(json:))
    nextCursor = try optionalString(object, "nextCursor", "resources/list")
  }
}

/// The result of `resources/read`. Mirrors upstream `ReadResourceResult`.
public struct MCPReadResourceResult: Sendable, Equatable {
  /// Text (`uri`, `text`) or blob (`uri`, `blob`) contents.
  public var contents: [JSONValue]

  init(json object: JSONObject) throws {
    contents = try requireArray(object, "contents", "resources/read")
    try contents.forEach(validateResourceContents)
  }
}

/// The result of `resources/templates/list`. Mirrors upstream `ListResourceTemplatesResult`.
public struct MCPListResourceTemplatesResult: Sendable, Equatable {
  public var resourceTemplates: [JSONObject]

  init(json object: JSONObject) throws {
    resourceTemplates = try requireArray(object, "resourceTemplates", "resources/templates/list").map { template in
      guard case .object(let template) = template else { throw parseFailure("resource template must be an object", template) }
      _ = try requireString(template, "uriTemplate", "resource template")
      _ = try requireString(template, "name", "resource template")
      return template
    }
  }
}

/// A prompt from `prompts/list`. Mirrors upstream `MCPPrompt`.
public struct MCPPrompt: Sendable, Equatable {
  public var name: String
  public var raw: JSONObject

  init(json value: JSONValue) throws {
    guard case .object(let object) = value else { throw parseFailure("prompt must be an object", value) }
    name = try requireString(object, "name", "prompt")
    raw = object
  }
}

/// The result of `prompts/list`. Mirrors upstream `ListPromptsResult`.
public struct MCPListPromptsResult: Sendable, Equatable {
  public var prompts: [MCPPrompt]
  public var nextCursor: String?

  init(json object: JSONObject) throws {
    prompts = try requireArray(object, "prompts", "prompts/list").map(MCPPrompt.init(json:))
    nextCursor = try optionalString(object, "nextCursor", "prompts/list")
  }
}

/// The result of `prompts/get`. Mirrors upstream `GetPromptResult`.
public struct MCPGetPromptResult: Sendable, Equatable {
  public var description: String?
  /// Messages with `role` (`user` or `assistant`) and one content part.
  public var messages: [JSONObject]

  init(json object: JSONObject) throws {
    description = try optionalString(object, "description", "prompts/get")
    messages = try requireArray(object, "messages", "prompts/get").map { message in
      guard case .object(let message) = message, ["user", "assistant"].contains(message["role"]?.stringValue ?? ""),
        let content = message["content"]
      else { throw parseFailure("prompt message needs a user/assistant role and content", message) }
      try validateContent(content)
      return message
    }
  }
}

/// The result of `completion/complete`. Mirrors upstream `CompleteResult`.
public struct MCPCompleteResult: Sendable, Equatable {
  public var values: [String]
  public var total: Int?
  public var hasMore: Bool?

  init(json object: JSONObject) throws {
    guard let completion = try optionalObject(object, "completion", "completion/complete"),
      case .array(let values)? = completion["values"], values.count <= 100
    else { throw parseFailure("completion.values must be an array of at most 100 strings", .object(object)) }
    self.values = try values.map {
      guard let value = $0.stringValue else { throw parseFailure("completion values must be strings", .object(object)) }
      return value
    }
    total = completion["total"]?.intValue
    hasMore = completion["hasMore"]?.boolValue
  }
}

/// A server request for user input. Mirrors upstream `ElicitationRequest`.
public struct MCPElicitationRequest: Sendable, Equatable {
  public var message: String
  /// The JSON Schema of the requested input.
  public var requestedSchema: JSONValue?
  public var params: JSONObject
}

/// The client's answer to an elicitation request. Mirrors upstream `ElicitResult`.
public struct MCPElicitResult: Sendable, Equatable {
  public enum Action: String, Sendable {
    case accept, decline, cancel
  }

  public var action: Action
  public var content: JSONObject?

  public init(action: Action, content: JSONObject? = nil) {
    self.action = action
    self.content = content
  }

  var json: JSONObject {
    jsonObject(["action": .string(action.rawValue), "content": content.map(JSONValue.object)]).objectValue ?? [:]
  }
}

/// Metadata attached to MCP tools. Mirrors upstream `McpProviderMetadata`.
public enum MCPToolMetadata {
  public static func make(clientName: String, toolName: String, title: String?, annotations: JSONObject?, app: JSONObject?)
    -> JSONObject
  {
    var metadata: JSONObject = ["clientName": .string(clientName), "toolName": .string(toolName)]
    if let title { metadata["title"] = .string(title) }
    if let annotations {
      var kept: JSONObject = [:]
      for key in ["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] {
        if let value = annotations[key], value != .null { kept[key] = value }
      }
      metadata["annotations"] = .object(kept)
    }
    if let app { metadata["app"] = .object(app) }
    return metadata
  }
}
