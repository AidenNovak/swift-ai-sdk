import AISDK
import Observation

/// A chat state that SwiftUI (or `withObservationTracking`) observes.
///
/// With `throttle`, message change notifications are coalesced so long
/// streams do not re-render on every token; readers always see the latest
/// messages. Status and error changes are delivered immediately.
@MainActor
public final class ObservableChatState: ChatState, Observable {
  private let registrar = ObservationRegistrar()
  private let throttle: Duration?
  private var storedMessages: [UIMessage]
  private var storedStatus: ChatStatus = .ready
  private var storedError: (any Error)?
  private var pendingNotification: Task<Void, Never>?

  public init(messages: [UIMessage] = [], throttle: Duration? = nil) {
    self.storedMessages = messages
    self.throttle = throttle
  }

  public var messages: [UIMessage] {
    get {
      registrar.access(self, keyPath: \.messages)
      return storedMessages
    }
    set {
      guard let throttle else {
        registrar.withMutation(of: self, keyPath: \.messages) { storedMessages = newValue }
        return
      }
      storedMessages = newValue
      guard pendingNotification == nil else { return }
      pendingNotification = Task { [weak self] in
        try? await Task.sleep(for: throttle)
        self?.flushMessages()
      }
    }
  }

  public var status: ChatStatus {
    get {
      registrar.access(self, keyPath: \.status)
      return storedStatus
    }
    set {
      if newValue == .ready || newValue == .error { flushMessages() }
      registrar.withMutation(of: self, keyPath: \.status) { storedStatus = newValue }
    }
  }

  public var error: (any Error)? {
    get {
      registrar.access(self, keyPath: \.error)
      return storedError
    }
    set {
      registrar.withMutation(of: self, keyPath: \.error) { storedError = newValue }
    }
  }

  /// Delivers a pending throttled message notification now.
  private func flushMessages() {
    guard let task = pendingNotification else { return }
    pendingNotification = nil
    task.cancel()
    registrar.withMutation(of: self, keyPath: \.messages) {}
  }
}

/// An observable chat for SwiftUI. Mirrors `useChat` from `@ai-sdk/react`.
///
/// ```swift
/// struct ChatView: View {
///   @State private var chat = Chat(transport: DirectChatTransport(agent: agent))
///   @State private var input = ""
///
///   var body: some View {
///     List(chat.messages) { message in Text(message.text) }
///     TextField("Message", text: $input).onSubmit {
///       let text = input
///       input = ""
///       Task { try await chat.sendMessage(text: text) }
///     }
///     if chat.status == .streaming { Button("Stop") { chat.stop() } }
///   }
/// }
/// ```
///
/// `messages`, `status` and `error` are observable. Set callbacks such as
/// `onToolCall` or `sendAutomaticallyWhen` at creation or later.
@MainActor
public final class Chat: AbstractChat, Observable {
  /// The observable state behind the chat.
  public let observableState: ObservableChatState

  /// - Parameters:
  ///   - messages: The initial messages, e.g. restored from storage.
  ///   - transport: Where messages go: `DirectChatTransport` for in-process
  ///     agents, `DefaultChatTransport` for a UI message stream endpoint.
  ///   - throttle: Coalesces message updates, e.g. `.milliseconds(50)`.
  public init(
    id: String? = nil,
    messages: [UIMessage] = [],
    transport: any ChatTransport,
    throttle: Duration? = nil,
    generateId: @escaping IdGenerator = AISDKProviderUtils.generateId,
    schemas: UIMessageStreamSchemas = UIMessageStreamSchemas(),
    onError: (@MainActor (any Error) -> Void)? = nil,
    onToolCall: (@MainActor (ChatToolCall) async -> Void)? = nil,
    onFinish: (@MainActor (ChatFinishEvent) -> Void)? = nil,
    onData: (@MainActor (DataUIPart) -> Void)? = nil,
    sendAutomaticallyWhen: (@MainActor ([UIMessage]) async -> Bool)? = nil
  ) {
    let state = ObservableChatState(messages: messages, throttle: throttle)
    observableState = state
    super.init(
      id: id, state: state, transport: transport, generateId: generateId, schemas: schemas, onError: onError,
      onToolCall: onToolCall, onFinish: onFinish, onData: onData, sendAutomaticallyWhen: sendAutomaticallyWhen)
  }
}
