import Foundation

/// The start of a streamed tool input.
public struct UIToolInputStartChunk: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var dynamic: Bool?
  public var title: String?

  public init(
    toolCallId: String, toolName: String, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil,
    toolMetadata: JSONObject? = nil, dynamic: Bool? = nil, title: String? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.dynamic = dynamic
    self.title = title
  }
}

/// A complete tool call. Also passed to `onToolCall` on the client.
public struct UIToolInputAvailableChunk: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var input: JSONValue
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var dynamic: Bool?
  public var title: String?

  public init(
    toolCallId: String, toolName: String, input: JSONValue, providerExecuted: Bool? = nil,
    providerMetadata: ProviderMetadata? = nil, toolMetadata: JSONObject? = nil, dynamic: Bool? = nil,
    title: String? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.input = input
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.dynamic = dynamic
    self.title = title
  }
}

/// A tool call whose input could not be parsed or validated.
public struct UIToolInputErrorChunk: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var input: JSONValue
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var dynamic: Bool?
  public var errorText: String
  public var title: String?

  public init(
    toolCallId: String, toolName: String, input: JSONValue, providerExecuted: Bool? = nil,
    providerMetadata: ProviderMetadata? = nil, toolMetadata: JSONObject? = nil, dynamic: Bool? = nil,
    errorText: String, title: String? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.input = input
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.dynamic = dynamic
    self.errorText = errorText
    self.title = title
  }
}

/// A request for the user to approve a tool call.
public struct UIToolApprovalRequestChunk: Sendable, Equatable {
  public var approvalId: String
  public var toolCallId: String
  public var approvalDescriptor: JSONValue?
  public var inputSchemaInput: JSONValue?
  public var reason: String?
  public var isAutomatic: Bool?
  public var signature: String?

  public init(
    approvalId: String, toolCallId: String, approvalDescriptor: JSONValue? = nil, inputSchemaInput: JSONValue? = nil,
    reason: String? = nil, isAutomatic: Bool? = nil, signature: String? = nil
  ) {
    self.approvalId = approvalId
    self.toolCallId = toolCallId
    self.approvalDescriptor = approvalDescriptor
    self.inputSchemaInput = inputSchemaInput
    self.reason = reason
    self.isAutomatic = isAutomatic
    self.signature = signature
  }
}

/// The response to a tool approval request.
public struct UIToolApprovalResponseChunk: Sendable, Equatable {
  public var approvalId: String
  public var approved: Bool
  public var reason: String?
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?

  public init(
    approvalId: String, approved: Bool, reason: String? = nil, providerExecuted: Bool? = nil,
    providerMetadata: ProviderMetadata? = nil
  ) {
    self.approvalId = approvalId
    self.approved = approved
    self.reason = reason
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
  }
}

/// A tool output.
public struct UIToolOutputAvailableChunk: Sendable, Equatable {
  public var toolCallId: String
  public var output: JSONValue
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var dynamic: Bool?
  public var preliminary: Bool?

  public init(
    toolCallId: String, output: JSONValue, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil,
    toolMetadata: JSONObject? = nil, dynamic: Bool? = nil, preliminary: Bool? = nil
  ) {
    self.toolCallId = toolCallId
    self.output = output
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.dynamic = dynamic
    self.preliminary = preliminary
  }
}

/// A tool execution error.
public struct UIToolOutputErrorChunk: Sendable, Equatable {
  public var toolCallId: String
  public var errorText: String
  public var providerExecuted: Bool?
  public var providerMetadata: ProviderMetadata?
  public var toolMetadata: JSONObject?
  public var dynamic: Bool?

  public init(
    toolCallId: String, errorText: String, providerExecuted: Bool? = nil, providerMetadata: ProviderMetadata? = nil,
    toolMetadata: JSONObject? = nil, dynamic: Bool? = nil
  ) {
    self.toolCallId = toolCallId
    self.errorText = errorText
    self.providerExecuted = providerExecuted
    self.providerMetadata = providerMetadata
    self.toolMetadata = toolMetadata
    self.dynamic = dynamic
  }
}

/// A chunk of the UI message stream protocol (`x-vercel-ai-ui-message-stream: v1`).
/// Mirrors upstream `UIMessageChunk`.
///
/// The server sends chunks as server-sent events (`data: {json}`), and the
/// client folds them into a `UIMessage` with `processUIMessageStream`.
public enum UIMessageChunk: Sendable, Equatable {
  case textStart(id: String, providerMetadata: ProviderMetadata? = nil)
  case textDelta(id: String, delta: String, providerMetadata: ProviderMetadata? = nil)
  case textEnd(id: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningStart(id: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningDelta(id: String, delta: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningEnd(id: String, providerMetadata: ProviderMetadata? = nil)
  case custom(kind: String, providerMetadata: ProviderMetadata? = nil)
  case error(errorText: String)
  case toolInputStart(UIToolInputStartChunk)
  case toolInputDelta(toolCallId: String, inputTextDelta: String)
  case toolInputAvailable(UIToolInputAvailableChunk)
  case toolInputError(UIToolInputErrorChunk)
  case toolApprovalRequest(UIToolApprovalRequestChunk)
  case toolApprovalResponse(UIToolApprovalResponseChunk)
  case toolOutputAvailable(UIToolOutputAvailableChunk)
  case toolOutputError(UIToolOutputErrorChunk)
  case toolOutputDenied(toolCallId: String)
  case sourceURL(sourceId: String, url: String, title: String? = nil, providerMetadata: ProviderMetadata? = nil)
  case sourceDocument(
    sourceId: String, mediaType: String, title: String, filename: String? = nil,
    providerMetadata: ProviderMetadata? = nil)
  case file(url: String, mediaType: String, providerMetadata: ProviderMetadata? = nil)
  case reasoningFile(url: String, mediaType: String, providerMetadata: ProviderMetadata? = nil)
  /// A `data-{name}` part. Transient parts reach `onData` but are not added to the message.
  case data(name: String, id: String? = nil, data: JSONValue, transient: Bool? = nil)
  case startStep
  case finishStep
  /// Discards the parts of the current step, e.g. before a retry.
  case resetStep
  case start(messageId: String? = nil, messageMetadata: JSONValue? = nil)
  case finish(finishReason: FinishReason? = nil, messageMetadata: JSONValue? = nil)
  case abort(reason: String? = nil)
  case messageMetadata(JSONValue)

  /// The upstream `type` discriminator.
  public var type: String {
    switch self {
    case .textStart: "text-start"
    case .textDelta: "text-delta"
    case .textEnd: "text-end"
    case .reasoningStart: "reasoning-start"
    case .reasoningDelta: "reasoning-delta"
    case .reasoningEnd: "reasoning-end"
    case .custom: "custom"
    case .error: "error"
    case .toolInputStart: "tool-input-start"
    case .toolInputDelta: "tool-input-delta"
    case .toolInputAvailable: "tool-input-available"
    case .toolInputError: "tool-input-error"
    case .toolApprovalRequest: "tool-approval-request"
    case .toolApprovalResponse: "tool-approval-response"
    case .toolOutputAvailable: "tool-output-available"
    case .toolOutputError: "tool-output-error"
    case .toolOutputDenied: "tool-output-denied"
    case .sourceURL: "source-url"
    case .sourceDocument: "source-document"
    case .file: "file"
    case .reasoningFile: "reasoning-file"
    case .data(let name, _, _, _): "data-\(name)"
    case .startStep: "start-step"
    case .finishStep: "finish-step"
    case .resetStep: "reset-step"
    case .start: "start"
    case .finish: "finish"
    case .abort: "abort"
    case .messageMetadata: "message-metadata"
    }
  }
}

// MARK: - JSON

extension UIMessageChunk {
  /// The upstream JSON form of the chunk.
  public var json: JSONValue {
    let type = JSONValue.string(type)
    switch self {
    case .textStart(let id, let metadata), .textEnd(let id, let metadata), .reasoningStart(let id, let metadata),
      .reasoningEnd(let id, let metadata):
      return uiJSON([("type", type), ("id", .string(id)), ("providerMetadata", uiJSON(metadata))])
    case .textDelta(let id, let delta, let metadata), .reasoningDelta(let id, let delta, let metadata):
      return uiJSON([
        ("type", type), ("id", .string(id)), ("delta", .string(delta)), ("providerMetadata", uiJSON(metadata)),
      ])
    case .custom(let kind, let metadata):
      return uiJSON([("type", type), ("kind", .string(kind)), ("providerMetadata", uiJSON(metadata))])
    case .error(let errorText):
      return uiJSON([("type", type), ("errorText", .string(errorText))])
    case .toolInputStart(let chunk):
      return uiJSON([
        ("type", type), ("toolCallId", .string(chunk.toolCallId)), ("toolName", .string(chunk.toolName)),
        ("providerExecuted", uiJSON(chunk.providerExecuted)), ("providerMetadata", uiJSON(chunk.providerMetadata)),
        ("toolMetadata", uiJSON(chunk.toolMetadata)), ("dynamic", uiJSON(chunk.dynamic)), ("title", uiJSON(chunk.title)),
      ])
    case .toolInputDelta(let toolCallId, let delta):
      return uiJSON([("type", type), ("toolCallId", .string(toolCallId)), ("inputTextDelta", .string(delta))])
    case .toolInputAvailable(let chunk):
      return uiJSON([
        ("type", type), ("toolCallId", .string(chunk.toolCallId)), ("toolName", .string(chunk.toolName)),
        ("input", chunk.input), ("providerExecuted", uiJSON(chunk.providerExecuted)),
        ("providerMetadata", uiJSON(chunk.providerMetadata)), ("toolMetadata", uiJSON(chunk.toolMetadata)),
        ("dynamic", uiJSON(chunk.dynamic)), ("title", uiJSON(chunk.title)),
      ])
    case .toolInputError(let chunk):
      return uiJSON([
        ("type", type), ("toolCallId", .string(chunk.toolCallId)), ("toolName", .string(chunk.toolName)),
        ("input", chunk.input), ("providerExecuted", uiJSON(chunk.providerExecuted)),
        ("providerMetadata", uiJSON(chunk.providerMetadata)), ("toolMetadata", uiJSON(chunk.toolMetadata)),
        ("dynamic", uiJSON(chunk.dynamic)), ("errorText", .string(chunk.errorText)), ("title", uiJSON(chunk.title)),
      ])
    case .toolApprovalRequest(let chunk):
      return uiJSON([
        ("type", type), ("approvalId", .string(chunk.approvalId)), ("toolCallId", .string(chunk.toolCallId)),
        ("approvalDescriptor", chunk.approvalDescriptor), ("inputSchemaInput", chunk.inputSchemaInput),
        ("reason", uiJSON(chunk.reason)), ("isAutomatic", uiJSON(chunk.isAutomatic)),
        ("signature", uiJSON(chunk.signature)),
      ])
    case .toolApprovalResponse(let chunk):
      return uiJSON([
        ("type", type), ("approvalId", .string(chunk.approvalId)), ("approved", .bool(chunk.approved)),
        ("reason", uiJSON(chunk.reason)), ("providerExecuted", uiJSON(chunk.providerExecuted)),
        ("providerMetadata", uiJSON(chunk.providerMetadata)),
      ])
    case .toolOutputAvailable(let chunk):
      return uiJSON([
        ("type", type), ("toolCallId", .string(chunk.toolCallId)), ("output", chunk.output),
        ("providerExecuted", uiJSON(chunk.providerExecuted)), ("providerMetadata", uiJSON(chunk.providerMetadata)),
        ("toolMetadata", uiJSON(chunk.toolMetadata)), ("dynamic", uiJSON(chunk.dynamic)),
        ("preliminary", uiJSON(chunk.preliminary)),
      ])
    case .toolOutputError(let chunk):
      return uiJSON([
        ("type", type), ("toolCallId", .string(chunk.toolCallId)), ("errorText", .string(chunk.errorText)),
        ("providerExecuted", uiJSON(chunk.providerExecuted)), ("providerMetadata", uiJSON(chunk.providerMetadata)),
        ("toolMetadata", uiJSON(chunk.toolMetadata)), ("dynamic", uiJSON(chunk.dynamic)),
      ])
    case .toolOutputDenied(let toolCallId):
      return uiJSON([("type", type), ("toolCallId", .string(toolCallId))])
    case .sourceURL(let sourceId, let url, let title, let metadata):
      return uiJSON([
        ("type", type), ("sourceId", .string(sourceId)), ("url", .string(url)), ("title", uiJSON(title)),
        ("providerMetadata", uiJSON(metadata)),
      ])
    case .sourceDocument(let sourceId, let mediaType, let title, let filename, let metadata):
      return uiJSON([
        ("type", type), ("sourceId", .string(sourceId)), ("mediaType", .string(mediaType)), ("title", .string(title)),
        ("filename", uiJSON(filename)), ("providerMetadata", uiJSON(metadata)),
      ])
    case .file(let url, let mediaType, let metadata), .reasoningFile(let url, let mediaType, let metadata):
      return uiJSON([
        ("type", type), ("url", .string(url)), ("mediaType", .string(mediaType)), ("providerMetadata", uiJSON(metadata)),
      ])
    case .data(_, let id, let data, let transient):
      return uiJSON([("type", type), ("id", uiJSON(id)), ("data", data), ("transient", uiJSON(transient))])
    case .startStep, .finishStep, .resetStep:
      return uiJSON([("type", type)])
    case .start(let messageId, let metadata):
      return uiJSON([("type", type), ("messageId", uiJSON(messageId)), ("messageMetadata", metadata)])
    case .finish(let finishReason, let metadata):
      return uiJSON([("type", type), ("finishReason", uiJSON(finishReason?.rawValue)), ("messageMetadata", metadata)])
    case .abort(let reason):
      return uiJSON([("type", type), ("reason", uiJSON(reason))])
    case .messageMetadata(let metadata):
      return uiJSON([("type", type), ("messageMetadata", metadata)])
    }
  }

  /// Decodes a chunk from its upstream JSON form. Unknown fields are ignored.
  public init(json: JSONValue) throws {
    let reader = try UIJSONReader(json, path: "chunk")
    let type = try reader.string("type")
    let metadata = { try reader.providerMetadata("providerMetadata") }

    switch type {
    case "text-start": self = .textStart(id: try reader.string("id"), providerMetadata: try metadata())
    case "text-delta":
      self = .textDelta(id: try reader.string("id"), delta: try reader.string("delta"), providerMetadata: try metadata())
    case "text-end": self = .textEnd(id: try reader.string("id"), providerMetadata: try metadata())
    case "reasoning-start": self = .reasoningStart(id: try reader.string("id"), providerMetadata: try metadata())
    case "reasoning-delta":
      self = .reasoningDelta(
        id: try reader.string("id"), delta: try reader.string("delta"), providerMetadata: try metadata())
    case "reasoning-end": self = .reasoningEnd(id: try reader.string("id"), providerMetadata: try metadata())
    case "custom": self = .custom(kind: try reader.string("kind"), providerMetadata: try metadata())
    case "error": self = .error(errorText: try reader.string("errorText"))
    case "tool-input-start":
      self = .toolInputStart(
        UIToolInputStartChunk(
          toolCallId: try reader.string("toolCallId"), toolName: try reader.string("toolName"),
          providerExecuted: try reader.optionalBool("providerExecuted"), providerMetadata: try metadata(),
          toolMetadata: try reader.optionalObject("toolMetadata"), dynamic: try reader.optionalBool("dynamic"),
          title: try reader.optionalString("title")))
    case "tool-input-delta":
      self = .toolInputDelta(
        toolCallId: try reader.string("toolCallId"), inputTextDelta: try reader.string("inputTextDelta"))
    case "tool-input-available":
      self = .toolInputAvailable(
        UIToolInputAvailableChunk(
          toolCallId: try reader.string("toolCallId"), toolName: try reader.string("toolName"),
          input: reader.object["input"] ?? .null, providerExecuted: try reader.optionalBool("providerExecuted"),
          providerMetadata: try metadata(), toolMetadata: try reader.optionalObject("toolMetadata"),
          dynamic: try reader.optionalBool("dynamic"), title: try reader.optionalString("title")))
    case "tool-input-error":
      self = .toolInputError(
        UIToolInputErrorChunk(
          toolCallId: try reader.string("toolCallId"), toolName: try reader.string("toolName"),
          input: reader.object["input"] ?? .null, providerExecuted: try reader.optionalBool("providerExecuted"),
          providerMetadata: try metadata(), toolMetadata: try reader.optionalObject("toolMetadata"),
          dynamic: try reader.optionalBool("dynamic"), errorText: try reader.string("errorText"),
          title: try reader.optionalString("title")))
    case "tool-approval-request":
      self = .toolApprovalRequest(
        UIToolApprovalRequestChunk(
          approvalId: try reader.string("approvalId"), toolCallId: try reader.string("toolCallId"),
          approvalDescriptor: reader.object["approvalDescriptor"], inputSchemaInput: reader.object["inputSchemaInput"],
          reason: try reader.optionalString("reason"), isAutomatic: try reader.optionalBool("isAutomatic"),
          signature: try reader.optionalString("signature")))
    case "tool-approval-response":
      self = .toolApprovalResponse(
        UIToolApprovalResponseChunk(
          approvalId: try reader.string("approvalId"), approved: try reader.bool("approved"),
          reason: try reader.optionalString("reason"), providerExecuted: try reader.optionalBool("providerExecuted"),
          providerMetadata: try metadata()))
    case "tool-output-available":
      self = .toolOutputAvailable(
        UIToolOutputAvailableChunk(
          toolCallId: try reader.string("toolCallId"), output: reader.object["output"] ?? .null,
          providerExecuted: try reader.optionalBool("providerExecuted"), providerMetadata: try metadata(),
          toolMetadata: try reader.optionalObject("toolMetadata"), dynamic: try reader.optionalBool("dynamic"),
          preliminary: try reader.optionalBool("preliminary")))
    case "tool-output-error":
      self = .toolOutputError(
        UIToolOutputErrorChunk(
          toolCallId: try reader.string("toolCallId"), errorText: try reader.string("errorText"),
          providerExecuted: try reader.optionalBool("providerExecuted"), providerMetadata: try metadata(),
          toolMetadata: try reader.optionalObject("toolMetadata"), dynamic: try reader.optionalBool("dynamic")))
    case "tool-output-denied": self = .toolOutputDenied(toolCallId: try reader.string("toolCallId"))
    case "source-url":
      self = .sourceURL(
        sourceId: try reader.string("sourceId"), url: try reader.string("url"), title: try reader.optionalString("title"),
        providerMetadata: try metadata())
    case "source-document":
      self = .sourceDocument(
        sourceId: try reader.string("sourceId"), mediaType: try reader.string("mediaType"),
        title: try reader.string("title"), filename: try reader.optionalString("filename"),
        providerMetadata: try metadata())
    case "file":
      self = .file(url: try reader.string("url"), mediaType: try reader.string("mediaType"), providerMetadata: try metadata())
    case "reasoning-file":
      self = .reasoningFile(
        url: try reader.string("url"), mediaType: try reader.string("mediaType"), providerMetadata: try metadata())
    case "start-step": self = .startStep
    case "finish-step": self = .finishStep
    case "reset-step": self = .resetStep
    case "start":
      self = .start(messageId: try reader.optionalString("messageId"), messageMetadata: reader.object["messageMetadata"])
    case "finish":
      var finishReason: FinishReason?
      if let raw = try reader.optionalString("finishReason") {
        guard let reason = FinishReason(rawValue: raw) else {
          throw MessageDecodingError(message: "Invalid finish reason '\(raw)' at chunk.finishReason.")
        }
        finishReason = reason
      }
      self = .finish(finishReason: finishReason, messageMetadata: reader.object["messageMetadata"])
    case "abort": self = .abort(reason: try reader.optionalString("reason"))
    case "message-metadata": self = .messageMetadata(reader.object["messageMetadata"] ?? .null)
    case _ where type.hasPrefix("data-"):
      self = .data(
        name: String(type.dropFirst(5)), id: try reader.optionalString("id"), data: reader.object["data"] ?? .null,
        transient: try reader.optionalBool("transient"))
    default:
      throw MessageDecodingError(message: "Unknown chunk type '\(type)'.")
    }
  }
}

extension UIMessageChunk: Codable {
  public init(from decoder: any Decoder) throws {
    try self.init(json: JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}
