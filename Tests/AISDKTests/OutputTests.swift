import AISDKTestUtils
import Foundation
import Testing

@testable import AISDK

struct Person: Codable, Sendable, Equatable {
  var name: String
  var age: Int
}

let personSchema = Schema(
  Person.self,
  jsonSchema: [
    "type": "object", "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
    "required": ["name", "age"], "additionalProperties": false,
  ])

private let context = OutputContext(
  response: LanguageModelResponseMetadata(id: "r", timestamp: Date(timeIntervalSince1970: 0), modelId: "m"),
  usage: LanguageModelUsage(), finishReason: .stop)

private func streamParts(_ deltas: [String]) -> [LanguageModelV4StreamPart] {
  [.streamStart(warnings: []), .textStart(id: "1")] + deltas.map { .textDelta(id: "1", delta: $0) } + [
    .textEnd(id: "1"), .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .stop)),
  ]
}

@Suite struct OutputSpecificationTests {
  @Test func objectParsesAndValidates() throws {
    let output = Output.object(schema: personSchema, name: "person")
    #expect(output.responseFormat == .json(schema: personSchema.jsonSchema, name: "person"))
    #expect(try output.parseCompleteOutput(#"{"name":"Ann","age":3}"#, context: context) == Person(name: "Ann", age: 3))
    #expect(output.parsePartialOutput(#"{"name":"An"#) == ["name": "An"])
    #expect(output.parsePartialOutput("") == nil)

    #expect {
      _ = try output.parseCompleteOutput("not json", context: context)
    } throws: { error in
      (error as? NoObjectGeneratedError)?.message == "No object generated: could not parse the response."
    }
    #expect {
      _ = try output.parseCompleteOutput(#"{"name":"Ann"}"#, context: context)
    } throws: { error in
      let error = error as? NoObjectGeneratedError
      return error?.message == "No object generated: response did not match schema." && error?.text == #"{"name":"Ann"}"#
        && error?.finishReason == .stop
    }
  }

  @Test func arrayWrapsElementsAndStreamsCompleteOnes() throws {
    let output = try Output.array(element: personSchema, maxItems: 3)
    guard case .json(let schema?, _, _) = output.responseFormat else {
      Issue.record("expected schema")
      return
    }
    #expect(schema.value["properties"]?["elements"]?["type"] == "array")
    #expect(schema.value["properties"]?["elements"]?["maxItems"] == 3)
    #expect(schema.value["required"] == ["elements"])

    let text = #"{"elements":[{"name":"A","age":1},{"name":"B","age":2}]}"#
    #expect(try output.parseCompleteOutput(text, context: context).map(\.name) == ["A", "B"])
    let partial = output.parsePartialOutput(#"{"elements":[{"name":"A","age":1},{"name":"B","age""#)
    #expect(partial?.elements.map(\.name) == ["A"])

    #expect(throws: NoObjectGeneratedError.self) {
      try output.parseCompleteOutput(#"{"elements":[{"name":"A","age":1},{"name":"A","age":1},{"name":"A","age":1},{"name":"A","age":1}]}"#, context: context)
    }
    #expect(throws: InvalidArgumentError.self) { try Output.array(element: personSchema, minItems: 3, maxItems: 1) }
  }

  @Test func choiceMatchesOptions() throws {
    let output = Output.choice(["sunny", "rainy", "snowy"])
    #expect(try output.parseCompleteOutput(#"{"result":"rainy"}"#, context: context) == "rainy")
    #expect(throws: NoObjectGeneratedError.self) {
      try output.parseCompleteOutput(#"{"result":"cloudy"}"#, context: context)
    }
    #expect(output.parsePartialOutput(#"{"result":"su"#) == "sunny")
    #expect(output.parsePartialOutput(#"{"result":"s"#) == nil)
  }

  @Test func jsonAcceptsAnyValue() throws {
    let output = Output.json()
    #expect(output.responseFormat == .json())
    #expect(try output.parseCompleteOutput("[1,2]", context: context) == [1, 2])
  }
}

@Suite struct GenerateTextOutputTests {
  @Test func sendsResponseFormatAndParsesOutput() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText(#"{"name":"Ann","age":3}"#)))
    let result = try await generateText(model: model, prompt: "p", output: .object(schema: personSchema))
    #expect(try result.output == Person(name: "Ann", age: 3))
    #expect(model.doGenerateCalls[0].responseFormat == .json(schema: personSchema.jsonSchema))
  }

  @Test func textOutputIsTheText() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("hello")))
    let result = try await generateText(model: model, prompt: "p")
    #expect(try result.output == "hello")
    #expect(model.doGenerateCalls[0].responseFormat == nil)
  }

  @Test func invalidObjectThrows() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("oops")))
    await #expect(throws: NoObjectGeneratedError.self) {
      _ = try await generateText(model: model, prompt: "p", output: .object(schema: personSchema))
    }
  }

  @Test func toolCallFinishHasNoOutput() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(toolCallResult([("c", "tool1", #"{"value":"v"}"#)])))
    let result = try await generateText(
      model: model, prompt: "p", tools: ["tool1": tool(inputSchema: valueSchema)], output: .object(schema: personSchema))
    #expect(throws: NoOutputGeneratedError.self) { try result.output }
  }
}

@Suite struct StreamTextOutputTests {
  @Test func streamsPartialObjects() async throws {
    let model = MockLanguageModelV4(doStream: .parts(streamParts([#"{"na"#, #"me":"An"#, #"n","age""#, #":3}"#])))
    let result = streamText(model: model, prompt: "p", output: .object(schema: personSchema))
    let partials = try await collect(result.partialOutputStream)
    #expect(partials.first == [:])
    #expect(partials.contains(["name": "An"]))
    #expect(partials.last == ["name": "Ann", "age": 3])
    #expect(try await result.output == Person(name: "Ann", age: 3))
  }

  @Test func streamsArrayElements() async throws {
    let model = MockLanguageModelV4(
      doStream: .parts(streamParts([#"{"elements":[{"name":"A","ag"#, #"e":1},{"name":"B","#, #""age":2}]}"#])))
    let result = streamText(model: model, prompt: "p", output: try .array(element: personSchema))
    #expect(try await collect(result.elementStream).map(\.name) == ["A", "B"])
    #expect(try await result.output.count == 2)
  }

  @Test func invalidOutputSurfacesParseError() async throws {
    let model = MockLanguageModelV4(doStream: .parts(streamParts(["nope"])))
    let result = streamText(model: model, prompt: "p", output: .object(schema: personSchema))
    await #expect(throws: NoObjectGeneratedError.self) { _ = try await result.output }
    #expect(try await result.text == "nope")
  }
}

@Suite struct GenerateObjectTests {
  @Test func generatesObject() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText(#"{"name":"Bob","age":41}"#)))
    let result = try await generateObject(model: model, schema: personSchema, schemaName: "person", prompt: "p")
    #expect(result.object == Person(name: "Bob", age: 41))
    #expect(result.finishReason == .stop)
    #expect(result.usage.totalTokens == 13)
    #expect(model.doGenerateCalls[0].responseFormat == .json(schema: personSchema.jsonSchema, name: "person"))
  }

  @Test func repairTextFixesInvalidOutput() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText(#"```json\n{"name":"Bob","age":41}\n```"#)))
    await #expect(throws: NoObjectGeneratedError.self) {
      _ = try await generateObject(model: model, schema: personSchema, prompt: "p")
    }
    let repaired = try await generateObject(
      model: model, schema: personSchema, prompt: "p",
      repairText: { text, _ in
        text.replacingOccurrences(of: "```json\\n", with: "").replacingOccurrences(of: "\\n```", with: "")
      })
    #expect(repaired.object.name == "Bob")
  }

  @Test func generatesEnumAndArray() async throws {
    let enumModel = MockLanguageModelV4(doGenerate: .result(.mockText(#"{"result":"rainy"}"#)))
    #expect(try await generateObject(model: enumModel, output: .choice(["sunny", "rainy"]), prompt: "p").object == "rainy")

    let arrayModel = MockLanguageModelV4(doGenerate: .result(.mockText(#"{"elements":[{"name":"A","age":1}]}"#)))
    #expect(try await generateObject(model: arrayModel, output: .array(element: personSchema), prompt: "p").object.count == 1)
  }

  @Test func streamObjectEmitsPartialsAndObject() async throws {
    let model = MockLanguageModelV4(doStream: .parts(streamParts([#"{"name":"Z"#, #"oe","age":7}"#])))
    let result = streamObject(model: model, schema: personSchema, prompt: "p")
    let partials = try await collect(result.partialObjectStream)
    #expect(partials.last == ["name": "Zoe", "age": 7])
    #expect(try await result.object == Person(name: "Zoe", age: 7))
    #expect(try await result.finishReason == .stop)
  }
}
