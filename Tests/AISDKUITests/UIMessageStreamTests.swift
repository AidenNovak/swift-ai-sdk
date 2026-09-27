import AISDK
import AISDKTestUtils
import Foundation
import Testing

@Suite struct UIMessageStreamTests {
  let textChunks: [UIMessageChunk] = [
    .start(messageId: "m1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Hé"),
    .textDelta(id: "t", delta: "llo"), .textEnd(id: "t"), .finishStep, .finish(finishReason: .stop),
  ]

  @Test func encodesServerSentEventsAndParsesThemBack() async throws {
    let events = try await collect(uiMessageStreamToSSE(streamFromArray(textChunks)))
    #expect(events.first?.hasPrefix("data: {") == true)
    #expect(events.allSatisfy { $0.hasSuffix("\n\n") })
    #expect(events.last == "data: [DONE]\n\n")

    let body = streamFromArray(events.map { Data($0.utf8) })
    let parsed = try await collect(parseUIMessageStream(body))
    #expect(parsed == textChunks)
  }

  @Test func responseCarriesProtocolHeadersWithoutOverridingCustomOnes() async throws {
    let response = createUIMessageStreamResponse(
      status: 201, headers: ["Cache-Control": "no-store", "x-custom": "1"], stream: streamFromArray(textChunks))
    #expect(response.statusCode == 201)
    #expect(response.headers["x-vercel-ai-ui-message-stream"] == "v1")
    #expect(response.headers["content-type"] == "text/event-stream")
    #expect(response.headers["cache-control"] == "no-store")
    #expect(response.headers["x-custom"] == "1")
    let text = try await response.bodyText()
    #expect(text.hasSuffix("data: [DONE]\n\n"))
  }

  @Test func consumeSSEStreamReceivesACopy() async throws {
    let copy = AsyncStream<[String]>.makeStream()
    let response = createUIMessageStreamResponse(stream: streamFromArray(textChunks)) { stream in
      copy.continuation.yield((try? await collect(stream)) ?? [])
      copy.continuation.finish()
    }
    let body = try await response.bodyText()
    var iterator = copy.stream.makeAsyncIterator()
    let copied = await iterator.next() ?? []
    #expect(copied.joined() == body)
  }

  @Test func invalidEventFailsTheStream() async throws {
    let body = streamFromArray([Data("data: {\"type\":\"text-delta\"}\n\n".utf8)])
    await #expect(throws: (any Error).self) {
      _ = try await collect(parseUIMessageStream(body))
    }
  }

  @Test func textStreamBecomesOneTextPart() async throws {
    let chunks = try await collect(transformTextToUIMessageStream(streamFromArray(["Hel", "lo"])))
    #expect(
      chunks == [
        .start(), .startStep, .textStart(id: "text-1"), .textDelta(id: "text-1", delta: "Hel"),
        .textDelta(id: "text-1", delta: "lo"), .textEnd(id: "text-1"), .finishStep, .finish(),
      ])
  }

  @Test func utf8DecodingKeepsSplitCharactersIntact() async throws {
    let bytes = Array("你好, 🌍!".utf8)
    let pieces = [Data(bytes[0..<2]), Data(bytes[2..<4]), Data(bytes[4..<10]), Data(bytes[10...])]
    let text = try await collect(decodeUTF8Stream(streamFromArray(pieces))).joined()
    #expect(text == "你好, 🌍!")
  }

  @Test func readUIMessageStreamYieldsSnapshots() async throws {
    let snapshots = try await collect(readUIMessageStream(stream: streamFromArray(textChunks)))
    #expect(snapshots.map(\.text) == ["", "", "Hé", "Héllo", "Héllo"])
    #expect(snapshots.last?.id == "m1")
  }

  @Test func readUIMessageStreamTerminatesOnError() async throws {
    let chunks: [UIMessageChunk] = [.textStart(id: "t"), .error(errorText: "boom"), .textDelta(id: "t", delta: "x")]
    let errors = LockedValues<String>()
    let stream = readUIMessageStream(
      stream: streamFromArray(chunks), onError: { errors.append("\($0)") }, terminateOnError: true)
    await #expect(throws: UIMessageStreamError.self) {
      _ = try await collect(stream)
    }
    #expect(errors.values.count == 1)
  }

  @Test func customOnErrorShapesToolErrors() async throws {
    let failing = Tool(inputSchema: jsonSchema(["type": "object"]), execute: { _, _ in throw TestFailure(description: "secret") })
    let model = MockLanguageModelV4(
      doStream: .parts([
        .toolCall(LanguageModelV4ToolCall(toolCallId: "c1", toolName: "failing", input: "{}")),
        .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .toolCalls)),
      ]))
    let tools: ToolSet = ["failing": failing]
    let result = streamText(model: model, prompt: "p", tools: tools)
    var options = UIMessageStreamOptions()
    options.onError = { error in "redacted \(error)" }
    let chunks = try await collect(result.toUIMessageStream(tools: tools, options: options))
    #expect(chunks.contains(.toolOutputError(UIToolOutputErrorChunk(toolCallId: "c1", errorText: "redacted secret"))))
  }

  @Test func cancellingTheConsumerReportsCancellation() async throws {
    let (source, continuation) = AsyncThrowingStream<UIMessageChunk, any Error>.makeStream()
    continuation.yield(.start())
    let ended = AsyncStream<UIMessageStreamEndEvent>.makeStream()
    let stream = handleUIMessageStreamFinish(source, messageId: "m", onEnd: { event in
      ended.continuation.yield(event)
    })
    let task = Task { try await collect(stream) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    var iterator = ended.stream.makeAsyncIterator()
    let event = await iterator.next()
    #expect(event?.isCancelled == true)
    #expect(event?.responseMessage.id == "m")
    continuation.finish()
  }

  @Test func uiMessagesRoundTripThroughCodable() throws {
    let message = UIMessage(
      id: "a", role: .assistant, metadata: ["createdAt": 1],
      parts: [
        .stepStart, .text(TextUIPart(text: "Hi", state: .done)),
        .tool(
          ToolUIPart(
            toolName: "weather", toolCallId: "c", state: .outputAvailable, input: ["city": "Paris"],
            output: ["temperature": 20])),
        .data(DataUIPart(name: "status", id: "s", data: "ok")),
        .file(FileUIPart(data: Data([1, 2, 3]), mediaType: "application/octet-stream", filename: "x.bin")),
      ])
    let data = try JSONEncoder().encode([message])
    let decoded = try JSONDecoder().decode([UIMessage].self, from: data)
    #expect(decoded == [message])
    #expect(message.toolParts.first?.type == "tool-weather")
  }
}

final class LockedValues<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Value] = []

  func append(_ value: Value) { lock.withLock { stored.append(value) } }
  var values: [Value] { lock.withLock { stored } }
}
