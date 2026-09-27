@testable import AISDK
import AISDKTestUtils
import Foundation
import Testing

@Suite struct GenerateTextBasicTests {
  @Test func returnsTextUsageAndResponse() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("Hello, world!")))
    let result = try await generateText(model: model, prompt: "prompt")

    #expect(result.text == "Hello, world!")
    #expect(result.finishReason == .stop)
    #expect(result.usage.inputTokens == 3)
    #expect(result.usage.outputTokens == 10)
    #expect(result.usage.totalTokens == 13)
    #expect(result.response.id == "id-0")
    #expect(result.response.modelId == "mock-model-id")
    #expect(result.steps.count == 1)
    #expect(result.responseMessages == [.assistant("Hello, world!")])
  }

  @Test func sendsInstructionsPromptAndUserAgent() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    _ = try await generateText(
      model: model, instructions: "You are terse.", prompt: "hi", temperature: 0.5, headers: ["X-Custom": "1"])

    let call = try #require(model.doGenerateCalls.first)
    #expect(
      call.prompt == [
        .system("You are terse."),
        .user([.text(LanguageModelV4TextPart(text: "hi"))]),
      ])
    #expect(call.temperature == 0.5)
    #expect(call.toolChoice == .auto)
    #expect(call.tools == nil)
    #expect(call.headers?["x-custom"] == "1")
    #expect(call.headers?["user-agent"] == "ai/\(AISDK_VERSION)")
  }

  @Test func rejectsSystemMessagesInPromptByDefault() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    await #expect(throws: InvalidPromptError.self) {
      _ = try await generateText(model: model, prompt: .messages([.system("s"), .user("u")]))
    }
    _ = try await generateText(model: model, prompt: .messages([.system("s"), .user("u")]), allowSystemInMessages: true)
  }

  @Test func rejectsEmptyMessages() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    await #expect(throws: InvalidPromptError.self) {
      _ = try await generateText(model: model, prompt: .messages([]))
    }
  }

  @Test func exposesReasoningSourcesAndWarnings() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .result(
        LanguageModelV4GenerateResult(
          content: [
            .reasoning(LanguageModelV4Reasoning(text: "thinking")),
            .text(LanguageModelV4Text(text: "answer")),
            .source(.url(id: "s1", url: "https://example.com", title: "Example")),
          ],
          finishReason: LanguageModelV4FinishReason(unified: .stop),
          usage: .mock,
          warnings: [.unsupported(feature: "temperature")])))
    let result = try await generateText(model: model, prompt: "p")
    #expect(result.reasoningText == "thinking")
    #expect(result.text == "answer")
    #expect(result.sources == [.url(id: "s1", url: "https://example.com", title: "Example")])
    #expect(result.warnings == [.unsupported(feature: "temperature")])
    #expect(
      result.responseMessages == [
        .assistant([.reasoning(ReasoningPart(text: "thinking")), .text(TextPart(text: "answer"))])
      ])
  }

  @Test func rejectsInvalidSettings() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    await #expect(throws: InvalidArgumentError.self) {
      _ = try await generateText(model: model, prompt: "p", maxOutputTokens: 0)
    }
  }
}

@Suite struct GenerateTextToolTests {
  @Test func runsTwoStepToolLoop() async throws {
    let toolMessages = Recorder<[ModelMessage]>()
    let steps = Recorder<Int>()
    let model = MockLanguageModelV4(
      doGenerate: .sequence([
        toolCallResult([("call-1", "tool1", #"{ "value": "value" }"#)]),
        .mockText("Hello, world!"),
      ]))

    let result = try await generateText(
      model: model,
      prompt: "test-input",
      tools: [
        "tool1": tool(title: "Tool One", inputSchema: valueSchema) { input, options in
          toolMessages.append(options.messages)
          return "result-\(input.value)"
        }
      ],
      stopWhen: [.isStepCount(3)],
      onStepFinish: { steps.append($0.stepNumber) })

    #expect(result.text == "Hello, world!")
    #expect(result.steps.count == 2)
    #expect(steps.values == [0, 1])
    #expect(result.toolCalls.map(\.toolCallId) == ["call-1"])
    #expect(result.toolResults.map(\.output) == ["result-value"])
    #expect(result.finalStep.toolCalls.isEmpty)
    #expect(result.totalUsage.inputTokens == 6)
    #expect(toolMessages.values == [[.user("test-input")]])

    let firstCall = model.doGenerateCalls[0]
    #expect(
      firstCall.tools == [
        .function(LanguageModelV4FunctionTool(name: "tool1", inputSchema: valueSchema.jsonSchema))
      ])

    let expectedResponse: [ModelMessage] = [
      .assistant([.toolCall(ToolCallPart(toolCallId: "call-1", toolName: "tool1", input: ["value": "value"]))]),
      .tool([.toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("result-value")))]),
      .assistant("Hello, world!"),
    ]
    #expect(result.responseMessages == expectedResponse)

    let secondPrompt = model.doGenerateCalls[1].prompt
    #expect(secondPrompt.count == 3)
    #expect(
      secondPrompt[2]
        == .tool([
          .toolResult(
            LanguageModelV4ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("result-value")))
        ]))
  }

  @Test func stopsAfterOneStepByDefault() async throws {
    let executions = Recorder<String>()
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p",
      tools: [
        "tool1": tool(inputSchema: valueSchema) { input, _ in
          executions.append(input.value)
          return ["ok": true] as JSONValue
        }
      ])
    #expect(model.doGenerateCalls.count == 1)
    #expect(executions.values == ["v"])
    #expect(result.toolResults.first?.output == ["ok": true])
    #expect(result.finishReason == .toolCalls)
  }

  @Test func toolsWithoutExecuteEndTheLoop() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "client", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["client": tool(inputSchema: valueSchema)], stopWhen: [.isStepCount(5)])
    #expect(model.doGenerateCalls.count == 1)
    #expect(result.toolCalls.count == 1)
    #expect(result.toolResults.isEmpty)
  }

  @Test func enforcesRequiredToolChoice() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("no tools")))
    await #expect {
      _ = try await generateText(
        model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema)], toolChoice: .required)
    } throws: { error in
      (error as? ToolChoiceViolationError)?.message
        == "Model response did not contain a tool call even though tool choice was required."
    }
    await #expect(throws: ToolChoiceViolationError.self) {
      _ = try await generateText(
        model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema)], toolChoice: .tool("tool1"))
    }
  }

  @Test func invalidToolCallsBecomeDynamicErrors() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .sequence([
        toolCallResult([("call-1", "unknownTool", #"{"value":"v"}"#)]),
        .mockText("recovered"),
      ]))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "x" }],
      stopWhen: [.isStepCount(3)])

    let firstStep = result.steps[0]
    let call = try #require(firstStep.toolCalls.first)
    #expect(call.invalid)
    #expect(call.dynamic)
    #expect(call.error is NoSuchToolError)
    #expect(firstStep.toolErrors.count == 1)
    #expect(result.text == "recovered")

    guard case .tool(let toolMessage) = firstStep.response.messages.last,
      case .toolResult(let part) = toolMessage.content.first
    else {
      Issue.record("expected tool message")
      return
    }
    #expect(
      part.output
        == .errorText("AI_NoSuchToolError: Model tried to call unavailable tool 'unknownTool'. Available tools: tool1."))
  }

  @Test func invalidInputIsReportedAndRepaired() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value": 1}"#)])))

    let unrepaired = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "x" }])
    #expect(unrepaired.toolCalls.first?.error is InvalidToolInputError)

    let repaired = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { input, _ in input.value }],
      repairToolCall: { options in
        var call = options.toolCall
        call.input = #"{"value":"fixed"}"#
        #expect(options.error is InvalidToolInputError)
        #expect(options.inputSchema(toolName: "tool1") == valueSchema.jsonSchema)
        return call
      })
    #expect(repaired.toolCalls.first?.invalid == false)
    #expect(repaired.toolResults.first?.output == "fixed")
  }

  @Test func toolExecutionErrorsBecomeToolErrors() async throws {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p",
      tools: ["tool1": tool(inputSchema: valueSchema) { (_, _) async throws -> String in throw Boom() }])

    #expect(result.steps[0].toolErrors.first?.error is Boom)
    #expect(
      result.responseMessages.last
        == .tool([.toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .errorText("boom")))]))
  }

  @Test func activeToolsAndToolOrderShapeTheToolList() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    let tools: ToolSet = [
      "b": tool(inputSchema: valueSchema),
      "a": tool(inputSchema: valueSchema),
      "c": tool(inputSchema: valueSchema),
    ]
    _ = try await generateText(model: model, prompt: "p", tools: tools, activeTools: ["c", "a"])
    #expect(model.doGenerateCalls[0].tools?.map(\.name) == ["a", "c"])

    _ = try await generateText(model: model, prompt: "p", tools: tools, toolOrder: ["c"])
    #expect(model.doGenerateCalls[1].tools?.map(\.name) == ["c", "a", "b"])

    _ = try await generateText(model: model, prompt: "p", tools: tools)
    #expect(model.doGenerateCalls[2].tools?.map(\.name) == ["b", "a", "c"])
  }

  @Test func dynamicToolsReceiveRawJSON() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "mcpTool", #"{"q":"x"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p",
      tools: ["mcpTool": dynamicTool(inputSchema: ["type": "object"]) { input, _ in ["echo": input] }])
    #expect(result.dynamicToolCalls.count == 1)
    #expect(result.dynamicToolResults.first?.output == ["echo": ["q": "x"]])
  }

  @Test func toModelOutputCustomizesToolMessage() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)])))
    var customTool = tool(inputSchema: valueSchema) { _, _ in ["big": "payload"] as JSONValue }
    customTool.toModelOutput = { _ in .text("summary") }
    let result = try await generateText(model: model, prompt: "p", tools: ["tool1": customTool])
    #expect(
      result.responseMessages.last
        == .tool([.toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("summary")))]))
  }

  @Test func prepareStepOverridesPerStep() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .sequence([toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)]), .mockText("done")]))
    let otherModel = MockLanguageModelV4(modelId: "other", doGenerate: .result(.mockText("from other")))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "r" }],
      stopWhen: [.isStepCount(2)],
      prepareStep: { options in
        if options.stepNumber == 0 {
          return PrepareStepResult(toolChoice: .tool("tool1"), temperature: 0.1)
        }
        #expect(options.responseMessages.count == 2)
        return PrepareStepResult(model: otherModel, activeTools: [])
      })

    #expect(model.doGenerateCalls.count == 1)
    #expect(model.doGenerateCalls[0].toolChoice == .tool(toolName: "tool1"))
    #expect(model.doGenerateCalls[0].temperature == 0.1)
    #expect(otherModel.doGenerateCalls.count == 1)
    #expect(otherModel.doGenerateCalls[0].tools == nil)
    #expect(result.text == "from other")
    #expect(result.steps[1].modelId == "other")
  }

  @Test func hasToolCallStopCondition() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "finish", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["finish": tool(inputSchema: valueSchema) { _, _ in "done" }],
      stopWhen: [.hasToolCall("finish"), .isStepCount(10)])
    #expect(result.steps.count == 1)
  }
}

@Suite struct GenerateTextApprovalTests {
  @Test func userApprovalStopsBeforeExecution() async throws {
    let executions = Recorder<String>()
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p",
      tools: [
        "tool1": tool(inputSchema: valueSchema, needsApproval: true) { input, _ in
          executions.append(input.value)
          return "r"
        }
      ],
      stopWhen: [.isStepCount(5)], generateId: fixedIds)

    #expect(executions.values.isEmpty)
    #expect(model.doGenerateCalls.count == 1)
    #expect(result.finalStep.toolApprovalRequests.map(\.approvalId) == ["test-id"])
    #expect(
      result.responseMessages == [
        .assistant([
          .toolCall(ToolCallPart(toolCallId: "call-1", toolName: "tool1", input: ["value": "v"])),
          .toolApprovalRequest(ToolApprovalRequest(approvalId: "test-id", toolCallId: "call-1")),
        ])
      ])
  }

  @Test func approvedCallIsExecutedOnNextRequest() async throws {
    let executions = Recorder<String>()
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("done")))
    let messages: [ModelMessage] = [
      .user("p"),
      .assistant([
        .toolCall(ToolCallPart(toolCallId: "call-1", toolName: "tool1", input: ["value": "v"])),
        .toolApprovalRequest(ToolApprovalRequest(approvalId: "a1", toolCallId: "call-1")),
      ]),
      .tool([.toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: true))]),
    ]
    let result = try await generateText(
      model: model, prompt: .messages(messages),
      tools: [
        "tool1": tool(inputSchema: valueSchema, needsApproval: true) { input, _ in
          executions.append(input.value)
          return "approved-result"
        }
      ])

    #expect(executions.values == ["v"])
    #expect(
      result.responseMessages.first
        == .tool([
          .toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("approved-result")))
        ]))
    let prompt = model.doGenerateCalls[0].prompt
    guard case .tool(let content, _) = prompt.last else {
      Issue.record("expected tool message last")
      return
    }
    #expect(
      content == [
        .toolResult(
          LanguageModelV4ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .text("approved-result")))
      ])
  }

  @Test func deniedCallProducesExecutionDenied() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    let messages: [ModelMessage] = [
      .user("p"),
      .assistant([
        .toolCall(ToolCallPart(toolCallId: "call-1", toolName: "tool1", input: ["value": "v"])),
        .toolApprovalRequest(ToolApprovalRequest(approvalId: "a1", toolCallId: "call-1")),
      ]),
      .tool([.toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: false, reason: "no"))]),
    ]
    let result = try await generateText(
      model: model, prompt: .messages(messages),
      tools: ["tool1": tool(inputSchema: valueSchema, needsApproval: true) { _, _ in "r" }])
    #expect(
      result.responseMessages.first
        == .tool([
          .toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .executionDenied(reason: "no")))
        ]))
  }

  @Test func unknownApprovalIdThrows() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    await #expect(throws: InvalidToolApprovalError.self) {
      _ = try await generateText(
        model: model,
        prompt: .messages([
          .user("p"), .tool([.toolApprovalResponse(ToolApprovalResponse(approvalId: "missing", approved: true))]),
        ]))
    }
  }

  @Test func automaticDenialContinuesLoop() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .sequence([toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)]), .mockText("after denial")]))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "r" }],
      stopWhen: [.isStepCount(3)],
      toolApproval: .perTool(["tool1": { _, _ in .denied(reason: "policy") }]),
      generateId: fixedIds)

    #expect(result.text == "after denial")
    #expect(result.steps[0].toolResults.isEmpty)
    guard case .tool(let toolMessage)? = result.steps[0].response.messages.last else {
      Issue.record("expected tool message")
      return
    }
    #expect(
      toolMessage.content == [
        .toolApprovalResponse(ToolApprovalResponse(approvalId: "test-id", approved: false, reason: "policy")),
        .toolResult(ToolResultPart(toolCallId: "call-1", toolName: "tool1", output: .executionDenied(reason: "policy"))),
      ])
  }

  @Test func automaticApprovalExecutes() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("call-1", "tool1", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema, needsApproval: true) { _, _ in "ran" }],
      toolApproval: .generic { _ in .approved() })
    #expect(result.toolResults.first?.output == "ran")
    #expect(result.finalStep.toolApprovalRequests.isEmpty)
  }
}

@Suite struct GenerateTextRetryTests {
  actor Attempts {
    var count = 0
    func next() -> Int {
      count += 1
      return count
    }
  }

  @Test func retriesRetryableErrors() async throws {
    let attempts = Attempts()
    let model = MockLanguageModelV4(
      doGenerate: .handler { _ in
        if await attempts.next() == 1 {
          throw APICallError(
            message: "overloaded", url: "u", requestBodyValues: nil, statusCode: 529,
            responseHeaders: ["retry-after-ms": "0"])
        }
        return .mockText("ok")
      })
    let result = try await generateText(model: model, prompt: "p")
    #expect(result.text == "ok")
    #expect(await attempts.count == 2)
  }

  @Test func doesNotRetryNonRetryableErrors() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .handler { _ in
        throw APICallError(message: "bad request", url: "u", requestBodyValues: nil, statusCode: 400)
      })
    await #expect(throws: APICallError.self) { _ = try await generateText(model: model, prompt: "p") }
  }

  @Test func wrapsExhaustedRetries() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .handler { _ in
        throw APICallError(
          message: "down", url: "u", requestBodyValues: nil, statusCode: 503,
          responseHeaders: ["retry-after-ms": "0"])
      })
    await #expect {
      _ = try await generateText(model: model, prompt: "p", maxRetries: 1)
    } throws: { error in
      let error = error as? RetryError
      return error?.reason == .maxRetriesExceeded && error?.errors.count == 2
    }
  }

  @Test func retryDelayHonorsHeaders() {
    let error = APICallError(
      message: "", url: "", requestBodyValues: nil, statusCode: 429, responseHeaders: ["retry-after": "3"])
    #expect(retryDelayInMs(error: error, exponentialBackoffDelay: 2000) == 3000)
    let tooLong = APICallError(
      message: "", url: "", requestBodyValues: nil, statusCode: 429, responseHeaders: ["retry-after": "120"])
    #expect(retryDelayInMs(error: tooLong, exponentialBackoffDelay: 2000) == 2000)
  }
}
