import Foundation

/// A message in a prompt. Mirrors upstream `ModelMessage`.
///
/// Messages are `Codable` using the upstream JSON shape (`role` and `type`
/// discriminators), so conversations can be persisted and exchanged with
/// TypeScript clients.
public enum ModelMessage: Sendable, Equatable {
  case system(SystemModelMessage)
  case user(UserModelMessage)
  case assistant(AssistantModelMessage)
  case tool(ToolModelMessage)

  public var role: String {
    switch self {
    case .system: "system"
    case .user: "user"
    case .assistant: "assistant"
    case .tool: "tool"
    }
  }

  public var providerOptions: ProviderOptions? {
    switch self {
    case .system(let message): message.providerOptions
    case .user(let message): message.providerOptions
    case .assistant(let message): message.providerOptions
    case .tool(let message): message.providerOptions
    }
  }
}

extension ModelMessage {
  /// A system message.
  public static func system(_ content: String, providerOptions: ProviderOptions? = nil) -> ModelMessage {
    .system(SystemModelMessage(content: content, providerOptions: providerOptions))
  }

  /// A user message with text content.
  public static func user(_ text: String, providerOptions: ProviderOptions? = nil) -> ModelMessage {
    .user(UserModelMessage(content: [.text(TextPart(text: text))], providerOptions: providerOptions))
  }

  /// A user message with content parts.
  public static func user(_ content: [UserContentPart], providerOptions: ProviderOptions? = nil)
    -> ModelMessage
  {
    .user(UserModelMessage(content: content, providerOptions: providerOptions))
  }

  /// An assistant message with text content.
  public static func assistant(_ text: String, providerOptions: ProviderOptions? = nil) -> ModelMessage {
    .assistant(AssistantModelMessage(content: [.text(TextPart(text: text))], providerOptions: providerOptions))
  }

  /// An assistant message with content parts.
  public static func assistant(
    _ content: [AssistantContentPart], providerOptions: ProviderOptions? = nil
  ) -> ModelMessage {
    .assistant(AssistantModelMessage(content: content, providerOptions: providerOptions))
  }

  /// A tool message.
  public static func tool(_ content: [ToolContentPart], providerOptions: ProviderOptions? = nil)
    -> ModelMessage
  {
    .tool(ToolModelMessage(content: content, providerOptions: providerOptions))
  }
}

/// A system message. Mirrors upstream `SystemModelMessage`.
public struct SystemModelMessage: Sendable, Equatable {
  public var content: String
  public var providerOptions: ProviderOptions?

  public init(content: String, providerOptions: ProviderOptions? = nil) {
    self.content = content
    self.providerOptions = providerOptions
  }
}

/// A user message. Mirrors upstream `UserModelMessage`.
public struct UserModelMessage: Sendable, Equatable {
  public var content: [UserContentPart]
  public var providerOptions: ProviderOptions?

  public init(content: [UserContentPart], providerOptions: ProviderOptions? = nil) {
    self.content = content
    self.providerOptions = providerOptions
  }
}

/// An assistant message. Mirrors upstream `AssistantModelMessage`.
public struct AssistantModelMessage: Sendable, Equatable {
  public var content: [AssistantContentPart]
  public var providerOptions: ProviderOptions?

  public init(content: [AssistantContentPart], providerOptions: ProviderOptions? = nil) {
    self.content = content
    self.providerOptions = providerOptions
  }
}

/// A tool message with tool results. Mirrors upstream `ToolModelMessage`.
public struct ToolModelMessage: Sendable, Equatable {
  public var content: [ToolContentPart]
  public var providerOptions: ProviderOptions?

  public init(content: [ToolContentPart], providerOptions: ProviderOptions? = nil) {
    self.content = content
    self.providerOptions = providerOptions
  }
}

/// Content of a user message. Mirrors upstream `UserContent`.
public enum UserContentPart: Sendable, Equatable {
  case text(TextPart)
  case image(ImagePart)
  case file(FilePart)
}

/// Content of an assistant message. Mirrors upstream `AssistantContent`.
public enum AssistantContentPart: Sendable, Equatable {
  case text(TextPart)
  case custom(CustomPart)
  case file(FilePart)
  case reasoning(ReasoningPart)
  case reasoningFile(ReasoningFilePart)
  case toolCall(ToolCallPart)
  case toolResult(ToolResultPart)
  case toolApprovalRequest(ToolApprovalRequest)
}

/// Content of a tool message. Mirrors upstream `ToolContent`.
public enum ToolContentPart: Sendable, Equatable {
  case toolResult(ToolResultPart)
  case toolApprovalResponse(ToolApprovalResponse)
}

/// Text content. Mirrors upstream `TextPart`.
public struct TextPart: Sendable, Equatable {
  public var text: String
  public var providerOptions: ProviderOptions?

  public init(text: String, providerOptions: ProviderOptions? = nil) {
    self.text = text
    self.providerOptions = providerOptions
  }
}

/// Image content. Mirrors upstream `ImagePart`.
public struct ImagePart: Sendable, Equatable {
  /// Image data or URL.
  public var image: FileData
  /// Optional IANA media type. Defaults to `image`.
  public var mediaType: String?
  public var providerOptions: ProviderOptions?

  public init(image: FileData, mediaType: String? = nil, providerOptions: ProviderOptions? = nil) {
    self.image = image
    self.mediaType = mediaType
    self.providerOptions = providerOptions
  }
}

/// File content. Mirrors upstream `FilePart`.
public struct FilePart: Sendable, Equatable {
  public var data: FileData
  public var filename: String?
  /// A full IANA media type or just the top-level segment (e.g. `image`).
  public var mediaType: String
  public var providerOptions: ProviderOptions?

  public init(
    data: FileData, mediaType: String, filename: String? = nil, providerOptions: ProviderOptions? = nil
  ) {
    self.data = data
    self.mediaType = mediaType
    self.filename = filename
    self.providerOptions = providerOptions
  }
}

/// Reasoning content. Mirrors upstream `ReasoningPart`.
public struct ReasoningPart: Sendable, Equatable {
  public var text: String
  public var providerOptions: ProviderOptions?

  public init(text: String, providerOptions: ProviderOptions? = nil) {
    self.text = text
    self.providerOptions = providerOptions
  }
}

/// A file generated during reasoning. Mirrors upstream `ReasoningFilePart`.
public struct ReasoningFilePart: Sendable, Equatable {
  public var data: FileData
  public var mediaType: String
  public var providerOptions: ProviderOptions?

  public init(data: FileData, mediaType: String, providerOptions: ProviderOptions? = nil) {
    self.data = data
    self.mediaType = mediaType
    self.providerOptions = providerOptions
  }
}

/// Provider-specific content. Mirrors upstream `CustomPart`.
public struct CustomPart: Sendable, Equatable {
  /// In the format `{provider}.{provider-type}`.
  public var kind: String
  public var providerOptions: ProviderOptions?

  public init(kind: String, providerOptions: ProviderOptions? = nil) {
    self.kind = kind
    self.providerOptions = providerOptions
  }
}

/// A tool call. Mirrors upstream `ToolCallPart`.
public struct ToolCallPart: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var input: JSONValue
  public var providerExecuted: Bool?
  public var providerOptions: ProviderOptions?

  public init(
    toolCallId: String,
    toolName: String,
    input: JSONValue,
    providerExecuted: Bool? = nil,
    providerOptions: ProviderOptions? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.input = input
    self.providerExecuted = providerExecuted
    self.providerOptions = providerOptions
  }
}

/// A tool result. Mirrors upstream `ToolResultPart`.
public struct ToolResultPart: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var output: ToolResultOutput
  public var providerOptions: ProviderOptions?

  public init(
    toolCallId: String, toolName: String, output: ToolResultOutput, providerOptions: ProviderOptions? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.output = output
    self.providerOptions = providerOptions
  }
}

/// A request to approve a tool call. Mirrors upstream `ToolApprovalRequest`.
public struct ToolApprovalRequest: Sendable, Equatable {
  public var approvalId: String
  public var toolCallId: String
  public var reason: String?
  /// Whether the approval was decided automatically by the approval configuration.
  public var isAutomatic: Bool?
  public var signature: String?

  public init(
    approvalId: String, toolCallId: String, reason: String? = nil, isAutomatic: Bool? = nil,
    signature: String? = nil
  ) {
    self.approvalId = approvalId
    self.toolCallId = toolCallId
    self.reason = reason
    self.isAutomatic = isAutomatic
    self.signature = signature
  }
}

/// The response to a tool approval request. Mirrors upstream `ToolApprovalResponse`.
public struct ToolApprovalResponse: Sendable, Equatable {
  public var approvalId: String
  public var approved: Bool
  public var reason: String?
  public var providerExecuted: Bool?

  public init(approvalId: String, approved: Bool, reason: String? = nil, providerExecuted: Bool? = nil) {
    self.approvalId = approvalId
    self.approved = approved
    self.reason = reason
    self.providerExecuted = providerExecuted
  }
}

/// Output of a tool, as sent to the model. Mirrors upstream `ToolResultOutput`.
///
/// The deprecated upstream content kinds (`file-data`, `image-url`, ...) are
/// not supported; use `.file` instead.
public enum ToolResultOutput: Sendable, Equatable {
  case text(String, providerOptions: ProviderOptions? = nil)
  case json(JSONValue, providerOptions: ProviderOptions? = nil)
  case executionDenied(reason: String? = nil, providerOptions: ProviderOptions? = nil)
  case errorText(String, providerOptions: ProviderOptions? = nil)
  case errorJSON(JSONValue, providerOptions: ProviderOptions? = nil)
  case content([ContentPart])

  public enum ContentPart: Sendable, Equatable {
    case text(String, providerOptions: ProviderOptions? = nil)
    case file(data: FileData, mediaType: String, filename: String? = nil, providerOptions: ProviderOptions? = nil)
    case custom(providerOptions: ProviderOptions? = nil)
  }
}
