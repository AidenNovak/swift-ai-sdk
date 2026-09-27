import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKOpenAI

private let completionURL = "https://api.openai.com/v1/completions"
private let embeddingURL = "https://api.openai.com/v1/embeddings"

@Suite struct OpenAICompletionTests {
  @Test func generatesFromRecordedResponse() async throws {
    let client = MockHTTPClient([completionURL: try jsonFixture("openai-completion-text")])
    let result = try await makeOpenAI(client).completion("gpt-3.5-turbo-instruct").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.system("Be brief."), .user([.text(LanguageModelV4TextPart(text: "Hello"))])],
        providerOptions: ["openai": ["echo": true, "logitBias": ["50256": -100], "suffix": "!", "user": "u", "logprobs": true]]))
    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "gpt-3.5-turbo-instruct", "prompt": "Be brief.\n\nuser:\nHello\n\nassistant:\n", "stop": ["\nuser:"],
        "echo": true, "logit_bias": ["50256": -100], "suffix": "!", "user": "u", "logprobs": 0,
      ])
    guard case .text(let text)? = result.content.first else {
      Issue.record("expected text")
      return
    }
    #expect(!text.text.isEmpty)
    #expect(result.usage.inputTokens.total != nil)
    #expect(result.providerMetadata?["openai"] != nil)
  }

  @Test func streamsRecordedChunks() async throws {
    let client = MockHTTPClient([completionURL: try chunksFixture("openai-completion-text")])
    let result = try await makeOpenAI(client).completion("gpt-3.5-turbo-instruct").doStream(
      LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)
    #expect(client.lastRequest?.bodyJSON?["stream_options"] == ["include_usage": true])
    #expect(parts.contains(.textStart(id: "0")))
    #expect(parts.contains(.textEnd(id: "0")))
    guard case .finish(let usage, _, _)? = parts.last else {
      Issue.record("missing finish")
      return
    }
    #expect(usage.outputTokens.total != nil)
  }

  @Test func warnsOnUnsupportedSettings() async throws {
    let client = MockHTTPClient([completionURL: try jsonFixture("openai-completion-text")])
    let result = try await makeOpenAI(client).completion("gpt-3.5-turbo-instruct").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, topK: 1, responseFormat: .json(schema: nil),
        tools: [.function(LanguageModelV4FunctionTool(name: "t", inputSchema: JSONSchema(["type": "object"])))],
        toolChoice: .auto))
    #expect(
      result.warnings == [
        .unsupported(feature: "topK"), .unsupported(feature: "tools"), .unsupported(feature: "toolChoice"),
        .unsupported(feature: "responseFormat", details: "JSON response format is not supported."),
      ])
  }
}

@Suite struct OpenAIEmbeddingTests {
  @Test func embedsRecordedResponse() async throws {
    let client = MockHTTPClient([embeddingURL: try jsonFixture("openai-embedding")])
    let model = try makeOpenAI(client).embedding("text-embedding-3-large")
    let result = try await model.doEmbed(
      EmbeddingModelV4CallOptions(values: ["sunny day at the beach", "rainy day in the city"], providerOptions: ["openai": ["dimensions": 64, "user": "u"]]))
    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "text-embedding-3-large", "input": ["sunny day at the beach", "rainy day in the city"],
        "encoding_format": "float", "dimensions": 64, "user": "u",
      ])
    #expect(!result.embeddings.isEmpty)
    #expect(result.usage != nil)
    #expect(try await model.maxEmbeddingsPerCall == 2048)
  }

  @Test func rejectsTooManyValues() async throws {
    let model = try makeOpenAI(MockHTTPClient()).embedding("text-embedding-3-small")
    await #expect(throws: TooManyEmbeddingValuesForCallError.self) {
      _ = try await model.doEmbed(EmbeddingModelV4CallOptions(values: Array(repeating: "x", count: 2049)))
    }
  }

  @Test func worksThroughRegistryAndEmbedMany() async throws {
    let client = MockHTTPClient([embeddingURL: try jsonFixture("openai-embedding")])
    let registry = createProviderRegistry(["openai": try makeOpenAI(client)])
    let result = try await embedMany(
      model: try registry.embeddingModel("openai:text-embedding-3-large"),
      values: ["sunny day at the beach", "rainy day in the city"])
    #expect(result.embeddings.count == 2)
  }
}
