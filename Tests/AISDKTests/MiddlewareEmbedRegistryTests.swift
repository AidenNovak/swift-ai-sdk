import AISDKTestUtils
import Foundation
import Testing

@testable import AISDK

private func textStream(_ deltas: [String]) -> [LanguageModelV4StreamPart] {
  [.streamStart(warnings: []), .textStart(id: "1")] + deltas.map { .textDelta(id: "1", delta: $0) } + [
    .textEnd(id: "1"), .finish(usage: .mock, finishReason: LanguageModelV4FinishReason(unified: .stop)),
  ]
}

@Suite struct WrapLanguageModelTests {
  @Test func appliesMiddlewareOutermostFirst() async throws {
    let order = Recorder<String>()
    func tracing(_ name: String) -> LanguageModelMiddleware {
      LanguageModelMiddleware(
        transformParams: { _, params, _ in
          order.append("transform-\(name)")
          return params
        },
        wrapGenerate: { options in
          order.append("wrap-\(name)")
          return try await options.doGenerate()
        })
    }
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("hi")))
    let wrapped = wrapLanguageModel(model: model, middleware: [tracing("a"), tracing("b")], modelId: "custom")
    _ = try await generateText(model: wrapped, prompt: "p")
    #expect(order.values == ["transform-a", "wrap-a", "transform-b", "wrap-b"])
    #expect(wrapped.modelId == "custom")
    #expect(wrapped.provider == "mock-provider")
  }

  @Test func defaultSettingsAreOverriddenByCallSettings() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("hi")))
    let wrapped = wrapLanguageModel(
      model: model,
      middleware: defaultSettingsMiddleware(
        maxOutputTokens: 100, temperature: 0.3, providerOptions: ["deepseek": ["userId": "u1", "logprobs": true]]))
    _ = try await generateText(
      model: wrapped, prompt: "p", temperature: 0.9, providerOptions: ["deepseek": ["logprobs": false]])
    let call = try #require(model.doGenerateCalls.first)
    #expect(call.maxOutputTokens == 100)
    #expect(call.temperature == 0.9)
    #expect(call.providerOptions == ["deepseek": ["userId": "u1", "logprobs": false]])
  }

  @Test func extractsReasoningFromGeneratedText() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("<think>plan it</think>The answer.")))
    let wrapped = wrapLanguageModel(model: model, middleware: extractReasoningMiddleware(tagName: "think"))
    let result = try await generateText(model: wrapped, prompt: "p")
    #expect(result.reasoningText == "plan it")
    #expect(result.text == "The answer.")
  }

  @Test func extractsReasoningFromStreamWithSplitTags() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textStream(["<thi", "nk>step 1", " step 2</th", "ink>Final", " answer"])))
    let wrapped = wrapLanguageModel(model: model, middleware: extractReasoningMiddleware(tagName: "think"))
    let result = streamText(model: wrapped, prompt: "p")
    #expect(try await result.reasoningText == "step 1 step 2")
    #expect(try await result.text == "Final answer")
  }

  @Test func extractsReasoningWhenStartingWithReasoning() async throws {
    let model = MockLanguageModelV4(doStream: .parts(textStream(["thinking", "</think>", "done"])))
    let wrapped = wrapLanguageModel(
      model: model, middleware: extractReasoningMiddleware(tagName: "think", startWithReasoning: true))
    let result = streamText(model: wrapped, prompt: "p")
    #expect(try await result.reasoningText == "thinking")
    #expect(try await result.text == "done")
  }

  @Test func simulatesStreamingFromGenerate() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("whole answer")))
    let wrapped = wrapLanguageModel(model: model, middleware: simulateStreamingMiddleware())
    let result = streamText(model: wrapped, prompt: "p")
    #expect(try await collect(result.textStream) == ["whole answer"])
    #expect(model.doStreamCalls.isEmpty)
  }

  @Test func extractsJsonFromCodeFences() async throws {
    let model = MockLanguageModelV4(doGenerate: .result(.mockText("```json\n{\"name\":\"Ann\",\"age\":3}\n```")))
    let wrapped = wrapLanguageModel(model: model, middleware: extractJsonMiddleware())
    let result = try await generateText(model: wrapped, prompt: "p", output: .object(schema: personSchema))
    #expect(try result.output == Person(name: "Ann", age: 3))

    let streaming = MockLanguageModelV4(doStream: .parts(textStream(["```json\n{\"name\":", "\"Bo\",\"age\":5}\n```"])))
    let streamed = streamText(
      model: wrapLanguageModel(model: streaming, middleware: extractJsonMiddleware()), prompt: "p",
      output: .object(schema: personSchema))
    #expect(try await streamed.output == Person(name: "Bo", age: 5))
  }

  @Test func potentialStartIndexFindsPartialSuffix() {
    let text = "abc<thi"
    #expect(getPotentialStartIndex(text, "<think>").map { text.distance(from: text.startIndex, to: $0) } == 3)
    #expect(getPotentialStartIndex("abc", "<think>") == nil)
    #expect(getPotentialStartIndex("a<think>b", "<think>").map { "a<think>b".distance(from: "a<think>b".startIndex, to: $0) } == 1)
  }
}

@Suite struct EmbedTests {
  static func vectorModel(maxPerCall: Int?, parallel: Bool = true) -> MockEmbeddingModelV4 {
    MockEmbeddingModelV4(maxEmbeddingsPerCall: maxPerCall, supportsParallelCalls: parallel) { options in
      EmbeddingModelV4Result(
        embeddings: options.values.map { [Double($0.count), 1] }, usage: .init(tokens: options.values.count * 2),
        providerMetadata: ["mock": ["calls": 1]])
    }
  }

  @Test func embedsOneValue() async throws {
    let model = Self.vectorModel(maxPerCall: 1)
    let result = try await embed(model: model, value: "hello")
    #expect(result.embedding == [5, 1])
    #expect(result.usage.tokens == 2)
    #expect(model.doEmbedCalls.first?.headers?["user-agent"] == "ai/\(AISDK_VERSION)")
  }

  @Test func embedManySplitsByLimitAndKeepsOrder() async throws {
    let model = Self.vectorModel(maxPerCall: 2)
    let values = ["a", "bb", "ccc", "dddd", "eeeee"]
    let result = try await embedMany(model: model, values: values)
    #expect(result.embeddings.map { $0[0] } == [1, 2, 3, 4, 5])
    #expect(result.usage.tokens == 10)
    #expect(model.doEmbedCalls.count == 3)
    #expect(result.responses.count == 3)
  }

  @Test func embedManyWithoutLimitUsesOneCall() async throws {
    let model = Self.vectorModel(maxPerCall: nil, parallel: false)
    let result = try await embedMany(model: model, values: ["x", "y"])
    #expect(result.embeddings.count == 2)
    #expect(model.doEmbedCalls.count == 1)
  }

  @Test func rejectsMismatchedEmbeddingCount() async throws {
    let model = MockEmbeddingModelV4(maxEmbeddingsPerCall: nil) { _ in EmbeddingModelV4Result(embeddings: []) }
    await #expect(throws: InvalidResponseDataError.self) { _ = try await embedMany(model: model, values: ["a"]) }
  }

  @Test func cosineSimilarityMatchesUpstream() throws {
    #expect(abs(try cosineSimilarity([1, 2, 3], [4, 5, 6]) - 0.9746318461970762) < 1e-12)
    #expect(try cosineSimilarity([1, 0], [0, 1]) == 0)
    #expect(try cosineSimilarity([0, 0], [1, 1]) == 0)
    #expect(throws: InvalidArgumentError.self) { try cosineSimilarity([1], [1, 2]) }
  }

  @Test func wrapsEmbeddingModelWithDefaultSettings() async throws {
    let model = Self.vectorModel(maxPerCall: nil)
    let wrapped = wrapEmbeddingModel(
      model: model, middleware: [defaultEmbeddingSettingsMiddleware(providerOptions: ["mock": ["dim": 256]])])
    _ = try await embed(model: wrapped, value: "v")
    #expect(model.doEmbedCalls.first?.providerOptions == ["mock": ["dim": 256]])
  }
}

@Suite struct ProviderRegistryTests {
  struct MockProvider: ProviderV4 {
    let name: String
    func languageModel(_ modelId: String) throws -> any LanguageModelV4 {
      MockLanguageModelV4(provider: name, modelId: modelId, doGenerate: .result(.mockText("\(name)/\(modelId)")))
    }
  }

  @Test func resolvesModelsByPrefixedId() async throws {
    let registry = createProviderRegistry(["a": MockProvider(name: "a"), "b": MockProvider(name: "b")])
    let model = try registry.languageModel("b:model-1")
    #expect(model.provider == "b")
    #expect(model.modelId == "model-1")
    #expect(try await generateText(model: model, prompt: "p").text == "b/model-1")
  }

  @Test func reportsUnknownProvidersAndBadIds() {
    let registry = createProviderRegistry(["a": MockProvider(name: "a")], separator: " > ")
    #expect {
      _ = try registry.languageModel("z > m")
    } throws: { error in
      (error as? NoSuchProviderError)?.message == "No such provider: z (available providers: a)"
    }
    #expect(throws: NoSuchModelError.self) { _ = try registry.languageModel("no-separator") }
    #expect(throws: NoSuchModelError.self) { _ = try registry.embeddingModel("a > e") }
  }

  @Test func appliesRegistryMiddleware() async throws {
    let registry = createProviderRegistry(
      ["a": MockProvider(name: "a")], languageModelMiddleware: [extractReasoningMiddleware(tagName: "t")])
    let model = try registry.languageModel("a:m")
    #expect(model.modelId == "m")
  }

  @Test func customProviderUsesAliasesThenFallback() throws {
    let fast = MockLanguageModelV4(modelId: "real-fast")
    let provider = customProvider(languageModels: ["fast": fast], fallbackProvider: MockProvider(name: "fb"))
    #expect(try provider.languageModel("fast").modelId == "real-fast")
    #expect(try provider.languageModel("other").provider == "fb")
    #expect(throws: NoSuchModelError.self) { _ = try customProvider().languageModel("x") }
  }
}
