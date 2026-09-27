import AISDK
import AISDKOpenAICompatible
import Foundation
import Testing

// Exercises the generic OpenAI-compatible provider against DeepSeek's
// OpenAI-format endpoint. Unknown provider options are passed through, so
// DeepSeek's `thinking` switch works without a dedicated provider.

private let compatible = createOpenAICompatible(
  OpenAICompatibleProviderSettings(
    baseURL: "https://api.deepseek.com", name: "deepseek",
    apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], includeUsage: true))

private let noThinking: ProviderOptions = ["deepseek": ["thinking": ["type": "disabled"]]]

@Suite(.enabled(if: liveEnabled), .serialized) struct OpenAICompatibleLiveTests {
  @Test func generatesText() async throws {
    let result = try await generateText(
      model: compatible(flash), prompt: "Reply with exactly: pong", providerOptions: noThinking)
    #expect(result.text.lowercased().contains("pong"))
    #expect(result.usage.inputTokens ?? 0 > 0)
    #expect(!result.response.modelId.isEmpty)
  }

  @Test func streamsReasoningAndText() async throws {
    let result = streamText(model: compatible(flash), prompt: "What is 17 * 3? Answer with just the number.")
    #expect(try await result.text.contains("51"))
    #expect(try await result.reasoningText?.isEmpty == false)
    #expect(try await result.usage.outputTokens ?? 0 > 0)
  }

  @Test func runsToolLoop() async throws {
    let result = try await generateText(
      model: compatible(flash), prompt: "What's the weather in Hangzhou? Use the tool.",
      tools: ["weather": weatherTool], providerOptions: noThinking, stopWhen: [.isStepCount(3)])
    #expect(result.steps.count >= 2)
    #expect(result.steps.first?.toolCalls.first?.toolName == "weather")
    #expect(result.text.contains("23") || result.text.lowercased().contains("sunny"))
  }

  @Test func generatesJsonObject() async throws {
    struct Answer: Codable, Sendable, Equatable { var answer: Int }
    let result = try await generateText(
      model: compatible(flash), prompt: "Return JSON with key answer = 6 * 7.",
      output: .object(schema: Schema(Answer.self, jsonSchema: ["type": "object", "properties": ["answer": ["type": "integer"]], "required": ["answer"]])),
      providerOptions: noThinking)
    #expect(try result.output == Answer(answer: 42))
  }
}
