import Foundation

/// A message could not be decoded from JSON.
public struct MessageDecodingError: AISDKError {
  public let name = "AI_MessageDecodingError"
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

// MARK: - JSON helpers

private func object(_ value: JSONValue, _ context: String) throws -> JSONObject {
  guard let object = value.objectValue else {
    throw MessageDecodingError(message: "Expected an object for \(context), got \(value.jsonString()).")
  }
  return object
}

private func string(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = object[key]?.stringValue else {
    throw MessageDecodingError(message: "Missing string field '\(key)'.")
  }
  return value
}

private func decodeProviderOptions(_ object: JSONObject, _ key: String = "providerOptions") -> ProviderOptions? {
  guard let options = object[key]?.objectValue else { return nil }
  return options.compactMapValues(\.objectValue)
}

private func encodeProviderOptions(_ options: ProviderOptions?) -> JSONValue? {
  options.map { .object($0.mapValues(JSONValue.object)) }
}

private func build(_ entries: [(String, JSONValue?)]) -> JSONValue {
  var object: JSONObject = [:]
  for (key, value) in entries {
    if let value { object[key] = value }
  }
  return .object(object)
}

// MARK: - FileData

extension SharedV4FileData {
  /// JSON form: base64 or URL strings, or `{type: 'reference' | 'text' | 'data' | 'url'}` objects.
  var messageJSON: JSONValue {
    switch self {
    case .data(let data): .string(data.base64EncodedString())
    case .base64(let string): .string(string)
    case .url(let url, _): .string(url.absoluteString)
    case .reference(let reference): ["type": "reference", "reference": .object(reference.mapValues(JSONValue.string))]
    case .text(let text): ["type": "text", "text": .string(text)]
    }
  }

  init(messageJSON value: JSONValue) throws {
    if let string = value.stringValue {
      self = Self(dataContent: string)
      return
    }
    let object = try object(value, "file data")
    switch object["type"]?.stringValue {
    case "reference":
      self = .reference(object["reference"]?.objectValue?.compactMapValues(\.stringValue) ?? [:])
    case "text":
      self = .text(try string(object, "text"))
    case "data":
      self = Self(dataContent: try string(object, "data"))
    case "url":
      guard let url = URL(string: try string(object, "url")) else {
        throw MessageDecodingError(message: "Invalid URL in file data.")
      }
      self = .url(url, originalURL: object["originalUrl"]?.stringValue)
    default:
      throw MessageDecodingError(message: "Unknown file data \(value.jsonString()).")
    }
  }

  /// Interprets a string as a URL when it has a scheme, and as base64 otherwise.
  /// Base64 text never contains a colon.
  init(dataContent string: String) {
    if string.contains(":"), let url = URL(string: string), url.scheme != nil {
      self = .url(url)
    } else {
      self = .base64(string)
    }
  }
}

// MARK: - ToolResultOutput

extension ToolResultOutput {
  var json: JSONValue {
    switch self {
    case .text(let value, let options):
      build([("type", "text"), ("value", .string(value)), ("providerOptions", encodeProviderOptions(options))])
    case .json(let value, let options):
      build([("type", "json"), ("value", value), ("providerOptions", encodeProviderOptions(options))])
    case .executionDenied(let reason, let options):
      build([
        ("type", "execution-denied"), ("reason", reason.map(JSONValue.string)),
        ("providerOptions", encodeProviderOptions(options)),
      ])
    case .errorText(let value, let options):
      build([("type", "error-text"), ("value", .string(value)), ("providerOptions", encodeProviderOptions(options))])
    case .errorJSON(let value, let options):
      build([("type", "error-json"), ("value", value), ("providerOptions", encodeProviderOptions(options))])
    case .content(let parts):
      ["type": "content", "value": .array(parts.map(\.json))]
    }
  }

  init(json value: JSONValue) throws {
    let object = try object(value, "tool result output")
    let options = decodeProviderOptions(object)
    switch try string(object, "type") {
    case "text": self = .text(try string(object, "value"), providerOptions: options)
    case "json": self = .json(object["value"] ?? .null, providerOptions: options)
    case "execution-denied": self = .executionDenied(reason: object["reason"]?.stringValue, providerOptions: options)
    case "error-text": self = .errorText(try string(object, "value"), providerOptions: options)
    case "error-json": self = .errorJSON(object["value"] ?? .null, providerOptions: options)
    case "content":
      self = .content(try (object["value"]?.arrayValue ?? []).map(ContentPart.init(json:)))
    case let type:
      throw MessageDecodingError(message: "Unknown tool result output type '\(type)'.")
    }
  }
}

extension ToolResultOutput.ContentPart {
  var json: JSONValue {
    switch self {
    case .text(let text, let options):
      build([("type", "text"), ("text", .string(text)), ("providerOptions", encodeProviderOptions(options))])
    case .file(let data, let mediaType, let filename, let options):
      build([
        ("type", "file"), ("data", data.messageJSON), ("mediaType", .string(mediaType)),
        ("filename", filename.map(JSONValue.string)), ("providerOptions", encodeProviderOptions(options)),
      ])
    case .custom(let options):
      build([("type", "custom"), ("providerOptions", encodeProviderOptions(options))])
    }
  }

  init(json value: JSONValue) throws {
    let object = try object(value, "tool result content")
    let options = decodeProviderOptions(object)
    switch try string(object, "type") {
    case "text": self = .text(try string(object, "text"), providerOptions: options)
    case "file":
      self = .file(
        data: try SharedV4FileData(messageJSON: object["data"] ?? .null),
        mediaType: try string(object, "mediaType"),
        filename: object["filename"]?.stringValue, providerOptions: options)
    case "custom": self = .custom(providerOptions: options)
    case let type:
      throw MessageDecodingError(message: "Unknown tool result content type '\(type)'.")
    }
  }
}

// MARK: - Parts

extension ToolCallPart {
  var json: JSONValue {
    build([
      ("type", "tool-call"), ("toolCallId", .string(toolCallId)), ("toolName", .string(toolName)),
      ("input", input), ("providerExecuted", providerExecuted.map(JSONValue.bool)),
      ("providerOptions", encodeProviderOptions(providerOptions)),
    ])
  }

  init(json object: JSONObject) throws {
    self.init(
      toolCallId: try string(object, "toolCallId"), toolName: try string(object, "toolName"),
      input: object["input"] ?? [:], providerExecuted: object["providerExecuted"]?.boolValue,
      providerOptions: decodeProviderOptions(object))
  }
}

extension ToolResultPart {
  var json: JSONValue {
    build([
      ("type", "tool-result"), ("toolCallId", .string(toolCallId)), ("toolName", .string(toolName)),
      ("output", output.json), ("providerOptions", encodeProviderOptions(providerOptions)),
    ])
  }

  init(json object: JSONObject) throws {
    self.init(
      toolCallId: try string(object, "toolCallId"), toolName: try string(object, "toolName"),
      output: try ToolResultOutput(json: object["output"] ?? .null), providerOptions: decodeProviderOptions(object))
  }
}

extension UserContentPart {
  var json: JSONValue {
    switch self {
    case .text(let part):
      build([("type", "text"), ("text", .string(part.text)), ("providerOptions", encodeProviderOptions(part.providerOptions))])
    case .image(let part):
      build([
        ("type", "image"), ("image", part.image.messageJSON), ("mediaType", part.mediaType.map(JSONValue.string)),
        ("providerOptions", encodeProviderOptions(part.providerOptions)),
      ])
    case .file(let part):
      build([
        ("type", "file"), ("data", part.data.messageJSON), ("mediaType", .string(part.mediaType)),
        ("filename", part.filename.map(JSONValue.string)),
        ("providerOptions", encodeProviderOptions(part.providerOptions)),
      ])
    }
  }

  init(json value: JSONValue) throws {
    let object = try object(value, "user content")
    let options = decodeProviderOptions(object)
    switch try string(object, "type") {
    case "text": self = .text(TextPart(text: try string(object, "text"), providerOptions: options))
    case "image":
      self = .image(
        ImagePart(
          image: try SharedV4FileData(messageJSON: object["image"] ?? .null),
          mediaType: object["mediaType"]?.stringValue, providerOptions: options))
    case "file":
      self = .file(
        FilePart(
          data: try SharedV4FileData(messageJSON: object["data"] ?? .null),
          mediaType: try string(object, "mediaType"), filename: object["filename"]?.stringValue,
          providerOptions: options))
    case let type:
      throw MessageDecodingError(message: "Unknown user content type '\(type)'.")
    }
  }
}

extension AssistantContentPart {
  var json: JSONValue {
    switch self {
    case .text(let part):
      build([("type", "text"), ("text", .string(part.text)), ("providerOptions", encodeProviderOptions(part.providerOptions))])
    case .custom(let part):
      build([("type", "custom"), ("kind", .string(part.kind)), ("providerOptions", encodeProviderOptions(part.providerOptions))])
    case .file(let part):
      build([
        ("type", "file"), ("data", part.data.messageJSON), ("mediaType", .string(part.mediaType)),
        ("filename", part.filename.map(JSONValue.string)),
        ("providerOptions", encodeProviderOptions(part.providerOptions)),
      ])
    case .reasoning(let part):
      build([("type", "reasoning"), ("text", .string(part.text)), ("providerOptions", encodeProviderOptions(part.providerOptions))])
    case .reasoningFile(let part):
      build([
        ("type", "reasoning-file"), ("data", part.data.messageJSON), ("mediaType", .string(part.mediaType)),
        ("providerOptions", encodeProviderOptions(part.providerOptions)),
      ])
    case .toolCall(let part): part.json
    case .toolResult(let part): part.json
    case .toolApprovalRequest(let part):
      build([
        ("type", "tool-approval-request"), ("approvalId", .string(part.approvalId)),
        ("toolCallId", .string(part.toolCallId)), ("reason", part.reason.map(JSONValue.string)),
        ("isAutomatic", part.isAutomatic.map(JSONValue.bool)), ("signature", part.signature.map(JSONValue.string)),
      ])
    }
  }

  init(json value: JSONValue) throws {
    let object = try object(value, "assistant content")
    let options = decodeProviderOptions(object)
    switch try string(object, "type") {
    case "text": self = .text(TextPart(text: try string(object, "text"), providerOptions: options))
    case "custom": self = .custom(CustomPart(kind: try string(object, "kind"), providerOptions: options))
    case "file":
      self = .file(
        FilePart(
          data: try SharedV4FileData(messageJSON: object["data"] ?? .null),
          mediaType: try string(object, "mediaType"), filename: object["filename"]?.stringValue,
          providerOptions: options))
    case "reasoning": self = .reasoning(ReasoningPart(text: try string(object, "text"), providerOptions: options))
    case "reasoning-file":
      self = .reasoningFile(
        ReasoningFilePart(
          data: try SharedV4FileData(messageJSON: object["data"] ?? .null),
          mediaType: try string(object, "mediaType"), providerOptions: options))
    case "tool-call": self = .toolCall(try ToolCallPart(json: object))
    case "tool-result": self = .toolResult(try ToolResultPart(json: object))
    case "tool-approval-request":
      self = .toolApprovalRequest(
        ToolApprovalRequest(
          approvalId: try string(object, "approvalId"), toolCallId: try string(object, "toolCallId"),
          reason: object["reason"]?.stringValue, isAutomatic: object["isAutomatic"]?.boolValue,
          signature: object["signature"]?.stringValue))
    case let type:
      throw MessageDecodingError(message: "Unknown assistant content type '\(type)'.")
    }
  }
}

extension ToolContentPart {
  var json: JSONValue {
    switch self {
    case .toolResult(let part): part.json
    case .toolApprovalResponse(let part):
      build([
        ("type", "tool-approval-response"), ("approvalId", .string(part.approvalId)),
        ("approved", .bool(part.approved)), ("reason", part.reason.map(JSONValue.string)),
        ("providerExecuted", part.providerExecuted.map(JSONValue.bool)),
      ])
    }
  }

  init(json value: JSONValue) throws {
    let object = try object(value, "tool content")
    switch try string(object, "type") {
    case "tool-result": self = .toolResult(try ToolResultPart(json: object))
    case "tool-approval-response":
      guard let approved = object["approved"]?.boolValue else {
        throw MessageDecodingError(message: "Missing boolean field 'approved'.")
      }
      self = .toolApprovalResponse(
        ToolApprovalResponse(
          approvalId: try string(object, "approvalId"), approved: approved,
          reason: object["reason"]?.stringValue, providerExecuted: object["providerExecuted"]?.boolValue))
    case let type:
      throw MessageDecodingError(message: "Unknown tool content type '\(type)'.")
    }
  }
}

// MARK: - ModelMessage

extension ModelMessage {
  /// The upstream JSON representation.
  public var json: JSONValue {
    switch self {
    case .system(let message):
      build([
        ("role", "system"), ("content", .string(message.content)),
        ("providerOptions", encodeProviderOptions(message.providerOptions)),
      ])
    case .user(let message):
      build([
        ("role", "user"), ("content", .array(message.content.map(\.json))),
        ("providerOptions", encodeProviderOptions(message.providerOptions)),
      ])
    case .assistant(let message):
      build([
        ("role", "assistant"), ("content", .array(message.content.map(\.json))),
        ("providerOptions", encodeProviderOptions(message.providerOptions)),
      ])
    case .tool(let message):
      build([
        ("role", "tool"), ("content", .array(message.content.map(\.json))),
        ("providerOptions", encodeProviderOptions(message.providerOptions)),
      ])
    }
  }

  /// Parses the upstream JSON representation. String content is accepted for
  /// user and assistant messages.
  public init(json value: JSONValue) throws {
    let object = try object(value, "message")
    let options = decodeProviderOptions(object)
    let content = object["content"] ?? .null

    switch try string(object, "role") {
    case "system":
      self = .system(SystemModelMessage(content: try string(object, "content"), providerOptions: options))
    case "user":
      let parts: [UserContentPart] =
        if let text = content.stringValue {
          [.text(TextPart(text: text))]
        } else {
          try (content.arrayValue ?? []).map(UserContentPart.init(json:))
        }
      self = .user(UserModelMessage(content: parts, providerOptions: options))
    case "assistant":
      let parts: [AssistantContentPart] =
        if let text = content.stringValue {
          [.text(TextPart(text: text))]
        } else {
          try (content.arrayValue ?? []).map(AssistantContentPart.init(json:))
        }
      self = .assistant(AssistantModelMessage(content: parts, providerOptions: options))
    case "tool":
      self = .tool(
        ToolModelMessage(
          content: try (content.arrayValue ?? []).map(ToolContentPart.init(json:)), providerOptions: options))
    case let role:
      throw MessageDecodingError(message: "Unknown message role '\(role)'.")
    }
  }
}

extension ModelMessage: Codable {
  public init(from decoder: any Decoder) throws {
    try self.init(json: JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}
