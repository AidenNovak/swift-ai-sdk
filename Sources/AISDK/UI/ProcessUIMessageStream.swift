import Foundation

/// The state of an assistant message while its UI message stream is processed.
/// Mirrors upstream `StreamingUIMessageState`.
public struct StreamingUIMessageState: Sendable, Equatable {
  struct PartialToolCall: Sendable, Equatable {
    var text: String
    var index: Int
    var toolName: String
    var dynamic: Bool?
    var title: String?
    var toolMetadata: JSONObject?
  }

  /// The message being built.
  public var message: UIMessage
  /// The finish reason from the `finish` chunk.
  public var finishReason: FinishReason?
  var activeTextParts: [String: Int] = [:]
  var activeReasoningParts: [String: Int] = [:]
  var partialToolCalls: [String: PartialToolCall] = [:]

  /// Continues `lastMessage` when it is an assistant message, otherwise starts
  /// a new assistant message with `messageId`.
  public init(lastMessage: UIMessage?, messageId: String) {
    if let lastMessage, lastMessage.role == .assistant {
      message = lastMessage
    } else {
      message = UIMessage(id: messageId, role: .assistant, parts: [])
    }
  }
}

/// A side effect of applying a chunk, in the order upstream performs them.
public enum UIMessageStreamEvent: Sendable, Equatable {
  /// The message changed. `updateStatus` is `false` for `start` chunks, which
  /// should not switch a chat to `streaming`.
  case write(updateStatus: Bool)
  /// A client-side tool call is ready (`onToolCall`).
  case toolCall(UIToolInputAvailableChunk)
  /// A data part arrived (`onData`), including transient parts.
  case data(DataUIPart)
  /// The stream sent an `error` chunk.
  case error(String)
}

/// Validators applied while processing a UI message stream.
public struct UIMessageStreamSchemas: Sendable {
  /// Validates the merged message metadata.
  public var messageMetadata: Schema<JSONValue>?
  /// Validates data parts, keyed by data part name (with or without the `data-` prefix).
  public var dataParts: [String: Schema<JSONValue>]?

  public init(messageMetadata: Schema<JSONValue>? = nil, dataParts: [String: Schema<JSONValue>]? = nil) {
    self.messageMetadata = messageMetadata
    self.dataParts = dataParts
  }

  func dataPartSchema(for name: String) -> Schema<JSONValue>? {
    dataParts?["data-\(name)"] ?? dataParts?[name]
  }
}

private struct ToolPartUpdate {
  var toolName: String
  var toolCallId: String
  var state: ToolUIPartState
  var input: JSONValue?
  var output: JSONValue?
  var errorText: String?
  var rawInput: JSONValue?
  var preliminary: Bool?
  var providerExecuted: Bool?
  var providerMetadata: ProviderMetadata?
  var title: String?
  var toolMetadata: JSONObject?

  var isResult: Bool { state == .outputAvailable || state == .outputError }
}

extension StreamingUIMessageState {
  /// Applies one chunk to the message and returns the resulting side effects.
  /// Mirrors the per-chunk logic of upstream `processUIMessageStream`.
  ///
  /// - Throws: `UIMessageStreamError` for invalid chunk sequences and
  ///   `TypeValidationError` when metadata or data parts fail validation.
  public mutating func apply(
    _ chunk: UIMessageChunk, schemas: UIMessageStreamSchemas = UIMessageStreamSchemas()
  ) throws -> [UIMessageStreamEvent] {
    switch chunk {
    case .textStart(let id, let metadata):
      activeTextParts[id] = message.parts.count
      message.parts.append(.text(TextUIPart(text: "", state: .streaming, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .textDelta(let id, let delta, let metadata):
      guard let index = activeTextParts[id], case .text(var part) = message.parts[index] else {
        throw UIMessageStreamError(
          chunkType: "text-delta", chunkId: id,
          message: "Received text-delta for missing text part with ID \"\(id)\". "
            + "Ensure a \"text-start\" chunk is sent before any \"text-delta\" chunks.")
      }
      part.text += delta
      part.providerMetadata = metadata ?? part.providerMetadata
      message.parts[index] = .text(part)
      return [.write(updateStatus: true)]

    case .textEnd(let id, let metadata):
      guard let index = activeTextParts[id], case .text(var part) = message.parts[index] else {
        throw UIMessageStreamError(
          chunkType: "text-end", chunkId: id,
          message: "Received text-end for missing text part with ID \"\(id)\". "
            + "Ensure a \"text-start\" chunk is sent before any \"text-end\" chunks.")
      }
      part.state = .done
      part.providerMetadata = metadata ?? part.providerMetadata
      message.parts[index] = .text(part)
      activeTextParts[id] = nil
      return [.write(updateStatus: true)]

    case .custom(let kind, let metadata):
      message.parts.append(.custom(CustomContentUIPart(kind: kind, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .reasoningStart(let id, let metadata):
      activeReasoningParts[id] = message.parts.count
      message.parts.append(.reasoning(ReasoningUIPart(id: id, text: "", state: .streaming, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .reasoningDelta(let id, let delta, let metadata):
      guard let index = activeReasoningParts[id], case .reasoning(var part) = message.parts[index] else {
        throw UIMessageStreamError(
          chunkType: "reasoning-delta", chunkId: id,
          message: "Received reasoning-delta for missing reasoning part with ID \"\(id)\". "
            + "Ensure a \"reasoning-start\" chunk is sent before any \"reasoning-delta\" chunks.")
      }
      part.text += delta
      part.providerMetadata = metadata ?? part.providerMetadata
      message.parts[index] = .reasoning(part)
      return [.write(updateStatus: true)]

    case .reasoningEnd(let id, let metadata):
      guard let index = activeReasoningParts[id], case .reasoning(var part) = message.parts[index] else {
        throw UIMessageStreamError(
          chunkType: "reasoning-end", chunkId: id,
          message: "Received reasoning-end for missing reasoning part with ID \"\(id)\". "
            + "Ensure a \"reasoning-start\" chunk is sent before any \"reasoning-end\" chunks.")
      }
      part.providerMetadata = metadata ?? part.providerMetadata
      part.state = .done
      message.parts[index] = .reasoning(part)
      activeReasoningParts[id] = nil
      return [.write(updateStatus: true)]

    case .file(let url, let mediaType, let metadata):
      message.parts.append(.file(FileUIPart(mediaType: mediaType, url: url, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .reasoningFile(let url, let mediaType, let metadata):
      message.parts.append(.reasoningFile(ReasoningFileUIPart(mediaType: mediaType, url: url, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .sourceURL(let sourceId, let url, let title, let metadata):
      message.parts.append(
        .sourceURL(SourceURLUIPart(sourceId: sourceId, url: url, title: title, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .sourceDocument(let sourceId, let mediaType, let title, let filename, let metadata):
      message.parts.append(
        .sourceDocument(
          SourceDocumentUIPart(
            sourceId: sourceId, mediaType: mediaType, title: title, filename: filename, providerMetadata: metadata)))
      return [.write(updateStatus: true)]

    case .toolInputStart(let chunk):
      let staticToolCount = currentStepRange.filter { message.parts[$0].toolPart.map { !$0.isDynamic } ?? false }.count
      partialToolCalls[chunk.toolCallId] = PartialToolCall(
        text: "", index: staticToolCount, toolName: chunk.toolName, dynamic: chunk.dynamic, title: chunk.title,
        toolMetadata: chunk.toolMetadata)
      updateToolPart(
        ToolPartUpdate(
          toolName: chunk.toolName, toolCallId: chunk.toolCallId, state: .inputStreaming,
          providerExecuted: chunk.providerExecuted, providerMetadata: chunk.providerMetadata, title: chunk.title,
          toolMetadata: chunk.toolMetadata),
        dynamic: chunk.dynamic == true)
      return [.write(updateStatus: true)]

    case .toolInputDelta(let toolCallId, let delta):
      guard var partial = partialToolCalls[toolCallId] else {
        throw UIMessageStreamError(
          chunkType: "tool-input-delta", chunkId: toolCallId,
          message: "Received tool-input-delta for missing tool call with ID \"\(toolCallId)\". "
            + "Ensure a \"tool-input-start\" chunk is sent before any \"tool-input-delta\" chunks.")
      }
      partial.text += delta
      partialToolCalls[toolCallId] = partial
      updateToolPart(
        ToolPartUpdate(
          toolName: partial.toolName, toolCallId: toolCallId, state: .inputStreaming,
          input: parsePartialJson(partial.text).value, title: partial.title, toolMetadata: partial.toolMetadata),
        dynamic: partial.dynamic == true)
      return [.write(updateStatus: true)]

    case .toolInputAvailable(let chunk):
      updateToolPart(
        ToolPartUpdate(
          toolName: chunk.toolName, toolCallId: chunk.toolCallId, state: .inputAvailable, input: chunk.input,
          providerExecuted: chunk.providerExecuted, providerMetadata: chunk.providerMetadata, title: chunk.title,
          toolMetadata: chunk.toolMetadata),
        dynamic: chunk.dynamic == true)
      var events: [UIMessageStreamEvent] = [.write(updateStatus: true)]
      if chunk.providerExecuted != true {
        events.append(.toolCall(chunk))
      }
      return events

    case .toolInputError(let chunk):
      // An existing part for this call (e.g. from tool-input-start) keeps its kind.
      let parts = message.parts
      let existing = currentStepRange.lazy.compactMap { parts[$0].toolPart }.first { $0.toolCallId == chunk.toolCallId }
      let isDynamic = existing?.isDynamic ?? (chunk.dynamic == true)
      updateToolPart(
        ToolPartUpdate(
          toolName: chunk.toolName, toolCallId: chunk.toolCallId, state: .outputError,
          input: isDynamic ? chunk.input : nil, errorText: chunk.errorText, rawInput: isDynamic ? nil : chunk.input,
          providerExecuted: chunk.providerExecuted, providerMetadata: chunk.providerMetadata,
          toolMetadata: chunk.toolMetadata),
        dynamic: isDynamic)
      return [.write(updateStatus: true)]

    case .toolApprovalRequest(let chunk):
      let index = try toolInvocationIndex(chunk.toolCallId)
      modifyToolPart(at: index) { part in
        part.state = .approvalRequested
        part.approval = ToolUIApproval(
          id: chunk.approvalId, descriptor: chunk.approvalDescriptor.flatMap { $0.isNull ? nil : $0 },
          requestReason: chunk.reason, isAutomatic: chunk.isAutomatic == true ? true : nil, signature: chunk.signature,
          inputSchemaInput: chunk.inputSchemaInput)
      }
      return [.write(updateStatus: true)]

    case .toolApprovalResponse(let chunk):
      guard
        let index = message.parts.firstIndex(where: { $0.toolPart?.approval?.id == chunk.approvalId })
      else {
        throw UIMessageStreamError(
          chunkType: "tool-approval-response", chunkId: chunk.approvalId,
          message: "No tool invocation found for approval ID \"\(chunk.approvalId)\".")
      }
      modifyToolPart(at: index) { part in
        var approval = part.approval ?? ToolUIApproval(id: chunk.approvalId)
        approval.id = chunk.approvalId
        approval.approved = chunk.approved
        if let reason = chunk.reason { approval.reason = reason }
        part.state = .approvalResponded
        part.approval = approval
        if let providerExecuted = chunk.providerExecuted { part.providerExecuted = providerExecuted }
        if let metadata = chunk.providerMetadata { part.callProviderMetadata = metadata }
      }
      return [.write(updateStatus: true)]

    case .toolOutputDenied(let toolCallId):
      let index = try toolInvocationIndex(toolCallId)
      modifyToolPart(at: index) { $0.state = .outputDenied }
      return [.write(updateStatus: true)]

    case .toolOutputAvailable(let chunk):
      let index = try toolInvocationIndex(chunk.toolCallId)
      guard let invocation = message.parts[index].toolPart else { return [] }
      updateToolPart(
        ToolPartUpdate(
          toolName: invocation.toolName, toolCallId: chunk.toolCallId, state: .outputAvailable,
          input: invocation.input, output: chunk.output, preliminary: chunk.preliminary,
          providerExecuted: chunk.providerExecuted, providerMetadata: chunk.providerMetadata, title: invocation.title,
          toolMetadata: invocation.toolMetadata),
        dynamic: invocation.isDynamic, existingIndex: index)
      return [.write(updateStatus: true)]

    case .toolOutputError(let chunk):
      let index = try toolInvocationIndex(chunk.toolCallId)
      guard let invocation = message.parts[index].toolPart else { return [] }
      updateToolPart(
        ToolPartUpdate(
          toolName: invocation.toolName, toolCallId: chunk.toolCallId, state: .outputError,
          input: invocation.input, errorText: chunk.errorText, rawInput: invocation.isDynamic ? nil : invocation.rawInput,
          providerExecuted: chunk.providerExecuted, providerMetadata: chunk.providerMetadata, title: invocation.title,
          toolMetadata: invocation.toolMetadata),
        dynamic: invocation.isDynamic, existingIndex: index)
      return [.write(updateStatus: true)]

    case .startStep:
      message.parts.append(.stepStart)
      return []

    case .finishStep:
      // Active parts are closed by their explicit end chunks. A merged
      // stream's step can finish while another stream's part is active.
      return []

    case .resetStep:
      let range = currentStepRange
      activeTextParts = [:]
      activeReasoningParts = [:]
      partialToolCalls = [:]
      guard !range.isEmpty else { return [] }
      message.parts.removeSubrange(range)
      return [.write(updateStatus: true)]

    case .start(let messageId, let metadata):
      if let messageId { message.id = messageId }
      let metadata = metadata.flatMap { $0.isNull ? nil : $0 }
      try updateMessageMetadata(metadata, schemas: schemas)
      return messageId != nil || metadata != nil ? [.write(updateStatus: false)] : []

    case .finish(let finishReason, let metadata):
      if let finishReason { self.finishReason = finishReason }
      let metadata = metadata.flatMap { $0.isNull ? nil : $0 }
      try updateMessageMetadata(metadata, schemas: schemas)
      return metadata != nil ? [.write(updateStatus: true)] : []

    case .messageMetadata(let metadata):
      let metadata = metadata.isNull ? nil : metadata
      try updateMessageMetadata(metadata, schemas: schemas)
      return metadata != nil ? [.write(updateStatus: true)] : []

    case .error(let errorText):
      return [.error(errorText)]

    case .abort:
      return []

    case .data(let name, let id, let data, let transient):
      if let schema = schemas.dataPartSchema(for: name) {
        let existingIndex = message.parts.firstIndex {
          if case .data(let part) = $0 { part.id == id && part.name == name } else { false }
        }
        _ = try validateTypes(
          value: data, schema: schema,
          context: TypeValidationContext(
            field: "message.parts[\(existingIndex ?? message.parts.count)].data", entityName: "data-\(name)",
            entityId: id))
      }
      let part = DataUIPart(name: name, id: id, data: data)
      if transient == true {
        return [.data(part)]
      }
      if let id,
        let index = message.parts.firstIndex(where: {
          if case .data(let existing) = $0 { existing.name == name && existing.id == id } else { false }
        })
      {
        message.parts[index] = .data(part)
      } else {
        message.parts.append(.data(part))
      }
      return [.data(part), .write(updateStatus: true)]
    }
  }

  /// The indices of the parts after the last `step-start` part.
  private var currentStepRange: Range<Int> {
    let start = message.parts.lastIndex(of: .stepStart).map { $0 + 1 } ?? 0
    return start..<message.parts.count
  }

  /// Finds a tool invocation in the current step, falling back to the latest match in the message.
  private func toolInvocationIndex(_ toolCallId: String) throws -> Int {
    if let index = currentStepRange.first(where: { message.parts[$0].toolPart?.toolCallId == toolCallId }) {
      return index
    }
    if let index = message.parts.lastIndex(where: { $0.toolPart?.toolCallId == toolCallId }) {
      return index
    }
    throw UIMessageStreamError(
      chunkType: "tool-invocation", chunkId: toolCallId,
      message: "No tool invocation found for tool call ID \"\(toolCallId)\".")
  }

  private mutating func modifyToolPart(at index: Int, _ body: (inout ToolUIPart) -> Void) {
    guard case .tool(var part) = message.parts[index] else { return }
    body(&part)
    message.parts[index] = .tool(part)
  }

  /// Mirrors upstream `updateToolPart` (static) and `updateDynamicToolPart`.
  private mutating func updateToolPart(_ update: ToolPartUpdate, dynamic: Bool, existingIndex: Int? = nil) {
    let index =
      existingIndex
      ?? currentStepRange.first {
        guard let part = message.parts[$0].toolPart else { return false }
        return part.isDynamic == dynamic && part.toolCallId == update.toolCallId
      }

    guard let index else {
      message.parts.append(
        .tool(
          ToolUIPart(
            toolName: update.toolName, isDynamic: dynamic, toolCallId: update.toolCallId, state: update.state,
            title: update.title, toolMetadata: update.toolMetadata, providerExecuted: update.providerExecuted,
            input: update.input, output: update.output, errorText: update.errorText,
            rawInput: dynamic ? nil : update.rawInput, preliminary: update.preliminary,
            callProviderMetadata: update.isResult ? nil : update.providerMetadata,
            resultProviderMetadata: update.isResult ? update.providerMetadata : nil)))
      return
    }

    modifyToolPart(at: index) { part in
      part.state = update.state
      if dynamic { part.toolName = update.toolName }
      part.input = update.input
      part.output = update.output
      part.errorText = update.errorText
      part.rawInput = dynamic ? (update.rawInput ?? part.rawInput) : update.rawInput
      part.preliminary = update.preliminary
      if let title = update.title { part.title = title }
      if let toolMetadata = update.toolMetadata { part.toolMetadata = toolMetadata }
      // Once providerExecuted is set, it stays for streaming.
      part.providerExecuted = update.providerExecuted ?? part.providerExecuted
      if let metadata = update.providerMetadata {
        if update.isResult {
          part.resultProviderMetadata = metadata
        } else {
          part.callProviderMetadata = metadata
        }
      }
    }
  }

  private mutating func updateMessageMetadata(_ metadata: JSONValue?, schemas: UIMessageStreamSchemas) throws {
    guard let metadata else { return }
    let merged = mergeJSONObjects(message.metadata, metadata)
    if let schema = schemas.messageMetadata {
      _ = try validateTypes(
        value: merged ?? .null, schema: schema,
        context: TypeValidationContext(field: "message.metadata", entityId: message.id))
    }
    message.metadata = merged
  }
}

/// Reads a UI message stream into a stream of message snapshots, one per
/// update. Mirrors upstream `readUIMessageStream`.
///
/// Use it on the server or in tests to observe the assistant message as it
/// is built (e.g. `for try await message in readUIMessageStream(stream: s)`).
///
/// - Parameters:
///   - message: An assistant message to continue, e.g. for tool round-trips.
///   - onError: Called for `error` chunks and processing failures.
///   - terminateOnError: Whether errors terminate the output stream.
public func readUIMessageStream(
  message: UIMessage? = nil,
  stream: AsyncThrowingStream<UIMessageChunk, any Error>,
  onError: (@Sendable (any Error) -> Void)? = nil,
  terminateOnError: Bool = false
) -> AsyncThrowingStream<UIMessage, any Error> {
  let (output, continuation) = AsyncThrowingStream<UIMessage, any Error>.makeStream()
  let task = Task {
    var state = StreamingUIMessageState(lastMessage: message, messageId: message?.id ?? "")
    var hasErrored = false

    func handle(_ error: any Error) {
      onError?(error)
      if !hasErrored && terminateOnError {
        hasErrored = true
        continuation.finish(throwing: error)
      }
    }

    do {
      for try await chunk in stream {
        for event in try state.apply(chunk) {
          switch event {
          case .write:
            if !hasErrored { continuation.yield(state.message) }
          case .error(let errorText):
            handle(UIMessageStreamError(chunkType: "error", chunkId: "", message: errorText))
          case .toolCall, .data:
            break
          }
        }
      }
    } catch {
      handle(error)
    }
    continuation.finish()
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}
