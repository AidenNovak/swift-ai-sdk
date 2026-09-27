import Foundation

/// The status of a chat. Mirrors upstream `ChatStatus`.
public enum ChatStatus: String, Sendable, Hashable {
  /// The request was sent and the response stream has not started yet.
  case submitted
  /// The response is streaming in.
  case streaming
  /// The chat is idle and a new message can be sent.
  case ready
  /// The last request failed; see `error`.
  case error
}

/// The storage behind a chat. UI frameworks implement it to observe changes,
/// e.g. `AISDKUI` stores it in an `@Observable` object. Mirrors upstream `ChatState`.
@MainActor
public protocol ChatState: AnyObject {
  var status: ChatStatus { get set }
  var error: (any Error)? { get set }
  var messages: [UIMessage] { get set }
  func pushMessage(_ message: UIMessage)
  func popMessage()
  func replaceMessage(at index: Int, with message: UIMessage)
}

extension ChatState {
  public func pushMessage(_ message: UIMessage) { messages.append(message) }
  public func popMessage() { _ = messages.popLast() }
  public func replaceMessage(at index: Int, with message: UIMessage) { messages[index] = message }
}

/// A plain chat state that reports changes through `onChange`, for AppKit,
/// command-line or server code.
@MainActor
public final class BasicChatState: ChatState {
  public var status: ChatStatus = .ready { didSet { onChange?() } }
  public var error: (any Error)? { didSet { onChange?() } }
  public var messages: [UIMessage] { didSet { onChange?() } }
  /// Called after every change.
  public var onChange: (@MainActor () -> Void)?

  public init(messages: [UIMessage] = []) {
    self.messages = messages
  }
}

/// Options sent with a chat request. Mirrors upstream `ChatRequestOptions`.
public struct ChatRequestOptions: Sendable {
  /// Additional HTTP headers.
  public var headers: [String: String]?
  /// Additional fields for the request body.
  public var body: JSONObject?
  /// Metadata for the transport's request preparation.
  public var metadata: JSONValue?

  public init(headers: [String: String]? = nil, body: JSONObject? = nil, metadata: JSONValue? = nil) {
    self.headers = headers
    self.body = body
    self.metadata = metadata
  }
}

/// A client-side tool call, passed to `onToolCall`.
public typealias ChatToolCall = UIToolInputAvailableChunk

/// Passed to `onFinish` when a response ends. Mirrors upstream `ChatOnFinishCallback`.
public struct ChatFinishEvent: Sendable {
  /// The response message.
  public var message: UIMessage
  /// All messages, including the response message.
  public var messages: [UIMessage]
  /// Whether the response was stopped with `stop()`.
  public var isAbort: Bool
  /// Whether the response ended because of a network failure.
  public var isDisconnect: Bool
  public var isError: Bool
  public var finishReason: FinishReason?
}

/// A message to send. Mirrors upstream's `sendMessage` argument forms.
public struct ChatMessageInput: Sendable {
  public var id: String?
  public var role: UIMessage.Role?
  public var metadata: JSONValue?
  public var parts: [UIMessagePart]
  /// The id of an earlier user message to replace; later messages are removed.
  public var messageId: String?

  public init(
    parts: [UIMessagePart], id: String? = nil, role: UIMessage.Role? = nil, metadata: JSONValue? = nil,
    messageId: String? = nil
  ) {
    self.parts = parts
    self.id = id
    self.role = role
    self.metadata = metadata
    self.messageId = messageId
  }

  /// A user message with optional files; files come before the text.
  public static func text(
    _ text: String?, files: [FileUIPart] = [], metadata: JSONValue? = nil, messageId: String? = nil
  ) -> ChatMessageInput {
    ChatMessageInput(
      parts: files.map(UIMessagePart.file) + (text.map { [.text(TextUIPart(text: $0))] } ?? []),
      metadata: metadata, messageId: messageId)
  }
}

/// Runs jobs one at a time, in order. Mirrors upstream `SerialJobExecutor`.
@MainActor
final class SerialJobExecutor {
  private var tail: Task<Void, Never>?

  func run(_ job: @escaping @MainActor () async throws -> Void) async throws {
    let previous = tail
    let task = Task { @MainActor () -> Result<Void, any Error> in
      await previous?.value
      do {
        try await job()
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    tail = Task { _ = await task.value }
    try await task.value.get()
  }
}

@MainActor
final class ChatAbortController {
  private(set) var isAborted = false
  var task: Task<Void, any Error>?

  func abort() {
    isAborted = true
    task?.cancel()
  }
}

@MainActor
final class ActiveChatResponse {
  var state: StreamingUIMessageState
  let abortController: ChatAbortController

  init(state: StreamingUIMessageState, abortController: ChatAbortController) {
    self.state = state
    self.abortController = abortController
  }
}

/// A chat session: sends messages through a transport and folds the streamed
/// response into the chat state. Mirrors upstream `AbstractChat`, the core of
/// `useChat`.
///
/// Framework-independent: `AISDKUI.Chat` adds SwiftUI observation; use
/// `AbstractChat(state: BasicChatState())` elsewhere.
@MainActor
open class AbstractChat {
  public enum Trigger: String, Sendable {
    case submitMessage = "submit-message"
    case regenerateMessage = "regenerate-message"
    case resumeStream = "resume-stream"
  }

  public let id: String
  public let generateId: IdGenerator
  public let state: any ChatState
  public let transport: any ChatTransport
  public let schemas: UIMessageStreamSchemas

  /// Called when a request fails.
  public var onError: (@MainActor (any Error) -> Void)?
  /// Called for client-side tool calls; add the result with `addToolOutput`.
  /// The next chunk is processed after it returns.
  public var onToolCall: (@MainActor (ChatToolCall) async -> Void)?
  /// Called when a response ends, including aborts and errors.
  public var onFinish: (@MainActor (ChatFinishEvent) -> Void)?
  /// Called for every data part, including transient ones.
  public var onData: (@MainActor (DataUIPart) -> Void)?
  /// Decides whether to send the messages again after a response or a tool
  /// output, e.g. `lastAssistantMessageIsCompleteWithToolCalls`.
  public var sendAutomaticallyWhen: (@MainActor ([UIMessage]) async -> Bool)?

  private let jobExecutor = SerialJobExecutor()
  private var activeResponse: ActiveChatResponse?
  private var activeResumeRequest: ChatAbortController?
  private var pendingApprovalMessageId: String?

  public init(
    id: String? = nil,
    state: any ChatState,
    transport: any ChatTransport,
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    schemas: UIMessageStreamSchemas = UIMessageStreamSchemas(),
    onError: (@MainActor (any Error) -> Void)? = nil,
    onToolCall: (@MainActor (ChatToolCall) async -> Void)? = nil,
    onFinish: (@MainActor (ChatFinishEvent) -> Void)? = nil,
    onData: (@MainActor (DataUIPart) -> Void)? = nil,
    sendAutomaticallyWhen: (@MainActor ([UIMessage]) async -> Bool)? = nil
  ) {
    self.generateId = generateId
    self.id = id ?? generateId()
    self.state = state
    self.transport = transport
    self.schemas = schemas
    self.onError = onError
    self.onToolCall = onToolCall
    self.onFinish = onFinish
    self.onData = onData
    self.sendAutomaticallyWhen = sendAutomaticallyWhen
  }

  public var status: ChatStatus { state.status }
  public var error: (any Error)? { state.error }
  public var lastMessage: UIMessage? { state.messages.last }

  public var messages: [UIMessage] {
    get { state.messages }
    set { state.messages = newValue }
  }

  private func setStatus(_ status: ChatStatus, error: (any Error)? = nil) {
    guard state.status != status else { return }
    state.status = status
    state.error = error
  }

  /// Sends a message and streams the response. Without a message, sends the
  /// current messages again, e.g. after answering tool approvals.
  ///
  /// - Throws: `InvalidArgumentError` when `messageId` does not name a user
  ///   message. Request failures are reported through `status`, `error` and `onError`.
  public func sendMessage(_ message: ChatMessageInput? = nil, options: ChatRequestOptions = ChatRequestOptions())
    async throws
  {
    guard let message else {
      var messageId = pendingApprovalMessageId
      if messageId == nil {
        messageId =
          state.messages.last { candidate in
            candidate.role == .assistant && candidate.parts.contains { $0.toolPart?.state == .approvalResponded }
          }?.id ?? lastMessage?.id
      }
      let consumesPendingApproval = messageId != nil && messageId == pendingApprovalMessageId
      let index = consumesPendingApproval ? state.messages.firstIndex { $0.id == messageId } : nil
      await makeRequestForToolApproval(messageId: messageId, messageIndex: index, options: options)
      return
    }

    if let messageId = message.messageId {
      guard let index = state.messages.firstIndex(where: { $0.id == messageId }) else {
        throw InvalidArgumentError(argument: "message.messageId", message: "message with id \(messageId) not found")
      }
      guard state.messages[index].role == .user else {
        throw InvalidArgumentError(
          argument: "message.messageId", message: "message with id \(messageId) is not a user message")
      }
      state.messages = Array(state.messages.prefix(index + 1))
      state.replaceMessage(
        at: index,
        with: UIMessage(id: messageId, role: message.role ?? .user, metadata: message.metadata, parts: message.parts))
    } else {
      state.pushMessage(
        UIMessage(
          id: message.id ?? generateId(), role: message.role ?? .user, metadata: message.metadata, parts: message.parts))
    }

    await makeRequest(trigger: .submitMessage, messageId: message.messageId, options: options)
  }

  /// Sends a user message with text and optional files.
  public func sendMessage(
    text: String, files: [FileUIPart] = [], metadata: JSONValue? = nil, options: ChatRequestOptions = ChatRequestOptions()
  ) async throws {
    try await sendMessage(.text(text, files: files, metadata: metadata), options: options)
  }

  /// Regenerates the assistant message (the last one by default) or the
  /// response to a user message.
  public func regenerate(messageId: String? = nil, options: ChatRequestOptions = ChatRequestOptions()) async throws {
    let index = messageId.map { id in state.messages.firstIndex { $0.id == id } } ?? state.messages.indices.last
    guard let index else {
      throw InvalidArgumentError(argument: "messageId", message: "message \(messageId ?? "") not found")
    }
    state.messages = Array(state.messages.prefix(state.messages[index].role == .assistant ? index : index + 1))
    await makeRequest(trigger: .regenerateMessage, messageId: messageId, options: options)
  }

  /// Reconnects to a response that is still streaming on the server.
  public func resumeStream(options: ChatRequestOptions = ChatRequestOptions()) async {
    await makeRequest(trigger: .resumeStream, messageId: nil, options: options)
  }

  /// Clears the error and returns to `ready`.
  public func clearError() {
    guard state.status == .error else { return }
    state.error = nil
    setStatus(.ready)
  }

  /// Stops the current response.
  public func stop() {
    activeResumeRequest?.abort()
    activeResponse?.abortController.abort()
  }

  /// Answers a tool approval request. When `sendAutomaticallyWhen` allows
  /// it, the follow-up request starts in the background.
  public func addToolApprovalResponse(
    id: String, approved: Bool, reason: String? = nil, options: ChatRequestOptions = ChatRequestOptions()
  ) async {
    func update(_ part: UIMessagePart) -> UIMessagePart {
      guard case .tool(var tool) = part, tool.state == .approvalRequested, tool.approval?.id == id else { return part }
      tool.state = .approvalResponded
      var approval = tool.approval ?? ToolUIApproval(id: id)
      approval.id = id
      approval.approved = approved
      approval.reason = reason
      tool.approval = approval
      return .tool(tool)
    }

    var messageIndex: Int?
    try? await jobExecutor.run { [self] in
      messageIndex = state.messages.firstIndex { message in
        message.parts.contains { $0.toolPart?.state == .approvalRequested && $0.toolPart?.approval?.id == id }
      }
      if let messageIndex {
        var message = state.messages[messageIndex]
        message.parts = message.parts.map(update)
        state.replaceMessage(at: messageIndex, with: message)
        pendingApprovalMessageId = message.id
      }
      activeResponse?.state.message.parts = activeResponse?.state.message.parts.map(update) ?? []
    }

    guard state.status != .streaming, state.status != .submitted, sendAutomaticallyWhen != nil else { return }
    let messageId = messageIndex.map { state.messages[$0].id } ?? lastMessage?.id
    Task { [self] in
      if await shouldSendAutomatically() {
        await makeRequestForToolApproval(messageId: messageId, messageIndex: messageIndex, options: options)
      }
    }
  }

  /// Adds the output of a client-side tool call to the last message. When
  /// `sendAutomaticallyWhen` allows it, the follow-up request starts in the background.
  ///
  /// - Parameter errorText: Set instead of `output` to report a tool failure (`output-error`).
  public func addToolOutput(
    toolCallId: String, output: JSONValue? = nil, errorText: String? = nil,
    options: ChatRequestOptions = ChatRequestOptions()
  ) async {
    let newState: ToolUIPartState = errorText != nil ? .outputError : .outputAvailable
    func update(_ part: UIMessagePart) -> UIMessagePart {
      guard case .tool(var tool) = part, tool.toolCallId == toolCallId else { return part }
      tool.state = newState
      tool.output = output
      tool.errorText = errorText
      return .tool(tool)
    }

    try? await jobExecutor.run { [self] in
      if let last = state.messages.indices.last {
        var message = state.messages[last]
        message.parts = message.parts.map(update)
        state.replaceMessage(at: last, with: message)
      }
      activeResponse?.state.message.parts = activeResponse?.state.message.parts.map(update) ?? []
    }

    guard state.status != .streaming, state.status != .submitted, sendAutomaticallyWhen != nil else { return }
    Task { [self] in
      if await shouldSendAutomatically() {
        await makeRequest(trigger: .submitMessage, messageId: lastMessage?.id, options: options)
      }
    }
  }

  private func shouldSendAutomatically() async -> Bool {
    guard let sendAutomaticallyWhen else { return false }
    return await sendAutomaticallyWhen(state.messages)
  }

  private func makeRequestForToolApproval(messageId: String?, messageIndex: Int?, options: ChatRequestOptions) async {
    let consumesPendingApproval = messageId != nil && messageId == pendingApprovalMessageId
    if consumesPendingApproval {
      pendingApprovalMessageId = nil
    }
    await makeRequest(trigger: .submitMessage, messageId: messageId, options: options)
    if consumesPendingApproval && state.status == .error && pendingApprovalMessageId == nil {
      pendingApprovalMessageId = messageIndex.flatMap { state.messages.indices.contains($0) ? state.messages[$0].id : nil }
        ?? messageId
    }
  }

  private func makeRequest(trigger: Trigger, messageId: String?, options: ChatRequestOptions) async {
    let abortController = ChatAbortController()
    let isResume = trigger == .resumeStream
    if isResume {
      activeResumeRequest?.abort()
      activeResumeRequest = abortController
    }
    let isCurrentRequest = { [unowned self] in !isResume || activeResumeRequest === abortController }
    let clearActiveResumeRequest = { [unowned self] in
      if activeResumeRequest === abortController { activeResumeRequest = nil }
    }

    var resumeStream: AsyncThrowingStream<UIMessageChunk, any Error>?
    if isResume {
      do {
        let reconnect = try await transport.reconnectToStream(
          ChatReconnectRequest(chatId: id, options: options))
        if abortController.isAborted || !isCurrentRequest() {
          if isCurrentRequest() { setStatus(.ready) }
          clearActiveResumeRequest()
          return
        }
        guard let reconnect else {
          setStatus(.ready)
          clearActiveResumeRequest()
          return
        }
        resumeStream = reconnect
      } catch {
        if abortController.isAborted || isCancellationError(error) {
          if isCurrentRequest() { setStatus(.ready) }
          clearActiveResumeRequest()
          return
        }
        guard isCurrentRequest() else { return }
        onError?(error)
        setStatus(.error, error: error)
        clearActiveResumeRequest()
        return
      }
    }

    setStatus(.submitted)

    let responseMessageIndex =
      trigger == .submitMessage && messageId != nil
      ? state.messages.firstIndex { $0.id == messageId } : state.messages.indices.last
    let responseMessage = responseMessageIndex.map { state.messages[$0] } ?? lastMessage
    let usesEarlierAssistantMessage =
      responseMessageIndex.map { $0 < state.messages.count - 1 } == true && responseMessage?.role == .assistant

    let response = ActiveChatResponse(
      state: StreamingUIMessageState(
        lastMessage: trigger == .submitMessage ? responseMessage : nil, messageId: generateId()),
      abortController: abortController)
    activeResponse = response

    var isAbort = false
    var isDisconnect = false
    var isError = false
    var isStale = false

    let requestMessages = state.messages
    let work = Task { @MainActor [self] in
      let stream: AsyncThrowingStream<UIMessageChunk, any Error>
      if let resumeStream {
        stream = resumeStream
      } else {
        stream = try await transport.sendMessages(
          ChatSendMessagesRequest(
            trigger: trigger == .regenerateMessage ? .regenerateMessage : .submitMessage, chatId: id,
            messageId: messageId, messages: requestMessages, options: options))
      }

      for try await chunk in stream {
        if response.abortController.isAborted { break }
        var toolCalls: [ChatToolCall] = []
        try await jobExecutor.run { [self] in
          guard !response.abortController.isAborted else { return }
          for event in try response.state.apply(chunk, schemas: schemas) {
            switch event {
            case .write(let updateStatus):
              write(
                response, updateStatus: updateStatus, responseMessageIndex: responseMessageIndex,
                usesEarlierAssistantMessage: usesEarlierAssistantMessage)
            case .toolCall(let call):
              toolCalls.append(call)
            case .data(let part):
              onData?(part)
            case .error(let errorText):
              throw UIMessageStreamError(chunkType: "error", chunkId: "", message: errorText)
            }
          }
        }
        for call in toolCalls {
          await onToolCall?(call)
        }
      }
    }
    abortController.task = work

    do {
      try await withTaskCancellationHandler {
        try await work.value
      } onCancel: {
        Task { @MainActor in abortController.abort() }
      }
      if abortController.isAborted { isAbort = true }
      if isCurrentRequest() { setStatus(.ready) }
    } catch {
      if abortController.isAborted || isCancellationError(error) {
        isAbort = true
        if isCurrentRequest() { setStatus(.ready) }
      } else if !isCurrentRequest() {
        isStale = true
      } else {
        isError = true
        isDisconnect = isNetworkError(error)
        onError?(error)
        setStatus(.error, error: error)
      }
    }

    onFinish?(
      ChatFinishEvent(
        message: response.state.message, messages: state.messages, isAbort: isAbort, isDisconnect: isDisconnect,
        isError: isError, finishReason: response.state.finishReason))
    if activeResponse === response { activeResponse = nil }
    clearActiveResumeRequest()

    guard !isAbort, !isError, !isStale else { return }
    if await shouldSendAutomatically() {
      await makeRequest(trigger: .submitMessage, messageId: lastMessage?.id, options: options)
    }
  }

  private func write(
    _ response: ActiveChatResponse, updateStatus: Bool, responseMessageIndex: Int?, usesEarlierAssistantMessage: Bool
  ) {
    guard !response.abortController.isAborted else { return }
    if updateStatus { setStatus(.streaming) }
    if usesEarlierAssistantMessage, let responseMessageIndex {
      state.replaceMessage(at: responseMessageIndex, with: response.state.message)
    } else if response.state.message.id == lastMessage?.id, let last = state.messages.indices.last {
      state.replaceMessage(at: last, with: response.state.message)
    } else {
      state.pushMessage(response.state.message)
    }
  }
}

/// Whether the last assistant message's last step has client-side tool calls
/// that all have results; use with `sendAutomaticallyWhen`.
/// Mirrors upstream `lastAssistantMessageIsCompleteWithToolCalls`.
public func lastAssistantMessageIsCompleteWithToolCalls(_ messages: [UIMessage]) -> Bool {
  guard let message = messages.last, message.role == .assistant else { return false }
  let start = message.parts.lastIndex(of: .stepStart).map { $0 + 1 } ?? 0
  let invocations = message.parts[start...].compactMap(\.toolPart).filter { $0.providerExecuted != true }
  return !invocations.isEmpty
    && invocations.allSatisfy {
      ($0.state == .outputAvailable && $0.preliminary != true) || $0.state == .outputError
    }
}

/// Whether the last assistant message's last step has answered approvals
/// and no pending tool calls; use with `sendAutomaticallyWhen`.
/// Mirrors upstream `lastAssistantMessageIsCompleteWithApprovalResponses`.
public func lastAssistantMessageIsCompleteWithApprovalResponses(_ messages: [UIMessage]) -> Bool {
  guard let message = messages.last, message.role == .assistant else { return false }
  let start = message.parts.lastIndex(of: .stepStart).map { $0 + 1 } ?? 0
  let invocations = message.parts[start...].compactMap(\.toolPart)
  return invocations.contains { $0.state == .approvalResponded }
    && invocations.allSatisfy {
      ($0.state == .outputAvailable && $0.preliminary != true) || $0.state == .outputError
        || $0.state == .outputDenied || $0.state == .approvalResponded
    }
}
