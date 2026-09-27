import AISDK
import AISDKAnthropic
import AISDKDeepSeek
import AISDKTestUtils
import Foundation
import Testing

struct LivePerson: Codable, Sendable, Equatable {
  var name: String
  var age: Int
}

let livePersonSchema = Schema(
  LivePerson.self,
  jsonSchema: [
    "type": "object", "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
    "required": ["name", "age"], "additionalProperties": false,
  ])

@Suite(.enabled(if: liveEnabled), .serialized) struct StructuredOutputLiveTests {
  @Test func generateObjectWithChatJsonMode() async throws {
    let result = try await generateObject(
      model: deepseek(flash), schema: livePersonSchema, prompt: "Extract the person: Carol is 29 years old.",
      maxOutputTokens: 300, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.object == LivePerson(name: "Carol", age: 29))
  }

  @Test func generateObjectWithResponsesJsonSchema() async throws {
    let result = try await generateObject(
      model: deepseek.responses(flash), schema: livePersonSchema, schemaName: "person",
      prompt: "Extract the person: Dan is 52 years old.", maxOutputTokens: 300,
      reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.object == LivePerson(name: "Dan", age: 52))
  }

  @Test func streamObjectEmitsPartials() async throws {
    let result = streamObject(
      model: deepseek(flash), schema: livePersonSchema, prompt: "Extract the person: Eve is 33 years old.",
      maxOutputTokens: 300, reasoning: LanguageModelV4ReasoningEffort.none)
    let partials = try await collect(result.partialObjectStream)
    #expect(!partials.isEmpty)
    #expect(try await result.object == LivePerson(name: "Eve", age: 33))
  }

  @Test func arrayOutputStreamsElements() async throws {
    let output = try Output.array(element: livePersonSchema)
    let result = streamText(
      model: deepseek(flash), prompt: "List three people: Ann (20), Ben (30), Cid (40).", output: output,
      maxOutputTokens: 500, reasoning: LanguageModelV4ReasoningEffort.none)
    let people: [LivePerson] = try await collect(result.elementStream)
    let names = people.map(\.name)
    #expect(names == ["Ann", "Ben", "Cid"])
  }

  @Test func choiceOutput() async throws {
    let result = try await generateText(
      model: deepseek(flash), prompt: "Is the sky usually blue on a clear day? Choose yes or no.",
      output: .choice(["yes", "no"]), maxOutputTokens: 100, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(try result.output == "yes")
  }

  @Test func objectOutputThroughAnthropicEndpoint() async throws {
    let anthropic = try createAnthropic(
      AnthropicProviderSettings(
        baseURL: "https://api.deepseek.com/anthropic/v1",
        apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]))
    let result = try await generateObject(
      model: anthropic(flash), schema: livePersonSchema, prompt: "Extract the person: Fay is 61 years old.",
      maxOutputTokens: 2000)
    #expect(result.object == LivePerson(name: "Fay", age: 61))
  }
}
