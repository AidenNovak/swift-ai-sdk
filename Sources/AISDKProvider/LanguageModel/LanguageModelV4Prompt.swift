/// A prompt is a list of messages. Mirrors upstream `LanguageModelV4Prompt`.
///
/// This is not a user-facing prompt. The core functions map user-facing
/// prompts to this format, so the user-facing API can evolve without breaking
/// the language model interface.
public typealias LanguageModelV4Prompt = [LanguageModelV4Message]

/// A message in a language model prompt. Mirrors upstream `LanguageModelV4Message`.
public enum LanguageModelV4Message: Sendable, Equatable {
  case system(String, providerOptions: SharedV4ProviderOptions? = nil)
  case user([LanguageModelV4UserContentPart], providerOptions: SharedV4ProviderOptions? = nil)
  case assistant(
    [LanguageModelV4AssistantContentPart], providerOptions: SharedV4ProviderOptions? = nil)
  case tool([LanguageModelV4ToolContentPart], providerOptions: SharedV4ProviderOptions? = nil)

  public enum Role: String, Sendable, Hashable {
    case system, user, assistant, tool
  }

  public var role: Role {
    switch self {
    case .system: .system
    case .user: .user
    case .assistant: .assistant
    case .tool: .tool
    }
  }

  public var providerOptions: SharedV4ProviderOptions? {
    switch self {
    case .system(_, let options), .user(_, let options), .assistant(_, let options),
      .tool(_, let options):
      options
    }
  }
}

/// Content of a user message.
public enum LanguageModelV4UserContentPart: Sendable, Equatable {
  case text(LanguageModelV4TextPart)
  case file(LanguageModelV4FilePart)
}

/// Content of an assistant message.
public enum LanguageModelV4AssistantContentPart: Sendable, Equatable {
  case text(LanguageModelV4TextPart)
  case file(LanguageModelV4FilePart)
  case custom(LanguageModelV4CustomPart)
  case reasoning(LanguageModelV4ReasoningPart)
  case reasoningFile(LanguageModelV4ReasoningFilePart)
  case toolCall(LanguageModelV4ToolCallPart)
  case toolResult(LanguageModelV4ToolResultPart)
}

/// Content of a tool message.
public enum LanguageModelV4ToolContentPart: Sendable, Equatable {
  case toolResult(LanguageModelV4ToolResultPart)
  case toolApprovalResponse(LanguageModelV4ToolApprovalResponsePart)
}

/// Text content part of a prompt. Mirrors upstream `LanguageModelV4TextPart`.
public struct LanguageModelV4TextPart: Sendable, Equatable {
  public var text: String
  public var providerOptions: SharedV4ProviderOptions?

  public init(text: String, providerOptions: SharedV4ProviderOptions? = nil) {
    self.text = text
    self.providerOptions = providerOptions
  }
}

/// Reasoning content part of a prompt. Mirrors upstream `LanguageModelV4ReasoningPart`.
public struct LanguageModelV4ReasoningPart: Sendable, Equatable {
  public var text: String
  public var providerOptions: SharedV4ProviderOptions?

  public init(text: String, providerOptions: SharedV4ProviderOptions? = nil) {
    self.text = text
    self.providerOptions = providerOptions
  }
}

/// A file generated as part of reasoning. Mirrors upstream `LanguageModelV4ReasoningFilePart`.
public struct LanguageModelV4ReasoningFilePart: Sendable, Equatable {
  /// Raw bytes, base64 or URL.
  public var data: SharedV4FileData
  /// IANA media type of the file.
  public var mediaType: String
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    data: SharedV4FileData, mediaType: String, providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.data = data
    self.mediaType = mediaType
    self.providerOptions = providerOptions
  }
}

/// Provider-specific content part. Mirrors upstream `LanguageModelV4CustomPart`.
public struct LanguageModelV4CustomPart: Sendable, Equatable {
  /// The kind of custom content, in the format `{provider}.{provider-type}`.
  public var kind: String
  public var providerOptions: SharedV4ProviderOptions?

  public init(kind: String, providerOptions: SharedV4ProviderOptions? = nil) {
    self.kind = kind
    self.providerOptions = providerOptions
  }
}

/// File content part of a prompt. Mirrors upstream `LanguageModelV4FilePart`.
public struct LanguageModelV4FilePart: Sendable, Equatable {
  public var filename: String?
  public var data: SharedV4FileData
  /// A full IANA media type (`image/png`) or just the top-level segment (`image`).
  public var mediaType: String
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    data: SharedV4FileData,
    mediaType: String,
    filename: String? = nil,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.data = data
    self.mediaType = mediaType
    self.filename = filename
    self.providerOptions = providerOptions
  }
}

/// Tool call content part of a prompt. Mirrors upstream `LanguageModelV4ToolCallPart`.
public struct LanguageModelV4ToolCallPart: Sendable, Equatable {
  /// Used to match the tool call with the tool result.
  public var toolCallId: String
  public var toolName: String
  /// Arguments matching the tool's input schema.
  public var input: JSONValue
  /// Whether the provider executes the tool. If not set, the client executes it.
  public var providerExecuted: Bool?
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    toolCallId: String,
    toolName: String,
    input: JSONValue,
    providerExecuted: Bool? = nil,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.input = input
    self.providerExecuted = providerExecuted
    self.providerOptions = providerOptions
  }
}

/// Tool result content part of a prompt. Mirrors upstream `LanguageModelV4ToolResultPart`.
public struct LanguageModelV4ToolResultPart: Sendable, Equatable {
  public var toolCallId: String
  public var toolName: String
  public var output: LanguageModelV4ToolResultOutput
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    toolCallId: String,
    toolName: String,
    output: LanguageModelV4ToolResultOutput,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.output = output
    self.providerOptions = providerOptions
  }
}

/// The user's decision on a tool approval request.
/// Mirrors upstream `LanguageModelV4ToolApprovalResponsePart`.
public struct LanguageModelV4ToolApprovalResponsePart: Sendable, Equatable {
  public var approvalId: String
  public var approved: Bool
  public var reason: String?
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    approvalId: String,
    approved: Bool,
    reason: String? = nil,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.approvalId = approvalId
    self.approved = approved
    self.reason = reason
    self.providerOptions = providerOptions
  }
}

/// Result of a tool call. Mirrors upstream `LanguageModelV4ToolResultOutput`.
public enum LanguageModelV4ToolResultOutput: Sendable, Equatable {
  /// Text output sent directly to the API.
  case text(String, providerOptions: SharedV4ProviderOptions? = nil)
  case json(JSONValue, providerOptions: SharedV4ProviderOptions? = nil)
  /// The user denied the execution of the tool call.
  case executionDenied(reason: String? = nil, providerOptions: SharedV4ProviderOptions? = nil)
  case errorText(String, providerOptions: SharedV4ProviderOptions? = nil)
  case errorJSON(JSONValue, providerOptions: SharedV4ProviderOptions? = nil)
  case content([ContentPart])

  public enum ContentPart: Sendable, Equatable {
    case text(String, providerOptions: SharedV4ProviderOptions? = nil)
    case file(
      data: SharedV4FileData,
      mediaType: String,
      filename: String? = nil,
      providerOptions: SharedV4ProviderOptions? = nil)
    case custom(providerOptions: SharedV4ProviderOptions? = nil)
  }
}
