import Foundation

/// A message as shown in a chat UI. Mirrors upstream `UIMessage`.
///
/// UI messages are the source of truth for application state: persist them,
/// send them to the server, and convert them to model messages with
/// `convertToModelMessages`. Upstream's generic metadata, data and tool types
/// are compile-time only in TypeScript; here they are carried as `JSONValue`.
/// The JSON form (`json`, `Codable`) matches upstream exactly, so Swift clients
/// and JavaScript servers (or the reverse) interoperate.
public struct UIMessage: Sendable, Equatable, Identifiable {
  public enum Role: String, Sendable, Hashable, Codable {
    case system, user, assistant
  }

  /// A unique identifier for the message.
  public var id: String
  public var role: Role
  /// Application-defined metadata, e.g. timestamps or token usage.
  public var metadata: JSONValue?
  /// The parts of the message; use them to render the message in the UI.
  public var parts: [UIMessagePart]

  public init(id: String, role: Role, metadata: JSONValue? = nil, parts: [UIMessagePart]) {
    self.id = id
    self.role = role
    self.metadata = metadata
    self.parts = parts
  }
}

/// A part of a UI message. Mirrors upstream `UIMessagePart`.
public enum UIMessagePart: Sendable, Equatable {
  case text(TextUIPart)
  /// Provider-specific content (`kind` is `{provider}.{type}`).
  case custom(CustomContentUIPart)
  case reasoning(ReasoningUIPart)
  /// A tool invocation: `tool-{name}` (static) or `dynamic-tool`.
  case tool(ToolUIPart)
  case sourceURL(SourceURLUIPart)
  case sourceDocument(SourceDocumentUIPart)
  case file(FileUIPart)
  case reasoningFile(ReasoningFileUIPart)
  /// An application-defined data part (`data-{name}`).
  case data(DataUIPart)
  /// The start of a step, e.g. between tool rounds.
  case stepStart

  /// The upstream `type` discriminator.
  public var type: String {
    switch self {
    case .text: "text"
    case .custom: "custom"
    case .reasoning: "reasoning"
    case .tool(let part): part.type
    case .sourceURL: "source-url"
    case .sourceDocument: "source-document"
    case .file: "file"
    case .reasoningFile: "reasoning-file"
    case .data(let part): "data-\(part.name)"
    case .stepStart: "step-start"
    }
  }

  /// The tool invocation, for `tool-*` and `dynamic-tool` parts.
  public var toolPart: ToolUIPart? {
    if case .tool(let part) = self { return part }
    return nil
  }
}

/// Whether a streamed text or reasoning part is still receiving deltas.
public enum UIPartStreamingState: String, Sendable, Hashable, Codable {
  case streaming, done
}

/// A text part. Mirrors upstream `TextUIPart`.
public struct TextUIPart: Sendable, Equatable {
  public var text: String
  public var state: UIPartStreamingState?
  public var providerMetadata: ProviderMetadata?

  public init(text: String, state: UIPartStreamingState? = nil, providerMetadata: ProviderMetadata? = nil) {
    self.text = text
    self.state = state
    self.providerMetadata = providerMetadata
  }
}

/// Provider-specific content. Mirrors upstream `CustomContentUIPart`.
public struct CustomContentUIPart: Sendable, Equatable {
  /// `{provider}.{provider-type}`.
  public var kind: String
  public var providerMetadata: ProviderMetadata?

  public init(kind: String, providerMetadata: ProviderMetadata? = nil) {
    self.kind = kind
    self.providerMetadata = providerMetadata
  }
}

/// A reasoning part. Mirrors upstream `ReasoningUIPart`.
public struct ReasoningUIPart: Sendable, Equatable {
  public var id: String?
  public var text: String
  public var state: UIPartStreamingState?
  public var providerMetadata: ProviderMetadata?

  public init(
    id: String? = nil, text: String, state: UIPartStreamingState? = nil, providerMetadata: ProviderMetadata? = nil
  ) {
    self.id = id
    self.text = text
    self.state = state
    self.providerMetadata = providerMetadata
  }
}

/// A URL source. Mirrors upstream `SourceUrlUIPart`.
public struct SourceURLUIPart: Sendable, Equatable {
  public var sourceId: String
  public var url: String
  public var title: String?
  public var providerMetadata: ProviderMetadata?

  public init(sourceId: String, url: String, title: String? = nil, providerMetadata: ProviderMetadata? = nil) {
    self.sourceId = sourceId
    self.url = url
    self.title = title
    self.providerMetadata = providerMetadata
  }
}

/// A document source. Mirrors upstream `SourceDocumentUIPart`.
public struct SourceDocumentUIPart: Sendable, Equatable {
  public var sourceId: String
  public var mediaType: String
  public var title: String
  public var filename: String?
  public var providerMetadata: ProviderMetadata?

  public init(
    sourceId: String, mediaType: String, title: String, filename: String? = nil,
    providerMetadata: ProviderMetadata? = nil
  ) {
    self.sourceId = sourceId
    self.mediaType = mediaType
    self.title = title
    self.filename = filename
    self.providerMetadata = providerMetadata
  }
}

/// A file. Mirrors upstream `FileUIPart`.
public struct FileUIPart: Sendable, Equatable {
  /// IANA media type of the file.
  public var mediaType: String
  public var filename: String?
  /// A hosted URL or a data URL.
  public var url: String
  /// A provider file reference; takes precedence over `url` when converting to model messages.
  public var providerReference: SharedV4ProviderReference?
  public var providerMetadata: ProviderMetadata?

  public init(
    mediaType: String, filename: String? = nil, url: String, providerReference: SharedV4ProviderReference? = nil,
    providerMetadata: ProviderMetadata? = nil
  ) {
    self.mediaType = mediaType
    self.filename = filename
    self.url = url
    self.providerReference = providerReference
    self.providerMetadata = providerMetadata
  }

  /// A file part with the data inlined as a `data:` URL.
  public init(data: Data, mediaType: String, filename: String? = nil) {
    self.init(mediaType: mediaType, filename: filename, url: "data:\(mediaType);base64,\(data.base64EncodedString())")
  }
}

/// A file generated as part of reasoning. Mirrors upstream `ReasoningFileUIPart`.
public struct ReasoningFileUIPart: Sendable, Equatable {
  public var mediaType: String
  public var url: String
  public var providerMetadata: ProviderMetadata?

  public init(mediaType: String, url: String, providerMetadata: ProviderMetadata? = nil) {
    self.mediaType = mediaType
    self.url = url
    self.providerMetadata = providerMetadata
  }
}

/// An application-defined data part. Mirrors upstream `DataUIPart`.
public struct DataUIPart: Sendable, Equatable {
  /// The data type name, without the `data-` prefix.
  public var name: String
  /// Parts with an id are updated in place when a chunk with the same id arrives.
  public var id: String?
  public var data: JSONValue

  public init(name: String, id: String? = nil, data: JSONValue) {
    self.name = name
    self.id = id
    self.data = data
  }
}

/// The lifecycle state of a tool invocation. Mirrors upstream `UIToolInvocation['state']`.
public enum ToolUIPartState: String, Sendable, Hashable, Codable {
  case inputStreaming = "input-streaming"
  case inputAvailable = "input-available"
  case approvalRequested = "approval-requested"
  case approvalResponded = "approval-responded"
  case outputAvailable = "output-available"
  case outputError = "output-error"
  case outputDenied = "output-denied"
}

/// A tool approval request and, once answered, its response.
public struct ToolUIApproval: Sendable, Equatable {
  public var id: String
  /// `nil` until the user responds.
  public var approved: Bool?
  public var descriptor: JSONValue?
  /// Why approval was requested.
  public var requestReason: String?
  /// Why the user approved or denied.
  public var reason: String?
  public var isAutomatic: Bool?
  public var signature: String?
  public var inputSchemaInput: JSONValue?

  public init(
    id: String, approved: Bool? = nil, descriptor: JSONValue? = nil, requestReason: String? = nil,
    reason: String? = nil, isAutomatic: Bool? = nil, signature: String? = nil, inputSchemaInput: JSONValue? = nil
  ) {
    self.id = id
    self.approved = approved
    self.descriptor = descriptor
    self.requestReason = requestReason
    self.reason = reason
    self.isAutomatic = isAutomatic
    self.signature = signature
    self.inputSchemaInput = inputSchemaInput
  }
}

/// A tool invocation. Mirrors upstream `ToolUIPart` (`tool-{name}`) and
/// `DynamicToolUIPart` (`dynamic-tool`), which share the same fields.
public struct ToolUIPart: Sendable, Equatable {
  public var toolName: String
  /// `true` for `dynamic-tool` parts (tools unknown at compile time, e.g. MCP tools).
  public var isDynamic: Bool
  public var toolCallId: String
  public var state: ToolUIPartState
  public var title: String?
  public var toolMetadata: JSONObject?
  /// Whether the provider executed the tool.
  public var providerExecuted: Bool?
  /// The (possibly partial, while streaming) tool input.
  public var input: JSONValue?
  public var output: JSONValue?
  public var errorText: String?
  /// Deprecated upstream: the unparsable input of a static tool whose input failed.
  public var rawInput: JSONValue?
  /// Preliminary outputs are superseded by the final output.
  public var preliminary: Bool?
  public var callProviderMetadata: ProviderMetadata?
  public var resultProviderMetadata: ProviderMetadata?
  public var approval: ToolUIApproval?

  public init(
    toolName: String,
    isDynamic: Bool = false,
    toolCallId: String,
    state: ToolUIPartState,
    title: String? = nil,
    toolMetadata: JSONObject? = nil,
    providerExecuted: Bool? = nil,
    input: JSONValue? = nil,
    output: JSONValue? = nil,
    errorText: String? = nil,
    rawInput: JSONValue? = nil,
    preliminary: Bool? = nil,
    callProviderMetadata: ProviderMetadata? = nil,
    resultProviderMetadata: ProviderMetadata? = nil,
    approval: ToolUIApproval? = nil
  ) {
    self.toolName = toolName
    self.isDynamic = isDynamic
    self.toolCallId = toolCallId
    self.state = state
    self.title = title
    self.toolMetadata = toolMetadata
    self.providerExecuted = providerExecuted
    self.input = input
    self.output = output
    self.errorText = errorText
    self.rawInput = rawInput
    self.preliminary = preliminary
    self.callProviderMetadata = callProviderMetadata
    self.resultProviderMetadata = resultProviderMetadata
    self.approval = approval
  }

  /// `tool-{name}` or `dynamic-tool`.
  public var type: String { isDynamic ? "dynamic-tool" : "tool-\(toolName)" }
}

extension UIMessage {
  /// The concatenated text of all text parts.
  public var text: String {
    parts.compactMap { if case .text(let part) = $0 { part.text } else { nil } }.joined()
  }

  /// All tool invocations in the message.
  public var toolParts: [ToolUIPart] { parts.compactMap(\.toolPart) }
}

// MARK: - JSON

extension UIMessage {
  /// The upstream JSON form of the message.
  public var json: JSONValue {
    uiJSON([
      ("id", .string(id)),
      ("role", .string(role.rawValue)),
      ("metadata", metadata),
      ("parts", .array(parts.map(\.json))),
    ])
  }

  /// Decodes a message from its upstream JSON form.
  public init(json: JSONValue) throws {
    try self.init(json: json, path: "message")
  }

  init(json: JSONValue, path: String) throws {
    let reader = try UIJSONReader(json, path: path)
    let roleString = try reader.string("role")
    guard let role = Role(rawValue: roleString) else {
      throw MessageDecodingError(message: "Invalid role '\(roleString)' at \(path).role.")
    }
    guard let partsJSON = reader.object["parts"]?.arrayValue else {
      throw MessageDecodingError(message: "Expected an array at \(path).parts.")
    }
    self.init(
      id: try reader.string("id"),
      role: role,
      metadata: reader.object["metadata"],
      parts: try partsJSON.enumerated().map { index, part in
        try UIMessagePart(json: part, path: "\(path).parts[\(index)]")
      })
  }
}

extension UIMessage: Codable {
  public init(from decoder: any Decoder) throws {
    try self.init(json: JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}

extension UIMessagePart {
  public var json: JSONValue {
    switch self {
    case .text(let part):
      uiJSON([
        ("type", "text"), ("text", .string(part.text)), ("state", uiJSON(part.state?.rawValue)),
        ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .custom(let part):
      uiJSON([("type", "custom"), ("kind", .string(part.kind)), ("providerMetadata", uiJSON(part.providerMetadata))])
    case .reasoning(let part):
      uiJSON([
        ("type", "reasoning"), ("id", uiJSON(part.id)), ("text", .string(part.text)),
        ("state", uiJSON(part.state?.rawValue)), ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .tool(let part):
      part.json
    case .sourceURL(let part):
      uiJSON([
        ("type", "source-url"), ("sourceId", .string(part.sourceId)), ("url", .string(part.url)),
        ("title", uiJSON(part.title)), ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .sourceDocument(let part):
      uiJSON([
        ("type", "source-document"), ("sourceId", .string(part.sourceId)), ("mediaType", .string(part.mediaType)),
        ("title", .string(part.title)), ("filename", uiJSON(part.filename)),
        ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .file(let part):
      uiJSON([
        ("type", "file"), ("mediaType", .string(part.mediaType)), ("filename", uiJSON(part.filename)),
        ("url", .string(part.url)), ("providerReference", uiJSON(part.providerReference)),
        ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .reasoningFile(let part):
      uiJSON([
        ("type", "reasoning-file"), ("mediaType", .string(part.mediaType)), ("url", .string(part.url)),
        ("providerMetadata", uiJSON(part.providerMetadata)),
      ])
    case .data(let part):
      uiJSON([("type", .string("data-\(part.name)")), ("id", uiJSON(part.id)), ("data", part.data)])
    case .stepStart:
      ["type": "step-start"]
    }
  }

  public init(json: JSONValue) throws {
    try self.init(json: json, path: "part")
  }

  init(json: JSONValue, path: String) throws {
    let reader = try UIJSONReader(json, path: path)
    let type = try reader.string("type")
    switch type {
    case "text":
      self = .text(
        TextUIPart(
          text: try reader.string("text"), state: try Self.streamingState(reader),
          providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "custom":
      self = .custom(
        CustomContentUIPart(
          kind: try reader.string("kind"), providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "reasoning":
      self = .reasoning(
        ReasoningUIPart(
          id: try reader.optionalString("id"), text: try reader.string("text"), state: try Self.streamingState(reader),
          providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "source-url":
      self = .sourceURL(
        SourceURLUIPart(
          sourceId: try reader.string("sourceId"), url: try reader.string("url"),
          title: try reader.optionalString("title"), providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "source-document":
      self = .sourceDocument(
        SourceDocumentUIPart(
          sourceId: try reader.string("sourceId"), mediaType: try reader.string("mediaType"),
          title: try reader.string("title"), filename: try reader.optionalString("filename"),
          providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "file":
      self = .file(
        FileUIPart(
          mediaType: try reader.string("mediaType"), filename: try reader.optionalString("filename"),
          url: try reader.string("url"), providerReference: try reader.stringMap("providerReference"),
          providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "reasoning-file":
      self = .reasoningFile(
        ReasoningFileUIPart(
          mediaType: try reader.string("mediaType"), url: try reader.string("url"),
          providerMetadata: try reader.providerMetadata("providerMetadata")))
    case "step-start":
      self = .stepStart
    case "dynamic-tool":
      self = .tool(try ToolUIPart(reader: reader, toolName: try reader.string("toolName"), isDynamic: true))
    case _ where type.hasPrefix("tool-"):
      self = .tool(try ToolUIPart(reader: reader, toolName: String(type.dropFirst(5)), isDynamic: false))
    case _ where type.hasPrefix("data-"):
      self = .data(
        DataUIPart(name: String(type.dropFirst(5)), id: try reader.optionalString("id"), data: reader.object["data"] ?? .null))
    default:
      throw MessageDecodingError(message: "Unknown part type '\(type)' at \(path).type.")
    }
  }

  private static func streamingState(_ reader: UIJSONReader) throws -> UIPartStreamingState? {
    guard let raw = try reader.optionalString("state") else { return nil }
    guard let state = UIPartStreamingState(rawValue: raw) else {
      throw MessageDecodingError(message: "Invalid state '\(raw)' at \(reader.path).state.")
    }
    return state
  }
}

extension UIMessagePart: Codable {
  public init(from decoder: any Decoder) throws {
    try self.init(json: JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}

extension ToolUIApproval {
  var json: JSONValue {
    uiJSON([
      ("id", .string(id)), ("approved", uiJSON(approved)), ("descriptor", descriptor),
      ("requestReason", uiJSON(requestReason)), ("reason", uiJSON(reason)), ("isAutomatic", uiJSON(isAutomatic)),
      ("signature", uiJSON(signature)), ("inputSchemaInput", inputSchemaInput),
    ])
  }

  init(json: JSONValue, path: String) throws {
    let reader = try UIJSONReader(json, path: path)
    self.init(
      id: try reader.string("id"), approved: try reader.optionalBool("approved"), descriptor: reader.object["descriptor"],
      requestReason: try reader.optionalString("requestReason"), reason: try reader.optionalString("reason"),
      isAutomatic: try reader.optionalBool("isAutomatic"), signature: try reader.optionalString("signature"),
      inputSchemaInput: reader.object["inputSchemaInput"])
  }
}

extension ToolUIPart {
  public var json: JSONValue {
    uiJSON([
      ("type", .string(type)),
      ("toolName", isDynamic ? .string(toolName) : nil),
      ("toolCallId", .string(toolCallId)),
      ("state", .string(state.rawValue)),
      ("title", uiJSON(title)),
      ("toolMetadata", uiJSON(toolMetadata)),
      ("providerExecuted", uiJSON(providerExecuted)),
      ("input", input),
      ("output", output),
      ("errorText", uiJSON(errorText)),
      ("rawInput", rawInput),
      ("preliminary", uiJSON(preliminary)),
      ("callProviderMetadata", uiJSON(callProviderMetadata)),
      ("resultProviderMetadata", uiJSON(resultProviderMetadata)),
      ("approval", approval?.json),
    ])
  }

  init(reader: UIJSONReader, toolName: String, isDynamic: Bool) throws {
    let rawState = try reader.string("state")
    guard let state = ToolUIPartState(rawValue: rawState) else {
      throw MessageDecodingError(message: "Invalid tool state '\(rawState)' at \(reader.path).state.")
    }
    self.init(
      toolName: toolName,
      isDynamic: isDynamic,
      toolCallId: try reader.string("toolCallId"),
      state: state,
      title: try reader.optionalString("title"),
      toolMetadata: try reader.optionalObject("toolMetadata"),
      providerExecuted: try reader.optionalBool("providerExecuted"),
      input: reader.object["input"],
      output: reader.object["output"],
      errorText: try reader.optionalString("errorText"),
      rawInput: reader.object["rawInput"],
      preliminary: try reader.optionalBool("preliminary"),
      callProviderMetadata: try reader.providerMetadata("callProviderMetadata"),
      resultProviderMetadata: try reader.providerMetadata("resultProviderMetadata"),
      approval: try reader.object["approval"].map { try ToolUIApproval(json: $0, path: "\(reader.path).approval") })
  }

  /// Enforces the per-state requirements of upstream's `uiMessagesSchema`
  /// (e.g. `output-error` needs `errorText`) and drops the fields that schema
  /// strips for the state.
  func validatedStructure(path: String) throws -> ToolUIPart {
    func forbid(_ fields: [(String, Bool)]) throws {
      for (name, isPresent) in fields where isPresent {
        throw MessageDecodingError(message: "Field \(path).\(name) is not allowed in state '\(state.rawValue)'.")
      }
    }
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw MessageDecodingError(message: "State '\(state.rawValue)' requires \(message) at \(path).") }
    }

    var part = self
    switch state {
    case .inputStreaming, .inputAvailable:
      try forbid([("output", output != nil), ("errorText", errorText != nil), ("approval", approval != nil)])
    case .approvalRequested:
      try forbid([("output", output != nil), ("errorText", errorText != nil)])
      try require(approval != nil && approval?.approved == nil && approval?.reason == nil, "an unanswered approval")
    case .approvalResponded:
      try forbid([("output", output != nil), ("errorText", errorText != nil)])
      try require(approval?.approved != nil, "approval.approved")
    case .outputAvailable:
      try forbid([("errorText", errorText != nil)])
      try require(approval == nil || approval?.approved == true, "a granted approval")
    case .outputError:
      try forbid([("output", output != nil)])
      try require(errorText != nil, "errorText")
      try require(approval == nil || approval?.approved == true, "a granted approval")
    case .outputDenied:
      try forbid([("output", output != nil), ("errorText", errorText != nil)])
      try require(approval?.approved == false, "a denied approval")
    }
    if state != .outputError { part.rawInput = nil }
    if state != .outputAvailable { part.preliminary = nil }
    if state != .outputAvailable && state != .outputError { part.resultProviderMetadata = nil }
    return part
  }
}
