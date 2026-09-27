import AISDKTestUtils
import Foundation
import Testing

@testable import AISDK

private func textParts(_ deltas: [String], finishReason: LanguageModelV4FinishReason.Unified = .stop)
  -> [LanguageModelV4StreamPart]
{
  var parts: [LanguageModelV4StreamPart] = [
    .streamStart(warnings: []),
    .responseMetadata(
      LanguageModelV4ResponseMetadata(id: "id-0", timestamp: Date(timeIntervalSince1970: 0), modelId: "mock-model-id")),
    .textStart(id: "1"),
  ]
  parts += deltas.map { .textDelta(id: "1", delta: $0) }
  parts += [
    .textEnd(id: "1"),
    .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: finishReason, raw: finishReason.rawValue)),
  ]
  return parts
}

private func toolCallParts(id: String, name: String, input: String) -> [LanguageModelV4StreamPart] {
  [
    .streamStart(warnings: []),
    .toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: name)),
    .toolInputDelta(id: id, delta: input),
    .toolInputEnd(id: id),
    .toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: name, input: input)),
    .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .toolCalls)),
  ]
}

private func types(_ parts: [TextStreamPart]) -> [String] {
  parts.map(\.type)
}

@Suite struct StreamTextBasicTests {
  @Test func streamsTextAndResolvesResults() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["Hello", ", ", "world!"])))
    let result = streamText(model: model, prompt: "test-input")

    #expect(try await collect(result.textStream) == ["Hello", ", ", "world!"])
    #expect(try await result.text == "Hello, world!")
    #expect(try await result.finishReason == .stop)
    #expect(try await result.usage.totalTokens == 13)
    #expect(try await result.totalUsage.inputTokens == 3)
    #expect(try await result.response.id == "id-0")
    #expect(try await result.responseMessages == [.assistant("Hello, world!")])
    #expect(model.doStreamCalls.first?.prompt == [.user([.text(LanguageModelV4TextPart(text: "test-input"))])])
  }

  @Test func fullStreamHasUpstreamPartOrder() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["a", "b"])))
    let parts = try await collect(streamText(model: model, prompt: "p").fullStream)
    #expect(
      types(parts) == [
        "start", "start-step", "text-start", "text-delta", "text-delta", "text-end", "finish-step", "finish",
      ])
    guard case .finish(let reason, _, let totalUsage) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(reason == .stop)
    #expect(totalUsage.outputTokens == 10)
  }

  @Test func everyConsumerReplaysFromTheStart() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["x", "y"])))
    let result = streamText(model: model, prompt: "p")
    let first = try await collect(result.textStream)
    let second = try await collect(result.textStream)
    let full = try await collect(result.fullStream)
    #expect(first == ["x", "y"])
    #expect(second == first)
    #expect(full.count == 8)
  }

  @Test func forwardsWarningsInStartStep() async throws {
    var parts = textParts(["a"])
    parts[0] = .streamStart(warnings: [.unsupported(feature: "seed")])
    let model = MockLanguageModelV4(doStream: .parts(parts))
    let result = streamText(model: model, prompt: "p")
    let full = try await collect(result.fullStream)
    guard case .startStep(_, let warnings) = full[1] else {
      Issue.record("expected start-step")
      return
    }
    #expect(warnings == [.unsupported(feature: "seed")])
    #expect(try await result.warnings == [.unsupported(feature: "seed")])
  }

  @Test func recordsReasoningAndSources() async throws {
    let model = MockLanguageModelV4(
      doStream: .parts([
        .streamStart(warnings: []),
        .reasoningStart(id: "r"),
        .reasoningDelta(id: "r", delta: "think"),
        .reasoningDelta(id: "r", delta: "ing"),
        .reasoningEnd(id: "r"),
        .source(.url(id: "s", url: "https://example.com")),
        .textStart(id: "t"),
        .textDelta(id: "t", delta: "answer"),
        .textEnd(id: "t"),
        .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .stop)),
      ]))
    let result = streamText(model: model, prompt: "p")
    #expect(try await result.reasoningText == "thinking")
    #expect(try await result.text == "answer")
    #expect(try await result.sources.map(\.id) == ["s"])
    #expect(
      try await result.responseMessages == [
        .assistant([.reasoning(ReasoningPart(text: "thinking")), .text(TextPart(text: "answer"))])
      ])
  }

  @Test func includesRawChunksOnlyWhenRequested() async throws {
    var parts = textParts(["a"])
    parts.insert(.raw(rawValue: ["chunk": 1]), at: 1)
    let model = MockLanguageModelV4(doStream: .parts(parts))

    let without = try await collect(streamText(model: model, prompt: "p").fullStream)
    #expect(!types(without).contains("raw"))

    let with = try await collect(streamText(model: model, prompt: "p", includeRawChunks: true).fullStream)
    #expect(types(with).contains("raw"))
    #expect(model.doStreamCalls.last?.includeRawChunks == true)
  }
}

@Suite struct StreamTextToolTests {
  @Test func runsMultiStepToolLoop() async throws {
    let model = MockLanguageModelV4(
      doStream: .sequence([
        toolCallParts(id: "call-1", name: "tool1", input: #"{"value":"v"}"#),
        textParts(["done"]),
      ]))
    let steps = Recorder<Int>()
    let finished = Recorder<Int>()
    let result = streamText(
      model: model, prompt: "p",
      tools: ["tool1": tool(inputSchema: valueSchema) { input, _ in "result-\(input.value)" }],
      stopWhen: [.isStepCount(3)],
      onStepFinish: { steps.append($0.stepNumber) },
      onFinish: { finished.append($0.steps.count) })

    let parts = try await collect(result.fullStream)
    #expect(
      types(parts) == [
        "start",
        "start-step", "tool-input-start", "tool-input-delta", "tool-input-end", "tool-call", "tool-result",
        "finish-step",
        "start-step", "text-start", "text-delta", "text-end", "finish-step",
        "finish",
      ])
    #expect(try await result.text == "done")
    #expect(try await result.steps.count == 2)
    #expect(try await result.toolResults.map(\.output) == ["result-v"])
    #expect(try await result.totalUsage.inputTokens == 6)
    #expect(steps.values == [0, 1])
    #expect(finished.values == [2])

    let secondPrompt = model.doStreamCalls[1].prompt
    #expect(
      secondPrompt.last
        == .tool([
          .toolResult(LanguageModelV4ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("result-v")))
        ]))
  }

  @Test func toolInputStartCarriesToolMetadata() async throws {
    let model = MockLanguageModelV4(doStream: .parts(toolCallParts(id: "c", name: "mcp", input: "{}")))
    let result = streamText(
      model: model, prompt: "p",
      tools: ["mcp": dynamicTool(title: "MCP Tool", inputSchema: ["type": "object"], metadata: ["server": "files"])])
    let parts = try await collect(result.fullStream)
    let start = parts.compactMap { part -> ToolInputStart? in
      if case .toolInputStart(let start) = part { return start }
      return nil
    }.first
    #expect(start?.dynamic == true)
    #expect(start?.title == "MCP Tool")
    #expect(start?.toolMetadata == ["server": "files"])
  }

  @Test func toolErrorsAreStreamed() async throws {
    struct Boom: Error {}
    let model = MockLanguageModelV4(doStream: .parts(toolCallParts(id: "c", name: "tool1", input: #"{"value":"v"}"#)))
    let result = streamText(
      model: model, prompt: "p",
      tools: ["tool1": tool(inputSchema: valueSchema) { (_, _) async throws -> String in throw Boom() }])
    let parts = try await collect(result.fullStream)
    #expect(types(parts).contains("tool-error"))
    #expect(try await result.steps[0].toolErrors.first?.error is Boom)
  }

  @Test func invalidToolCallsBecomeToolErrors() async throws {
    let model = MockLanguageModelV4(doStream: .parts(toolCallParts(id: "c", name: "missing", input: "{}")))
    let result = streamText(model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema)])
    let parts = try await collect(result.fullStream)
    let call = parts.compactMap { part -> ToolCall? in
      if case .toolCall(let call) = part { return call }
      return nil
    }.first
    #expect(call?.invalid == true)
    #expect(types(parts).contains("tool-error"))
  }

  @Test func streamsPreliminaryToolResults() async throws {
    let model = MockLanguageModelV4(doStream: .parts(toolCallParts(id: "c", name: "progress", input: #"{"value":"v"}"#)))
    let result = streamText(
      model: model, prompt: "p",
      tools: [
        "progress": streamingTool(inputSchema: valueSchema) { _, _ in
          AsyncThrowingStream { continuation in
            continuation.yield("25%")
            continuation.yield("50%")
            continuation.yield("done")
            continuation.finish()
          }
        }
      ])
    let parts = try await collect(result.fullStream)
    let results = parts.compactMap { part -> ToolResult? in
      if case .toolResult(let result) = part { return result }
      return nil
    }
    #expect(results.map(\.output) == ["25%", "50%", "done"])
    #expect(results.map(\.preliminary) == [true, true, false])
    #expect(try await result.toolResults.map(\.output) == ["done"])
  }

  @Test func userApprovalStopsBeforeExecution() async throws {
    let executions = Recorder<String>()
    let model = MockLanguageModelV4(doStream: .parts(toolCallParts(id: "c", name: "tool1", input: #"{"value":"v"}"#)))
    let result = streamText(
      model: model, prompt: "p",
      tools: [
        "tool1": tool(inputSchema: valueSchema, needsApproval: true) { input, _ in
          executions.append(input.value)
          return "r"
        }
      ],
      stopWhen: [.isStepCount(5)], generateId: fixedIds)
    let parts = try await collect(result.fullStream)
    #expect(types(parts).contains("tool-approval-request"))
    #expect(executions.values.isEmpty)
    #expect(model.doStreamCalls.count == 1)
    #expect(try await result.finalStep.toolApprovalRequests.map(\.approvalId) == ["test-id"])
  }

  @Test func automaticDenialEmitsDeniedOutput() async throws {
    let model = MockLanguageModelV4(
      doStream: .sequence([toolCallParts(id: "c", name: "tool1", input: #"{"value":"v"}"#), textParts(["ok"])]))
    let result = streamText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "r" }],
      stopWhen: [.isStepCount(3)], toolApproval: .generic { _ in .denied(reason: "nope") })
    let parts = try await collect(result.fullStream)
    #expect(types(parts).contains("tool-output-denied"))
    #expect(try await result.text == "ok")
  }

  @Test func approvedCallFromMessagesRunsBeforeFirstStep() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["after"])))
    let result = streamText(
      model: model,
      prompt: .messages([
        .user("p"),
        .assistant([
          .toolCall(ToolCallPart(toolCallId: "c1", toolName: "tool1", input: ["value": "v"])),
          .toolApprovalRequest(ToolApprovalRequest(approvalId: "a1", toolCallId: "c1")),
        ]),
        .tool([.toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: true))]),
      ]),
      tools: ["tool1": tool(inputSchema: valueSchema, needsApproval: true) { _, _ in "ran" }])
    let parts = try await collect(result.fullStream)
    #expect(Array(types(parts).prefix(3)) == ["start", "tool-result", "start-step"])
    #expect(try await result.responseMessages.first == .tool([
      .toolResult(ToolResultPart(toolCallId: "c1", toolName: "tool1", output: .text("ran")))
    ]))
  }
}

@Suite struct StreamTextErrorTests {
  @Test func modelStreamErrorsAreForwardedAndReported() async throws {
    struct StreamFailure: Error {}
    let errors = Recorder<String>()
    var parts = textParts(["a"])
    parts.insert(.error(StreamFailure()), at: 3)
    let model = MockLanguageModelV4(doStream: .parts(parts))
    let result = streamText(model: model, prompt: "p", onError: { errors.append(String(describing: $0)) })
    let full = try await collect(result.fullStream)
    #expect(types(full).contains("error"))
    #expect(errors.values.count == 1)
    #expect(try await result.text == "a")
  }

  @Test func doStreamFailureYieldsErrorAndNoOutput() async throws {
    let model = MockLanguageModelV4(
      doStream: .handler { _ in
        throw APICallError(message: "bad", url: "u", requestBodyValues: nil, statusCode: 400)
      })
    let result = streamText(model: model, prompt: "p")
    let full = try await collect(result.fullStream)
    #expect(types(full) == ["start", "error"])
    await #expect {
      _ = try await result.text
    } throws: { error in
      (error as? NoOutputGeneratedError)?.cause is APICallError
    }
  }

  @Test func invalidPromptIsReportedAsError() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["a"])))
    let full = try await collect(streamText(model: model, prompt: .messages([])).fullStream)
    guard case .error(let error) = full.last else {
      Issue.record("expected error")
      return
    }
    #expect(error is InvalidPromptError)
  }

  @Test func cancelEmitsAbort() async throws {
    let aborted = Recorder<Int>()
    let model = MockLanguageModelV4(
      doStream: .handler { _ in
        LanguageModelV4StreamResult(
          stream: LanguageModelV4Stream { continuation in
            continuation.yield(.streamStart(warnings: []))
            continuation.yield(.textStart(id: "1"))
            continuation.yield(.textDelta(id: "1", delta: "partial"))
            let task = Task {
              try? await Task.sleep(nanoseconds: 5_000_000_000)
              continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
          })
      })
    let result = streamText(model: model, prompt: "p", onAbort: { aborted.append($0.count) })
    var seen: [TextStreamPart] = []
    for try await part in result.fullStream {
      seen.append(part)
      if case .textDelta = part { result.cancel() }
    }
    #expect(seen.last?.type == "abort")
    #expect(aborted.values == [0])
  }
}

@Suite struct StreamTextTransformTests {
  @Test func smoothStreamRechunksByWord() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["Hello wo", "rld, how ", "are you?"])))
    let result = streamText(model: model, prompt: "p", transform: [smoothStream(delayInMs: nil)])
    #expect(try await collect(result.textStream) == ["Hello ", "world, ", "how ", "are ", "you?"])
    #expect(try await result.text == "Hello world, how are you?")
  }

  @Test func smoothStreamByLine() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textParts(["line1\nli", "ne2\n", "tail"])))
    let result = streamText(model: model, prompt: "p", transform: [smoothStream(delayInMs: nil, chunking: .line)])
    #expect(try await collect(result.textStream) == ["line1\n", "line2\n", "tail"])
  }

  @Test func onChunkReceivesContentChunks() async throws {
    let chunks = Recorder<String>()
    let model = MockLanguageModelV4(doStream: .parts(textParts(["a", "b"])))
    let result = streamText(model: model, prompt: "p", onChunk: { chunks.append($0.type) })
    await result.consumeStream()
    #expect(chunks.values == ["text-delta", "text-delta"])
  }
}
