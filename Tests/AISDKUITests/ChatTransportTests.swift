import AISDK
import AISDKTestUtils
import AISDKUI
import Foundation
import Observation
import Testing

private let api = URL(string: "https://example.com/api/chat?tenant=1")!

private func sse(_ chunks: [UIMessageChunk]) -> [String] {
  chunks.map { "data: \($0.json.jsonString())\n\n" } + ["data: [DONE]\n\n"]
}

private let helloChunks: [UIMessageChunk] = [
  .start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Hello"), .textEnd(id: "t"),
  .finishStep, .finish(finishReason: .stop),
]

private let userMessage = UIMessage(id: "u1", role: .user, parts: [.text(TextUIPart(text: "Hi"))])

@Suite struct ChatTransportTests {
  @Test func defaultTransportPostsUpstreamRequestBody() async throws {
    let http = MockHTTPClient([api.absoluteString: .streamChunks(sse(helloChunks))])
    let transport = DefaultChatTransport(
      api: api, headers: ["authorization": "Bearer t"], body: ["model": "fast"], httpClient: http)
    let stream = try await transport.sendMessages(
      ChatSendMessagesRequest(
        trigger: .submitMessage, chatId: "chat-1", messageId: nil, messages: [userMessage],
        options: ChatRequestOptions(headers: ["x-request": "1"], body: ["temperature": 0.5])))
    let chunks = try await collect(stream)
    #expect(chunks == helloChunks)

    let request = try #require(http.lastRequest)
    #expect(request.method == "POST")
    #expect(request.headers["content-type"] == "application/json")
    #expect(request.headers["authorization"] == "Bearer t")
    #expect(request.headers["x-request"] == "1")
    #expect(
      request.bodyJSON
        == [
          "id": "chat-1", "messages": [userMessage.json], "trigger": "submit-message", "model": "fast",
          "temperature": 0.5,
        ])
  }

  @Test func prepareSendMessagesRequestReplacesBodyHeadersAndURL() async throws {
    let other = URL(string: "https://example.com/other")!
    let http = MockHTTPClient([other.absoluteString: .streamChunks(sse(helloChunks))])
    let options = HTTPChatTransportOptions(api: api, httpClient: http) { prepare in
      #expect(prepare.trigger == .regenerateMessage)
      #expect(prepare.messageId == "a1")
      return PreparedSendMessagesRequest(
        body: ["last": prepare.messages.last?.json ?? .null], headers: ["x-only": "yes"], api: other)
    }
    let transport = DefaultChatTransport(options: options)
    _ = try await collect(
      try await transport.sendMessages(
        ChatSendMessagesRequest(trigger: .regenerateMessage, chatId: "c", messageId: "a1", messages: [userMessage])))
    let request = try #require(http.lastRequest)
    #expect(request.url == other)
    #expect(request.headers["x-only"] == "yes")
    #expect(request.bodyJSON == ["last": userMessage.json])
  }

  @Test func errorStatusBecomesAPICallError() async throws {
    let http = MockHTTPClient([api.absoluteString: .error(statusCode: 429, body: "slow down")])
    let transport = DefaultChatTransport(api: api, httpClient: http)
    await #expect {
      _ = try await transport.sendMessages(
        ChatSendMessagesRequest(trigger: .submitMessage, chatId: "c", messageId: nil, messages: [userMessage]))
    } throws: { error in
      guard let error = error as? APICallError else { return false }
      return error.statusCode == 429 && error.message == "slow down"
    }
  }

  @Test func reconnectUsesStreamPathAndTreats204AsNoStream() async throws {
    let streamURL = "https://example.com/api/chat/chat-1/stream?tenant=1"
    let http = MockHTTPClient([streamURL: .empty(statusCode: 204)])
    let transport = DefaultChatTransport(api: api, httpClient: http)
    let stream = try await transport.reconnectToStream(ChatReconnectRequest(chatId: "chat-1"))
    #expect(stream == nil)
    #expect(http.lastRequest?.method == "GET")
    #expect(http.lastRequest?.url.absoluteString == streamURL)
  }

  @Test func textTransportWrapsPlainText() async throws {
    let http = MockHTTPClient([api.absoluteString: .streamChunks(["Hel", "lo"])])
    let transport = TextStreamChatTransport(api: api, httpClient: http)
    let chunks = try await collect(
      try await transport.sendMessages(
        ChatSendMessagesRequest(trigger: .submitMessage, chatId: "c", messageId: nil, messages: [userMessage])))
    let message = try await collect(readUIMessageStream(stream: streamFromArray(chunks))).last
    #expect(message?.text == "Hello")
  }

  @Test func completionAPIAccumulatesDeltas() async throws {
    let http = MockHTTPClient([api.absoluteString: .streamChunks(sse(helloChunks))])
    let updates = LockedValues<String>()
    let result = try await callCompletionAPI(
      api: api, prompt: "Say hi", body: ["style": "short"], httpClient: http
    ) { updates.append($0) }
    #expect(result == "Hello")
    #expect(updates.values == ["Hello"])
    #expect(http.lastRequest?.bodyJSON == ["prompt": "Say hi", "style": "short"])
    #expect(http.lastRequest?.headers["user-agent"]?.contains("ai-sdk/swift") == true)
  }
}

@MainActor
@Suite struct ChatTests {
  @Test func directTransportRunsAnAgentWithTools() async throws {
    let model = MockLanguageModelV4(
      doStream: .sequence([
        [
          .toolCall(LanguageModelV4ToolCall(toolCallId: "c1", toolName: "weather", input: #"{"city":"Paris"}"#)),
          .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .toolCalls)),
        ],
        [
          .textStart(id: "0"), .textDelta(id: "0", delta: "20 degrees in Paris."), .textEnd(id: "0"),
          .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .stop)),
        ],
      ]))
    let weather = Tool(inputSchema: citySchema, execute: { input, _ in ["temperature": 20, "city": input["city"] ?? .null] })
    let agent = ToolLoopAgent(model: model, tools: ["weather": weather])
    let chat = Chat(transport: DirectChatTransport(agent: agent), generateId: counterIdGenerator())

    try await chat.sendMessage(text: "Weather in Paris?")

    #expect(chat.status == .ready)
    #expect(chat.messages.count == 2)
    let assistant = try #require(chat.messages.last)
    #expect(assistant.role == .assistant)
    #expect(assistant.text == "20 degrees in Paris.")
    #expect(assistant.toolParts.first?.state == .outputAvailable)
    #expect(assistant.toolParts.first?.output == ["temperature": 20, "city": "Paris"])

    let secondPrompt = try #require(model.doStreamCalls.last?.prompt)
    #expect(secondPrompt.count == 3)
  }

  @Test func stopAbortsTheResponse() async throws {
    let (stream, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
    continuation.yield(.start(messageId: "a1"))
    continuation.yield(.textStart(id: "t"))
    continuation.yield(.textDelta(id: "t", delta: "Partial"))
    let transport = SingleStreamTransport(stream: stream)
    let finishes = LockedValues<ChatFinishEvent>()
    let chat = Chat(transport: transport, onFinish: { finishes.append($0) })

    let send = Task { try await chat.sendMessage(text: "Hi") }
    while chat.messages.last?.text != "Partial" { try await Task.sleep(for: .milliseconds(2)) }
    #expect(chat.status == .streaming)
    chat.stop()
    try await send.value

    #expect(chat.status == .ready)
    #expect(chat.messages.last?.text == "Partial")
    #expect(finishes.values.first?.isAbort == true)
    continuation.finish()
  }

  @Test func sendMessageRejectsUnknownMessageIds() async throws {
    let chat = Chat(transport: SingleStreamTransport(stream: streamFromArray(helloChunks)))
    await #expect(throws: InvalidArgumentError.self) {
      try await chat.sendMessage(.text("x", messageId: "missing"))
    }
  }

  @Test func observationNotifiesMessageAndStatusChanges() async throws {
    let chat = Chat(transport: SingleStreamTransport(stream: streamFromArray(helloChunks)))
    let changes = LockedValues<String>()
    func track() {
      withObservationTracking {
        _ = chat.messages
        _ = chat.status
      } onChange: {
        changes.append("change")
      }
    }
    track()
    try await chat.sendMessage(text: "Hi")
    #expect(changes.values.count == 1)
    #expect(chat.messages.last?.text == "Hello")
  }

  @Test func throttleCoalescesMessageNotifications() async throws {
    let state = ObservableChatState(throttle: .milliseconds(30))
    let changes = LockedValues<Int>()
    func track() {
      withObservationTracking { _ = state.messages } onChange: { changes.append(1) }
    }
    track()
    state.messages = [userMessage]
    state.messages = [userMessage, userMessage]
    #expect(changes.values.isEmpty)
    #expect(state.messages.count == 2)
    try await Task.sleep(for: .milliseconds(80))
    #expect(changes.values.count == 1)

    track()
    state.messages = []
    state.status = .ready
    #expect(changes.values.count == 2)
  }

  @Test func completionStreamsIntoObservableState() async throws {
    let http = MockHTTPClient([api.absoluteString: .streamChunks(["Hel", "lo"])])
    let finished = LockedValues<String>()
    let completion = Completion(
      api: api, streamProtocol: .text, httpClient: http, onFinish: { prompt, text in finished.append("\(prompt)=\(text)") })
    completion.input = "Say hi"
    let result = await completion.submit()
    #expect(result == "Hello")
    #expect(completion.completion == "Hello")
    #expect(completion.isLoading == false)
    #expect(finished.values == ["Say hi=Hello"])
  }

  @Test func completionReportsErrors() async throws {
    let http = MockHTTPClient([api.absoluteString: .error(statusCode: 500, body: "down")])
    let completion = Completion(api: api, httpClient: http)
    let result = await completion.complete("x")
    #expect(result == nil)
    #expect((completion.error as? APICallError)?.statusCode == 500)
    #expect(completion.isLoading == false)
  }
}

/// Returns the same stream for the first request.
final class SingleStreamTransport: ChatTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var stream: AsyncThrowingStream<UIMessageChunk, any Error>?

  init(stream: AsyncThrowingStream<UIMessageChunk, any Error>) {
    self.stream = stream
  }

  func sendMessages(_ request: ChatSendMessagesRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error> {
    guard let stream = lock.withLock({ () -> AsyncThrowingStream<UIMessageChunk, any Error>? in
      defer { self.stream = nil }
      return self.stream
    }) else { throw TestFailure(description: "no stream") }
    return stream
  }

  func reconnectToStream(_ request: ChatReconnectRequest) async throws -> AsyncThrowingStream<UIMessageChunk, any Error>? {
    nil
  }
}
