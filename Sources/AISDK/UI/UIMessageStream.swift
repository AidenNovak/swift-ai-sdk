import Foundation

/// How a UI message stream ended. Mirrors upstream `UIMessageStreamOutcome`.
public enum UIMessageStreamOutcome: Sendable {
  case completed
  case failed((any Error)?)
  case aborted
  case unknown

  var isUnknown: Bool { if case .unknown = self { true } else { false } }
  var isFailed: Bool { if case .failed = self { true } else { false } }
  var isAborted: Bool { if case .aborted = self { true } else { false } }
  var isCompleted: Bool { if case .completed = self { true } else { false } }
}

/// Passed to `onEnd` when a UI message stream ends. Mirrors the upstream
/// `UIMessageStreamOnEndCallback` event.
public struct UIMessageStreamEndEvent: Sendable {
  /// The original messages plus the response message.
  public var messages: [UIMessage]
  /// Whether the response continued the last original (assistant) message.
  public var isContinuation: Bool
  public var isAborted: Bool
  /// Whether the consumer cancelled the stream before it finished.
  public var isCancelled: Bool
  public var outcome: UIMessageStreamOutcome
  public var responseMessage: UIMessage
  public var finishReason: FinishReason?
}

/// Passed to `onStepEnd` after each `finish-step` chunk.
public struct UIMessageStreamStepEndEvent: Sendable {
  public var messages: [UIMessage]
  public var isContinuation: Bool
  public var responseMessage: UIMessage
}

public typealias UIMessageStreamOnEnd = @Sendable (UIMessageStreamEndEvent) async -> Void
public typealias UIMessageStreamOnStepEnd = @Sendable (UIMessageStreamStepEndEvent) async throws -> Void

/// Options for converting a `streamText` stream to a UI message stream.
/// Mirrors upstream `UIMessageStreamOptions`.
public struct UIMessageStreamOptions: Sendable {
  /// The original messages. When set, persistence mode is assumed and the
  /// response message gets an id (the last assistant message's id when it continues it).
  public var originalMessages: [UIMessage]?
  /// Generates the response message id.
  public var generateMessageId: IdGenerator?
  /// Called when the stream ends, e.g. to persist `messages`.
  public var onEnd: UIMessageStreamOnEnd?
  /// Extracts message metadata sent with `start`, `finish` and other parts.
  public var messageMetadata: (@Sendable (TextStreamPart) -> JSONValue?)?
  /// Send reasoning parts. Defaults to `true`.
  public var sendReasoning: Bool
  /// Send source parts. Defaults to `false`.
  public var sendSources: Bool
  /// Send the `finish` chunk; disable when more `streamText` calls follow. Defaults to `true`.
  public var sendFinish: Bool
  /// Send the `start` chunk; disable when it was already sent. Defaults to `true`.
  public var sendStart: Bool
  /// Converts errors to the text sent to the client. The default hides
  /// server error details: `"An error occurred."`.
  public var onError: @Sendable (any Error) -> String

  public init(
    originalMessages: [UIMessage]? = nil,
    generateMessageId: IdGenerator? = nil,
    onEnd: UIMessageStreamOnEnd? = nil,
    messageMetadata: (@Sendable (TextStreamPart) -> JSONValue?)? = nil,
    sendReasoning: Bool = true,
    sendSources: Bool = false,
    sendFinish: Bool = true,
    sendStart: Bool = true,
    onError: @escaping @Sendable (any Error) -> String = { _ in "An error occurred." }
  ) {
    self.originalMessages = originalMessages
    self.generateMessageId = generateMessageId
    self.onEnd = onEnd
    self.messageMetadata = messageMetadata
    self.sendReasoning = sendReasoning
    self.sendSources = sendSources
    self.sendFinish = sendFinish
    self.sendStart = sendStart
    self.onError = onError
  }
}

/// Converts one `streamText` part to a UI message chunk, or `nil` when the
/// part is not sent. Mirrors upstream `toUIMessageChunk`.
public func toUIMessageChunk(
  _ part: TextStreamPart,
  tools: ToolSet? = nil,
  options: UIMessageStreamOptions = UIMessageStreamOptions(),
  messageMetadata: JSONValue? = nil,
  responseMessageId: String? = nil
) -> UIMessageChunk? {
  func isDynamic(toolName: String, dynamic: Bool?) -> Bool? {
    guard let tool = tools?[toolName] else { return dynamic }
    return tool.isDynamic ? true : nil
  }

  switch part {
  case .start:
    guard options.sendStart else { return nil }
    return .start(messageId: responseMessageId, messageMetadata: messageMetadata)
  case .startStep:
    return .startStep
  case .textStart(let id, let metadata):
    return .textStart(id: id, providerMetadata: metadata)
  case .textDelta(let id, let text, let metadata):
    return .textDelta(id: id, delta: text, providerMetadata: metadata)
  case .textEnd(let id, let metadata):
    return .textEnd(id: id, providerMetadata: metadata)
  case .reasoningStart(let id, let metadata):
    return options.sendReasoning ? .reasoningStart(id: id, providerMetadata: metadata) : nil
  case .reasoningDelta(let id, let text, let metadata):
    return options.sendReasoning ? .reasoningDelta(id: id, delta: text, providerMetadata: metadata) : nil
  case .reasoningEnd(let id, let metadata):
    return options.sendReasoning ? .reasoningEnd(id: id, providerMetadata: metadata) : nil
  case .file(let file, let metadata):
    return .file(url: "data:\(file.mediaType);base64,\(file.base64)", mediaType: file.mediaType, providerMetadata: metadata)
  case .reasoningFile(let file, let metadata):
    guard options.sendReasoning else { return nil }
    return .reasoningFile(
      url: "data:\(file.mediaType);base64,\(file.base64)", mediaType: file.mediaType, providerMetadata: metadata)
  case .source(let source):
    guard options.sendSources else { return nil }
    switch source {
    case .url(let id, let url, let title, let metadata):
      return .sourceURL(sourceId: id, url: url, title: title, providerMetadata: metadata)
    case .document(let id, let mediaType, let title, let filename, let metadata):
      return .sourceDocument(
        sourceId: id, mediaType: mediaType, title: title, filename: filename, providerMetadata: metadata)
    }
  case .custom(let kind, let metadata):
    return .custom(kind: kind, providerMetadata: metadata)
  case .toolInputStart(let start):
    return .toolInputStart(
      UIToolInputStartChunk(
        toolCallId: start.id, toolName: start.toolName, providerExecuted: start.providerExecuted,
        providerMetadata: start.providerMetadata, toolMetadata: start.toolMetadata,
        dynamic: isDynamic(toolName: start.toolName, dynamic: start.dynamic), title: start.title))
  case .toolInputDelta(let id, let delta, _):
    return .toolInputDelta(toolCallId: id, inputTextDelta: delta)
  case .toolCall(let call):
    let dynamic = isDynamic(toolName: call.toolName, dynamic: call.dynamic ? true : nil)
    if call.invalid {
      return .toolInputError(
        UIToolInputErrorChunk(
          toolCallId: call.toolCallId, toolName: call.toolName, input: call.input,
          providerExecuted: call.providerExecuted, providerMetadata: call.providerMetadata,
          toolMetadata: call.toolMetadata, dynamic: dynamic,
          errorText: options.onError(call.error ?? InvalidToolInputError(
            toolName: call.toolName, toolInput: call.input.jsonString(), cause: nil)),
          title: call.title))
    }
    return .toolInputAvailable(
      UIToolInputAvailableChunk(
        toolCallId: call.toolCallId, toolName: call.toolName, input: call.input,
        providerExecuted: call.providerExecuted, providerMetadata: call.providerMetadata,
        toolMetadata: call.toolMetadata, dynamic: dynamic, title: call.title))
  case .toolApprovalRequest(let request):
    return .toolApprovalRequest(
      UIToolApprovalRequestChunk(
        approvalId: request.approvalId, toolCallId: request.toolCall.toolCallId, reason: request.reason,
        isAutomatic: request.isAutomatic, signature: request.signature))
  case .toolApprovalResponse(let response):
    return .toolApprovalResponse(
      UIToolApprovalResponseChunk(
        approvalId: response.approvalId, approved: response.approved, reason: response.reason,
        providerExecuted: response.providerExecuted))
  case .toolResult(let result):
    return .toolOutputAvailable(
      UIToolOutputAvailableChunk(
        toolCallId: result.toolCallId, output: result.output, providerExecuted: result.providerExecuted,
        providerMetadata: result.providerMetadata, toolMetadata: result.toolMetadata,
        dynamic: isDynamic(toolName: result.toolName, dynamic: result.dynamic ? true : nil),
        preliminary: result.preliminary ? true : nil))
  case .toolError(let toolError):
    let errorText: String
    if toolError.providerExecuted == true {
      if let providerError = toolError.error as? ProviderToolError {
        errorText = providerError.value.stringValue ?? providerError.value.jsonString()
      } else {
        errorText = getErrorMessage(toolError.error)
      }
    } else {
      errorText = options.onError(toolError.error)
    }
    return .toolOutputError(
      UIToolOutputErrorChunk(
        toolCallId: toolError.toolCallId, errorText: errorText, providerExecuted: toolError.providerExecuted,
        providerMetadata: toolError.providerMetadata, toolMetadata: toolError.toolMetadata,
        dynamic: isDynamic(toolName: toolError.toolName, dynamic: toolError.dynamic ? true : nil)))
  case .toolOutputDenied(let toolCallId, _):
    return .toolOutputDenied(toolCallId: toolCallId)
  case .error(let error):
    return .error(errorText: options.onError(error))
  case .finishStep:
    return .finishStep
  case .finish(let finishReason, _, _):
    guard options.sendFinish else { return nil }
    return .finish(finishReason: finishReason, messageMetadata: messageMetadata)
  case .abort(let reason):
    return .abort(reason: reason)
  case .toolInputEnd, .raw:
    return nil
  }
}

/// The response message id: the last original message's id when it is an
/// assistant message, otherwise a new id. Mirrors upstream `getResponseUIMessageId`.
public func getResponseUIMessageId(originalMessages: [UIMessage]?, responseMessageId: IdGenerator) -> String? {
  guard let originalMessages else { return nil }
  if let last = originalMessages.last, last.role == .assistant {
    return last.id
  }
  return responseMessageId()
}

/// Converts a `streamText` full stream to a UI message stream. Mirrors upstream `toUIMessageStream`.
///
/// ```swift
/// let result = try streamText(model: model, messages: try await convertToModelMessages(messages))
/// let response = createUIMessageStreamResponse(stream: toUIMessageStream(result.fullStream))
/// ```
public func toUIMessageStream(
  _ stream: AsyncThrowingStream<TextStreamPart, any Error>,
  tools: ToolSet? = nil,
  options: UIMessageStreamOptions = UIMessageStreamOptions()
) -> AsyncThrowingStream<UIMessageChunk, any Error> {
  let responseMessageId = options.generateMessageId.flatMap {
    getResponseUIMessageId(originalMessages: options.originalMessages, responseMessageId: $0)
  }
  let outcome = OutcomeTracker(mode: .source)

  let (chunks, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
  let task = Task {
    do {
      for try await part in stream {
        let metadata = options.messageMetadata?(part)
        if let chunk = toUIMessageChunk(
          part, tools: tools, options: options, messageMetadata: metadata, responseMessageId: responseMessageId)
        {
          continuation.yield(chunk)
        }
        switch part {
        case .start, .finish: break
        default:
          if let metadata { continuation.yield(.messageMetadata(metadata)) }
        }
        switch part {
        case .finish: outcome.set(.completed)
        case .abort: outcome.set(.aborted)
        case .error(let error): outcome.set(.failed(error))
        default: break
        }
      }
      continuation.finish()
    } catch {
      outcome.fail(error)
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }

  return handleUIMessageStreamFinish(
    chunks,
    messageId: responseMessageId ?? options.generateMessageId?(),
    originalMessages: options.originalMessages,
    onEnd: options.onEnd,
    getOutcome: { outcome.value })
}

extension StreamTextResult {
  /// The result as a UI message stream. Mirrors upstream `result.toUIMessageStream()`.
  public func toUIMessageStream(
    tools: ToolSet? = nil, options: UIMessageStreamOptions = UIMessageStreamOptions()
  ) -> AsyncThrowingStream<UIMessageChunk, any Error> {
    AISDK.toUIMessageStream(fullStream, tools: tools, options: options)
  }

  /// The result as a streaming HTTP response in the UI message stream protocol.
  /// Mirrors upstream `result.toUIMessageStreamResponse()`.
  public func toUIMessageStreamResponse(
    status: Int = 200, headers: [String: String]? = nil, tools: ToolSet? = nil,
    options: UIMessageStreamOptions = UIMessageStreamOptions()
  ) -> HTTPResponse {
    createUIMessageStreamResponse(
      status: status, headers: headers, stream: toUIMessageStream(tools: tools, options: options))
  }

  /// The text deltas as a streaming `text/plain` HTTP response.
  /// Mirrors upstream `result.toTextStreamResponse()`.
  public func toTextStreamResponse(status: Int = 200, headers: [String: String]? = nil) -> HTTPResponse {
    createTextStreamResponse(status: status, headers: headers, textStream: textStream)
  }
}

/// Tracks the declared outcome of a stream across tasks.
final class OutcomeTracker: @unchecked Sendable {
  enum Mode {
    /// `toUIMessageStream`: a later failure does not replace an earlier outcome.
    case source
    /// `createUIMessageStream`: only the first outcome is kept.
    case firstWins
  }

  private let lock = NSLock()
  private let mode: Mode
  private var outcome = UIMessageStreamOutcome.unknown
  private var hasFatalFailure = false

  init(mode: Mode) { self.mode = mode }

  var value: UIMessageStreamOutcome { lock.withLock { outcome } }

  func set(_ newOutcome: UIMessageStreamOutcome) {
    lock.withLock {
      guard !newOutcome.isUnknown else { return }
      switch mode {
      case .source:
        if !hasFatalFailure && !outcome.isCompleted && !outcome.isAborted
          && (outcome.isUnknown || !newOutcome.isFailed)
        {
          outcome = newOutcome
        }
      case .firstWins:
        if outcome.isUnknown { outcome = newOutcome }
      }
    }
  }

  func fail(_ error: any Error) {
    lock.withLock {
      hasFatalFailure = true
      outcome = .failed(error)
    }
  }
}

/// Injects the response message id into the `start` chunk and, when
/// callbacks are set, folds the stream into the response message to call
/// `onStepEnd` and `onEnd`. Mirrors upstream `handleUIMessageStreamFinish`.
public func handleUIMessageStreamFinish(
  _ stream: AsyncThrowingStream<UIMessageChunk, any Error>,
  messageId: String? = nil,
  originalMessages: [UIMessage]? = nil,
  onStepEnd: UIMessageStreamOnStepEnd? = nil,
  onEnd: UIMessageStreamOnEnd? = nil,
  onError: (@Sendable (any Error) -> Void)? = nil,
  getOutcome: (@Sendable () -> UIMessageStreamOutcome)? = nil
) -> AsyncThrowingStream<UIMessageChunk, any Error> {
  let originalMessages = originalMessages ?? []
  var lastMessage = originalMessages.last
  var messageId = messageId
  if let last = lastMessage, last.role == .assistant {
    messageId = last.id
  } else {
    lastMessage = nil
  }
  let finalMessageId = messageId
  let finalLastMessage = lastMessage

  let (output, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
  let task = Task {
    var state = StreamingUIMessageState(lastMessage: finalLastMessage, messageId: finalMessageId ?? "")
    var isAborted = false
    var processingError: (any Error)?
    let tracksMessage = onEnd != nil || onStepEnd != nil

    func messages() -> (isContinuation: Bool, messages: [UIMessage]) {
      let isContinuation = state.message.id == finalLastMessage?.id
      return (isContinuation, (isContinuation ? Array(originalMessages.dropLast()) : originalMessages) + [state.message])
    }

    func callOnEnd(isCancelled: Bool) async {
      guard let onEnd else { return }
      let declared = getOutcome?() ?? .unknown
      let outcome: UIMessageStreamOutcome =
        if let processingError { .failed(processingError) } else if declared.isUnknown && isAborted { .aborted } else {
          declared
        }
      let (isContinuation, allMessages) = messages()
      await onEnd(
        UIMessageStreamEndEvent(
          messages: allMessages, isContinuation: isContinuation, isAborted: isAborted || outcome.isAborted,
          isCancelled: isCancelled && outcome.isUnknown, outcome: outcome, responseMessage: state.message,
          finishReason: state.finishReason))
    }

    do {
      for try await chunk in stream {
        var chunk = chunk
        if case .start(.none, let metadata) = chunk, let finalMessageId {
          chunk = .start(messageId: finalMessageId, messageMetadata: metadata)
        }
        if case .abort = chunk { isAborted = true }

        if tracksMessage {
          do {
            _ = try state.apply(chunk)
          } catch {
            processingError = error
            throw error
          }
          if case .finishStep = chunk, let onStepEnd {
            let (isContinuation, allMessages) = messages()
            do {
              try await onStepEnd(
                UIMessageStreamStepEndEvent(
                  messages: allMessages, isContinuation: isContinuation, responseMessage: state.message))
            } catch {
              onError?(error)
            }
          }
        }
        continuation.yield(chunk)
      }
      await callOnEnd(isCancelled: Task.isCancelled)
      continuation.finish()
    } catch {
      await callOnEnd(isCancelled: true)
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}

/// Writes chunks into a stream created with `createUIMessageStream`.
/// Mirrors upstream `UIMessageStreamWriter`.
public struct UIMessageStreamWriter: Sendable {
  fileprivate let collector: UIMessageStreamCollector

  /// Appends a chunk to the stream.
  public func write(_ chunk: UIMessageChunk) {
    collector.continuation.yield(chunk)
  }

  /// Merges another UI message stream, e.g. `result.toUIMessageStream()`.
  /// The stream stays open until all merged streams finish.
  public func merge(_ stream: AsyncThrowingStream<UIMessageChunk, any Error>) {
    collector.track(
      Task { [collector] in
        do {
          for try await chunk in stream {
            collector.continuation.yield(chunk)
          }
        } catch {
          collector.handle(error)
        }
      })
  }

  /// Declares how the stream ended, e.g. after inspecting a `streamText` result.
  public func setOutcome(_ outcome: UIMessageStreamOutcome) {
    collector.outcome.set(outcome)
  }

  /// The error handler of the stream, for converting errors in merged work.
  public var onError: @Sendable (any Error) -> String { collector.onError }
}

fileprivate final class UIMessageStreamCollector: @unchecked Sendable {
  let continuation: AsyncThrowingStream<UIMessageChunk, any Error>.Continuation
  let onError: @Sendable (any Error) -> String
  let outcome = OutcomeTracker(mode: .firstWins)
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  init(
    continuation: AsyncThrowingStream<UIMessageChunk, any Error>.Continuation,
    onError: @escaping @Sendable (any Error) -> String
  ) {
    self.continuation = continuation
    self.onError = onError
  }

  func track(_ task: Task<Void, Never>) {
    lock.withLock { tasks.append(task) }
  }

  /// Waits for all tracked tasks, including tasks added while waiting.
  func waitForAll() async {
    while let task = lock.withLock({ tasks.isEmpty ? nil : tasks.removeFirst() }) {
      await task.value
    }
  }

  func cancelAll() {
    lock.withLock { tasks.forEach { $0.cancel() } }
  }

  func handle(_ error: any Error) {
    outcome.fail(error)
    continuation.yield(.error(errorText: onError(error)))
  }
}

/// Creates a UI message stream that `execute` writes to; merge `streamText`
/// results and write custom data parts. Mirrors upstream `createUIMessageStream`.
///
/// ```swift
/// let stream = createUIMessageStream { writer in
///   writer.write(.data(name: "status", data: "searching"))
///   let result = try streamText(model: model, prompt: "...")
///   writer.merge(result.toUIMessageStream())
/// }
/// ```
///
/// Errors thrown by `execute` or merged streams become `error` chunks with
/// the text returned by `onError`.
public func createUIMessageStream(
  onError: @escaping @Sendable (any Error) -> String = { _ in "An error occurred." },
  originalMessages: [UIMessage]? = nil,
  onStepEnd: UIMessageStreamOnStepEnd? = nil,
  onEnd: UIMessageStreamOnEnd? = nil,
  generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
  execute: @escaping @Sendable (UIMessageStreamWriter) async throws -> Void
) -> AsyncThrowingStream<UIMessageChunk, any Error> {
  let (stream, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
  let collector = UIMessageStreamCollector(continuation: continuation, onError: onError)
  let writer = UIMessageStreamWriter(collector: collector)

  let task = Task {
    do {
      try await execute(writer)
    } catch {
      collector.handle(error)
    }
    await collector.waitForAll()
    continuation.finish()
  }
  continuation.onTermination = { @Sendable _ in
    task.cancel()
    collector.cancelAll()
  }

  return handleUIMessageStreamFinish(
    stream,
    messageId: generateId(),
    originalMessages: originalMessages,
    onStepEnd: onStepEnd,
    onEnd: onEnd,
    onError: { _ = onError($0) },
    getOutcome: { collector.outcome.value })
}

// MARK: - Server-sent events

/// The response headers of the UI message stream protocol. Mirrors upstream `UI_MESSAGE_STREAM_HEADERS`.
public let uiMessageStreamHeaders: [String: String] = [
  "content-type": "text/event-stream",
  "cache-control": "no-cache",
  "connection": "keep-alive",
  "x-vercel-ai-ui-message-stream": "v1",
  "x-accel-buffering": "no",
]

/// Encodes chunks as server-sent events (`data: {json}\n\n`), ending with
/// `data: [DONE]\n\n`. Mirrors upstream `JsonToSseTransformStream`.
public func uiMessageStreamToSSE(
  _ stream: AsyncThrowingStream<UIMessageChunk, any Error>
) -> AsyncThrowingStream<String, any Error> {
  let (output, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
  let task = Task {
    do {
      for try await chunk in stream {
        continuation.yield("data: \(chunk.json.jsonString(sortedKeys: false))\n\n")
      }
      continuation.yield("data: [DONE]\n\n")
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}

/// Adds default headers that are not already set (case-insensitively).
func prepareHeaders(_ headers: [String: String]?, defaults: [String: String]) -> [String: String] {
  var result = headers ?? [:]
  for (name, value) in defaults where !result.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
    result[name] = value
  }
  return result
}

/// Creates a streaming HTTP response in the UI message stream protocol,
/// ready to hand to a server framework. Mirrors upstream `createUIMessageStreamResponse`.
///
/// - Parameter consumeSSEStream: Receives a copy of the SSE stream, e.g. to
///   store it for resumable streams. It is not awaited.
public func createUIMessageStreamResponse(
  status: Int = 200,
  headers: [String: String]? = nil,
  stream: AsyncThrowingStream<UIMessageChunk, any Error>,
  consumeSSEStream: (@Sendable (AsyncThrowingStream<String, any Error>) async -> Void)? = nil
) -> HTTPResponse {
  var sse = uiMessageStreamToSSE(stream)
  if let consumeSSEStream {
    let (primary, copy) = tee(sse)
    sse = primary
    Task { await consumeSSEStream(copy) }
  }
  return HTTPResponse(
    statusCode: status,
    headers: prepareHeaders(headers, defaults: uiMessageStreamHeaders),
    body: mapStream(sse) { Data($0.utf8) })
}

/// Creates a streaming `text/plain; charset=utf-8` HTTP response.
/// Mirrors upstream `createTextStreamResponse`.
public func createTextStreamResponse(
  status: Int = 200, headers: [String: String]? = nil, textStream: AsyncThrowingStream<String, any Error>
) -> HTTPResponse {
  HTTPResponse(
    statusCode: status,
    headers: prepareHeaders(headers, defaults: ["content-type": "text/plain; charset=utf-8"]),
    body: mapStream(textStream) { Data($0.utf8) })
}

/// Parses a server-sent event body in the UI message stream protocol into chunks.
///
/// - Throws: (from the stream) the parse or validation error of the first invalid event.
public func parseUIMessageStream(_ body: HTTPBodyStream) -> AsyncThrowingStream<UIMessageChunk, any Error> {
  let results = parseJsonEventStream(body, as: UIMessageChunk.self)
  return mapStream(results) { result in
    switch result {
    case .success(let chunk, _): return chunk
    case .failure(let error, _): throw error
    }
  }
}

/// Converts a plain text stream into UI message chunks: one text part in one
/// step. Mirrors upstream `transformTextToUiMessageStream`.
public func transformTextToUIMessageStream(
  _ stream: AsyncThrowingStream<String, any Error>
) -> AsyncThrowingStream<UIMessageChunk, any Error> {
  let (output, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
  let task = Task {
    continuation.yield(.start())
    continuation.yield(.startStep)
    continuation.yield(.textStart(id: "text-1"))
    do {
      for try await text in stream {
        continuation.yield(.textDelta(id: "text-1", delta: text))
      }
      continuation.yield(.textEnd(id: "text-1"))
      continuation.yield(.finishStep)
      continuation.yield(.finish())
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}

/// Decodes a UTF-8 byte stream into text, keeping multi-byte characters
/// that are split across chunks intact.
public func decodeUTF8Stream(_ body: HTTPBodyStream) -> AsyncThrowingStream<String, any Error> {
  let (output, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
  let task = Task {
    var pending = Data()
    do {
      for try await data in body {
        pending.append(data)
        let complete = completeUTF8Prefix(pending)
        if complete > 0 {
          continuation.yield(String(decoding: pending.prefix(complete), as: UTF8.self))
          pending = Data(pending.dropFirst(complete))
        }
      }
      if !pending.isEmpty {
        continuation.yield(String(decoding: pending, as: UTF8.self))
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}

/// The length of the longest prefix that does not end inside a UTF-8 sequence.
private func completeUTF8Prefix(_ data: Data) -> Int {
  guard !data.isEmpty else { return 0 }
  let bytes = [UInt8](data.suffix(3))
  let count = data.count
  for back in 1...min(3, bytes.count) {
    let byte = bytes[bytes.count - back]
    if byte & 0b1100_0000 == 0b1000_0000 { continue }
    let length =
      if byte & 0b1000_0000 == 0 { 1 } else if byte & 0b1110_0000 == 0b1100_0000 { 2 } else if byte & 0b1111_0000
        == 0b1110_0000
      { 3 } else if byte & 0b1111_1000 == 0b1111_0000 { 4 } else { 1 }
    return length > back ? count - back : count
  }
  return count
}

func mapStream<Input: Sendable, Output: Sendable>(
  _ stream: AsyncThrowingStream<Input, any Error>, _ transform: @escaping @Sendable (Input) throws -> Output
) -> AsyncThrowingStream<Output, any Error> {
  let (output, continuation) = AsyncThrowingStream<Output, any Error>.makeStream()
  let task = Task {
    do {
      for try await element in stream {
        continuation.yield(try transform(element))
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { @Sendable _ in task.cancel() }
  return output
}

/// Splits a stream into two streams that each receive every element.
func tee<Element: Sendable>(
  _ stream: AsyncThrowingStream<Element, any Error>
) -> (AsyncThrowingStream<Element, any Error>, AsyncThrowingStream<Element, any Error>) {
  let (first, firstContinuation) = AsyncThrowingStream<Element, any Error>.makeStream()
  let (second, secondContinuation) = AsyncThrowingStream<Element, any Error>.makeStream()
  let task = Task {
    do {
      for try await element in stream {
        firstContinuation.yield(element)
        secondContinuation.yield(element)
      }
      firstContinuation.finish()
      secondContinuation.finish()
    } catch {
      firstContinuation.finish(throwing: error)
      secondContinuation.finish(throwing: error)
    }
  }
  firstContinuation.onTermination = { @Sendable _ in task.cancel() }
  return (first, second)
}
