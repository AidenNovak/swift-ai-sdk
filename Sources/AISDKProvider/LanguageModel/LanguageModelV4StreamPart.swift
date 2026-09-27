/// A part of a language model output stream. Mirrors upstream `LanguageModelV4StreamPart`.
public enum LanguageModelV4StreamPart: Sendable {
  // Text blocks
  case textStart(id: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case textDelta(id: String, delta: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case textEnd(id: String, providerMetadata: SharedV4ProviderMetadata? = nil)

  // Reasoning blocks
  case reasoningStart(id: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case reasoningDelta(id: String, delta: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case reasoningEnd(id: String, providerMetadata: SharedV4ProviderMetadata? = nil)

  // Tool inputs, calls and results
  case toolInputStart(LanguageModelV4ToolInputStart)
  case toolInputDelta(id: String, delta: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case toolInputEnd(id: String, providerMetadata: SharedV4ProviderMetadata? = nil)
  case toolApprovalRequest(LanguageModelV4ToolApprovalRequest)
  case toolCall(LanguageModelV4ToolCall)
  case toolResult(LanguageModelV4ToolResult)
  case custom(LanguageModelV4CustomContent)

  // Files and sources
  case file(LanguageModelV4File)
  case reasoningFile(LanguageModelV4ReasoningFile)
  case source(LanguageModelV4Source)

  /// Sent first, with warnings for the call such as unsupported settings.
  case streamStart(warnings: [SharedV4Warning])
  /// Response metadata, sent once it is available.
  case responseMetadata(LanguageModelV4ResponseMetadata)
  /// Metadata available after the stream has finished.
  case finish(
    usage: LanguageModelV4Usage,
    finishReason: LanguageModelV4FinishReason,
    providerMetadata: SharedV4ProviderMetadata? = nil)
  /// Raw chunks, when `includeRawChunks` is enabled.
  case raw(rawValue: JSONValue)
  /// Streamed errors. A stream can contain multiple errors.
  case error(any Error)
}

/// The start of a streamed tool input. Mirrors the upstream `tool-input-start` part.
public struct LanguageModelV4ToolInputStart: Sendable, Equatable {
  public var id: String
  public var toolName: String
  public var providerMetadata: SharedV4ProviderMetadata?
  public var providerExecuted: Bool?
  public var dynamic: Bool?
  public var title: String?

  public init(
    id: String,
    toolName: String,
    providerMetadata: SharedV4ProviderMetadata? = nil,
    providerExecuted: Bool? = nil,
    dynamic: Bool? = nil,
    title: String? = nil
  ) {
    self.id = id
    self.toolName = toolName
    self.providerMetadata = providerMetadata
    self.providerExecuted = providerExecuted
    self.dynamic = dynamic
    self.title = title
  }
}

extension LanguageModelV4StreamPart: Equatable {
  /// Errors compare by their description; every other case compares structurally.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case let (.textStart(a1, a2), .textStart(b1, b2)): a1 == b1 && a2 == b2
    case let (.textDelta(a1, a2, a3), .textDelta(b1, b2, b3)): a1 == b1 && a2 == b2 && a3 == b3
    case let (.textEnd(a1, a2), .textEnd(b1, b2)): a1 == b1 && a2 == b2
    case let (.reasoningStart(a1, a2), .reasoningStart(b1, b2)): a1 == b1 && a2 == b2
    case let (.reasoningDelta(a1, a2, a3), .reasoningDelta(b1, b2, b3)):
      a1 == b1 && a2 == b2 && a3 == b3
    case let (.reasoningEnd(a1, a2), .reasoningEnd(b1, b2)): a1 == b1 && a2 == b2
    case let (.toolInputStart(a), .toolInputStart(b)): a == b
    case let (.toolInputDelta(a1, a2, a3), .toolInputDelta(b1, b2, b3)):
      a1 == b1 && a2 == b2 && a3 == b3
    case let (.toolInputEnd(a1, a2), .toolInputEnd(b1, b2)): a1 == b1 && a2 == b2
    case let (.toolApprovalRequest(a), .toolApprovalRequest(b)): a == b
    case let (.toolCall(a), .toolCall(b)): a == b
    case let (.toolResult(a), .toolResult(b)): a == b
    case let (.custom(a), .custom(b)): a == b
    case let (.file(a), .file(b)): a == b
    case let (.reasoningFile(a), .reasoningFile(b)): a == b
    case let (.source(a), .source(b)): a == b
    case let (.streamStart(a), .streamStart(b)): a == b
    case let (.responseMetadata(a), .responseMetadata(b)): a == b
    case let (.finish(a1, a2, a3), .finish(b1, b2, b3)): a1 == b1 && a2 == b2 && a3 == b3
    case let (.raw(a), .raw(b)): a == b
    case let (.error(a), .error(b)): getErrorMessage(a) == getErrorMessage(b)
    default: false
    }
  }
}
