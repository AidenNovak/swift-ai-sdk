import AISDKTestUtils
import Foundation
import Testing

@testable import AISDK

@Suite struct ToolLoopAgentTests {
  @Test func loopsUntilModelStopsCallingTools() async throws {
    let model = MockLanguageModelV4(
      doGenerate: .sequence([
        toolCallResult([("c1", "tool1", #"{"value":"a"}"#)]),
        toolCallResult([("c2", "tool1", #"{"value":"b"}"#)]),
        .mockText("done"),
      ]))
    let agent = ToolLoopAgent(
      id: "worker", model: model, instructions: "Be helpful.",
      tools: ["tool1": tool(inputSchema: valueSchema) { input, _ in input.value }])

    let result = try await agent.generate(prompt: "go")
    #expect(agent.id == "worker")
    #expect(result.steps.count == 3)
    #expect(result.text == "done")
    #expect(model.doGenerateCalls[0].prompt.first == .system("Be helpful."))
    #expect(model.doGenerateCalls[0].headers?["user-agent"]?.contains("ai-sdk-agent/tool-loop") == true)
  }

  @Test func defaultStopConditionIsTwentySteps() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("c", "tool1", #"{"value":"x"}"#)])))
    let agent = ToolLoopAgent(model: model, tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "again" }])
    let result = try await agent.generate(prompt: "loop forever")
    #expect(result.steps.count == 20)
  }

  @Test func mergesAgentAndCallCallbacks() async throws {
    let events = Recorder<String>()
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("hi")))
    let agent = ToolLoopAgent(
      model: model,
      onStepFinish: { _ in events.append("agent-step") },
      onFinish: { _ in events.append("agent-finish") })
    _ = try await agent.generate(
      prompt: "p",
      onStepFinish: { _ in events.append("call-step") },
      onFinish: { _ in events.append("call-finish") })
    #expect(events.values == ["agent-step", "call-step", "agent-finish", "call-finish"])
  }

  @Test func prepareCallUsesValidatedOptions() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("ok")))
    let otherModel = MockLanguageModelV4(modelId: "big", doGenerate: .result(.mockText("from big")))
    let agent = ToolLoopAgent(
      model: model,
      prepareCall: { call in
        var call = call
        if call.options?["tier"] == "premium" {
          call.model = otherModel
          call.instructions = "Premium user."
        }
        return call
      },
      callOptionsSchema: jsonSchema(["type": "object"]) { value in
        guard value["tier"]?.stringValue != nil else {
          throw InvalidArgumentError(argument: "tier", message: "tier is required")
        }
        return value
      })

    let premium = try await agent.generate(prompt: "p", options: ["tier": "premium"])
    #expect(premium.text == "from big")
    #expect(otherModel.doGenerateCalls[0].prompt.first == .system("Premium user."))

    await #expect(throws: TypeValidationError.self) {
      _ = try await agent.generate(prompt: "p", options: ["other": 1])
    }
  }

  @Test func structuredOutputAgent() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText(#"{"name":"Ann","age":3}"#)))
    let agent = ToolLoopAgent(model: model, output: .object(schema: personSchema))
    let result = try await agent.generate(prompt: "p")
    #expect(try result.output == Person(name: "Ann", age: 3))
  }

  @Test func streamsThroughAgent() async throws {
    let model = MockLanguageModelV4(
      doStream: .sequence([
        [
          .streamStart(warnings: []),
          .toolCall(LanguageModelV4ToolCall(toolCallId: "c", toolName: "tool1", input: #"{"value":"v"}"#)),
          .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .toolCalls)),
        ],
        [
          .streamStart(warnings: []), .textStart(id: "1"), .textDelta(id: "1", delta: "fin"), .textEnd(id: "1"),
          .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .stop)),
        ],
      ]))
    let agent = ToolLoopAgent(model: model, tools: ["tool1": tool(inputSchema: valueSchema) { _, _ in "r" }])
    let result = try await agent.stream(prompt: "p")
    #expect(try await result.text == "fin")
    #expect(try await result.steps.count == 2)
  }

  @Test func worksThroughTheAgentProtocol() async throws {
    func run<A: Agent>(_ agent: A) async throws -> A.OutputValue {
      try await agent.generate(prompt: "p", options: nil).output
    }
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("generic")))
    #expect(try await run(ToolLoopAgent(model: model)) == "generic")
  }
}
