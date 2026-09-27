import AISDK
import AISDKTestUtils
import Foundation
import Testing

private let chatCases: [JSONValue] = {
  guard let url = Bundle.module.url(forResource: "ui-conformance", withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url), let json = try? JSONValue(jsonData: data)
  else { return [] }
  return json["chat"]?.arrayValue ?? []
}()

/// Records status transitions like the `RecordingState` of the generator.
@MainActor
final class RecordingChatState: ChatState {
  var statuses: [ChatStatus] = []
  var status: ChatStatus = .ready { didSet { statuses.append(status) } }
  var error: (any Error)?
  var messages: [UIMessage]

  init(messages: [UIMessage]) {
    self.messages = messages
  }
}

/// Replies to each request with the next scripted response and records the requests.
final class ScriptedChatTransport: ChatTransport, @unchecked Sendable {
  enum Response {
    case chunks([UIMessageChunk])
    case failure(String)
  }

  private let lock = NSLock()
  private var responses: [Response]
  private var recorded: [ChatSendMessagesRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

  var requests: [ChatSendMessagesRequest] { lock.withLock { recorded } }

  func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    let response = lock.withLock { () -> Response in
      recorded.append(request)
      return responses.isEmpty ? .failure("no scripted response") : responses.removeFirst()
    }
    switch response {
    case .chunks(let chunks): return streamFromArray(chunks)
    case .failure(let message): throw TestFailure(description: message)
    }
  }

  func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    nil
  }
}

func counterIdGenerator() -> IdGenerator {
  let counter = LockedCounter()
  return { "id-\(counter.next())" }
}

final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.withLock {
      defer { value += 1 }
      return value
    }
  }
}

/// Waits until the chat has been idle for several consecutive checks, like the generator's `settle`.
@MainActor
func settle(_ chat: AbstractChat) async throws {
  var stable = 0
  while stable < 5 {
    try await Task.sleep(for: .milliseconds(5))
    stable = chat.status == .submitted || chat.status == .streaming ? 0 : stable + 1
  }
}

private func requestJSON(_ request: ChatSendMessagesRequest) -> JSONValue {
  var json: JSONObject = [
    "trigger": .string(request.trigger.rawValue), "chatId": .string(request.chatId),
    "messages": .array(request.messages.map(\.json)),
  ]
  if let messageId = request.messageId { json["messageId"] = .string(messageId) }
  return .object(json)
}

private func finishJSON(_ event: ChatFinishEvent) -> JSONValue {
  var json: JSONObject = [
    "messageId": .string(event.message.id), "messageCount": .number(Double(event.messages.count)),
    "isAbort": .bool(event.isAbort), "isDisconnect": .bool(event.isDisconnect), "isError": .bool(event.isError),
  ]
  if let finishReason = event.finishReason { json["finishReason"] = .string(finishReason.rawValue) }
  return .object(json)
}

private func scriptedResponses(_ json: JSONValue?) throws -> [ScriptedChatTransport.Response] {
  try (json?.arrayValue ?? []).map { response in
    if let error = response["error"]?.stringValue { return .failure(error) }
    return .chunks(try (response["chunks"]?.arrayValue ?? []).map(UIMessageChunk.init(json:)))
  }
}

@MainActor
private final class ChatRecorder {
  var finishes: [JSONValue] = []
  var toolCalls: [JSONValue] = []
  var data: [JSONValue] = []
  var errors: [String] = []
}

@MainActor
private func perform(_ op: JSONValue, on chat: AbstractChat) async throws {
  switch op["op"]?.stringValue {
  case "send":
    try await chat.sendMessage(
      .text(op["text"]?.stringValue, metadata: op["metadata"], messageId: op["messageId"]?.stringValue))
  case "sendEmpty":
    try await chat.sendMessage()
  case "regenerate":
    try await chat.regenerate(messageId: op["messageId"]?.stringValue)
  case "addToolOutput":
    await chat.addToolOutput(
      toolCallId: op["toolCallId"]?.stringValue ?? "", output: op["output"], errorText: op["errorText"]?.stringValue)
  case "approve":
    await chat.addToolApprovalResponse(
      id: op["id"]?.stringValue ?? "", approved: op["approved"]?.boolValue ?? false, reason: op["reason"]?.stringValue)
  case "clearError":
    chat.clearError()
  default:
    Issue.record("unknown op \(op)")
  }
}

@MainActor
@Test("AbstractChat matches upstream", arguments: chatCases.compactMap { $0["name"]?.stringValue })
func chatConformance(name: String) async throws {
  let expected = try #require(chatCases.first { $0["name"]?.stringValue == name })
  let state = RecordingChatState(
    messages: try (expected["initialMessages"]?.arrayValue ?? []).map(UIMessage.init(json:)))
  let transport = ScriptedChatTransport(responses: try scriptedResponses(expected["responses"]))
  let recorder = ChatRecorder()
  let clientTools = expected["clientTools"]?.objectValue ?? [:]

  let chat = AbstractChat(id: "chat-1", state: state, transport: transport, generateId: counterIdGenerator())
  chat.onData = { part in recorder.data.append(UIMessagePart.data(part).json) }
  chat.onError = { error in recorder.errors.append((error as? any AISDKError)?.message ?? "\(error)") }
  chat.onFinish = { event in recorder.finishes.append(finishJSON(event)) }
  chat.onToolCall = { [unowned chat] call in
    recorder.toolCalls.append(UIMessageChunk.toolInputAvailable(call).json)
    if let output = clientTools[call.toolName] {
      await chat.addToolOutput(toolCallId: call.toolCallId, output: output)
    }
  }
  switch expected["autoSend"]?.stringValue {
  case "toolCalls": chat.sendAutomaticallyWhen = { lastAssistantMessageIsCompleteWithToolCalls($0) }
  case "approvals": chat.sendAutomaticallyWhen = { lastAssistantMessageIsCompleteWithApprovalResponses($0) }
  default: break
  }

  for op in expected["ops"]?.arrayValue ?? [] {
    try await perform(op, on: chat)
    try await settle(chat)
  }

  let differences = UpstreamConformance.differences(
    [
      "requests": expected["requests"] ?? [], "messages": expected["messages"] ?? [],
      "statuses": expected["statuses"] ?? [], "status": expected["status"] ?? .null,
      "finishes": expected["finishes"] ?? [], "toolCalls": expected["toolCalls"] ?? [], "data": expected["data"] ?? [],
      "errors": expected["errors"] ?? [],
    ],
    [
      "requests": .array(transport.requests.map(requestJSON)), "messages": .array(state.messages.map(\.json)),
      "statuses": .array(state.statuses.map { .string($0.rawValue) }), "status": .string(state.status.rawValue),
      "finishes": .array(recorder.finishes), "toolCalls": .array(recorder.toolCalls), "data": .array(recorder.data),
      "errors": .array(recorder.errors.map(JSONValue.string)),
    ])
  #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
}
