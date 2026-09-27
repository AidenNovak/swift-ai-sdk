import Foundation

/// An OpenAI-style streamed tool call delta. Mirrors upstream `StreamingToolCallDelta`.
public struct StreamingToolCallDelta: Sendable, Decodable, Equatable {
  public struct Function: Sendable, Decodable, Equatable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
      self.name = name
      self.arguments = arguments
    }
  }

  public var index: Int?
  public var id: String?
  public var type: String?
  public var function: Function?

  public init(index: Int? = nil, id: String? = nil, type: String? = nil, function: Function? = nil) {
    self.index = index
    self.id = id
    self.type = type
    self.function = function
  }
}

/// Assembles streamed tool call deltas into `tool-input-*` and `tool-call`
/// stream parts. Mirrors upstream `StreamingToolCallTracker`.
///
/// Not thread-safe; use it from a single stream-processing task.
public final class StreamingToolCallTracker {
  public enum TypeValidation: Sendable {
    case none, ifPresent, required
  }

  private final class TrackedToolCall {
    let id: String
    let name: String
    var arguments: String
    var hasFinished = false
    let metadata: SharedV4ProviderMetadata?

    init(id: String, name: String, arguments: String, metadata: SharedV4ProviderMetadata?) {
      self.id = id
      self.name = name
      self.arguments = arguments
      self.metadata = metadata
    }
  }

  private var toolCalls: [TrackedToolCall] = []
  private var toolCallsById: [String: TrackedToolCall] = [:]
  private var toolCallsByIndex: [Int: TrackedToolCall] = [:]
  private var latestToolCall: TrackedToolCall?
  private let emit: (LanguageModelV4StreamPart) -> Void
  private let generateId: IdGenerator
  private let typeValidation: TypeValidation
  private let extractMetadata: ((StreamingToolCallDelta) -> SharedV4ProviderMetadata?)?
  private let buildToolCallProviderMetadata: ((SharedV4ProviderMetadata?) -> SharedV4ProviderMetadata?)?

  public init(
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    typeValidation: TypeValidation = .none,
    extractMetadata: ((StreamingToolCallDelta) -> SharedV4ProviderMetadata?)? = nil,
    buildToolCallProviderMetadata: ((SharedV4ProviderMetadata?) -> SharedV4ProviderMetadata?)? = nil,
    emit: @escaping (LanguageModelV4StreamPart) -> Void
  ) {
    self.generateId = generateId
    self.typeValidation = typeValidation
    self.extractMetadata = extractMetadata
    self.buildToolCallProviderMetadata = buildToolCallProviderMetadata
    self.emit = emit
  }

  /// Processes one delta.
  ///
  /// - Throws: `InvalidResponseDataError` when a new tool call lacks an id or name.
  public func processDelta(_ delta: StreamingToolCallDelta) throws {
    let existing: TrackedToolCall? =
      if let id = delta.id, !id.isEmpty {
        toolCallsById[id]
      } else if let index = delta.index {
        toolCallsByIndex[index]
      } else {
        latestToolCall
      }

    let toolCall: TrackedToolCall
    if let existing {
      toolCall = existing
      if !toolCall.hasFinished, let arguments = delta.function?.arguments {
        toolCall.arguments += arguments
        emit(.toolInputDelta(id: toolCall.id, delta: arguments))
      }
    } else {
      toolCall = try startToolCall(delta)
    }

    if let index = delta.index {
      toolCallsByIndex[index] = toolCall
    }
    latestToolCall = toolCall
  }

  /// Emits `tool-input-end` and `tool-call` for every unfinished tool call.
  public func flush() {
    for toolCall in toolCalls where !toolCall.hasFinished {
      emit(.toolInputEnd(id: toolCall.id))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCall.id.isEmpty ? generateId() : toolCall.id,
            toolName: toolCall.name,
            input: toolCall.arguments,
            providerMetadata: buildToolCallProviderMetadata?(toolCall.metadata))))
      toolCall.hasFinished = true
    }
  }

  private func startToolCall(_ delta: StreamingToolCallDelta) throws -> TrackedToolCall {
    let data = try? JSONValue(encoding: DeltaSnapshot(delta))
    switch typeValidation {
    case .required where delta.type != "function",
      .ifPresent where delta.type != nil && delta.type != "function":
      throw InvalidResponseDataError(data: data, message: "Expected 'function' type.")
    default:
      break
    }
    guard let id = delta.id else {
      throw InvalidResponseDataError(data: data, message: "Expected 'id' to be a string.")
    }
    guard let name = delta.function?.name else {
      throw InvalidResponseDataError(data: data, message: "Expected 'function.name' to be a string.")
    }

    emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: name)))
    let toolCall = TrackedToolCall(
      id: id, name: name, arguments: delta.function?.arguments ?? "", metadata: extractMetadata?(delta))
    toolCalls.append(toolCall)
    if !id.isEmpty { toolCallsById[id] = toolCall }
    if !toolCall.arguments.isEmpty {
      emit(.toolInputDelta(id: id, delta: toolCall.arguments))
    }
    return toolCall
  }
}

private struct DeltaSnapshot: Encodable {
  let index: Int?
  let id: String?
  let type: String?
  let name: String?
  let arguments: String?

  init(_ delta: StreamingToolCallDelta) {
    index = delta.index
    id = delta.id
    type = delta.type
    name = delta.function?.name
    arguments = delta.function?.arguments
  }
}
