import AISDK
import AISDKOpenAI
import Foundation
import Testing

// Runs the OpenAI Chat Completions model against DeepSeek's OpenAI-format
// endpoint to check the wire format and stream handling on a live service.
// Set OPENAI_API_KEY to also run against api.openai.com.

private let openaiOverDeepSeek = try! createOpenAI(
  OpenAIProviderSettings(
    baseURL: "https://api.deepseek.com", apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "missing",
    name: "deepseek"))

private let openaiEnabled = ProcessInfo.processInfo.environment["AISDK_LIVE_TESTS"] == "1"
  && ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil

@Suite(.enabled(if: liveEnabled), .serialized) struct OpenAIWireLiveTests {
  @Test func generatesAndStreamsText() async throws {
    let model = openaiOverDeepSeek.chat(flash)
    let generated = try await generateText(model: model, prompt: "Reply with exactly: pong")
    #expect(generated.text.lowercased().contains("pong"))
    let streamed = streamText(model: model, prompt: "Count from 1 to 5 separated by spaces.")
    #expect(try await streamed.text.contains("1 2 3 4 5"))
    #expect(try await streamed.usage.inputTokens ?? 0 > 0)
  }

  @Test func streamsToolLoop() async throws {
    let result = streamText(
      model: openaiOverDeepSeek.chat(flash), prompt: "What's the weather in Beijing? Use the tool.",
      tools: ["weather": weatherTool], stopWhen: [.isStepCount(3)])
    #expect(try await result.steps.count >= 2)
    #expect(try await result.steps.first?.toolCalls.first?.toolName == "weather")
  }

  @Test func surfacesEarlyStreamErrorsAsAPICallErrors() async throws {
    let broken = try createOpenAI(OpenAIProviderSettings(baseURL: "https://api.deepseek.com", apiKey: "sk-invalid"))
    await #expect(throws: APICallError.self) {
      _ = try await broken.chat(flash).doStream(LanguageModelV4CallOptions(prompt: [.user([.text(.init(text: "hi"))])]))
    }
  }
}

@Suite(.enabled(if: openaiEnabled), .serialized) struct OpenAIOfficialLiveTests {
  @Test func generatesTextAndEmbeddings() async throws {
    let openai = try createOpenAI()
    let result = try await generateText(model: openai.chat("gpt-4.1-nano"), prompt: "Reply with exactly: pong")
    #expect(result.text.lowercased().contains("pong"))
    let embedding = try await embed(model: openai.embedding("text-embedding-3-small"), value: "hello")
    #expect(embedding.embedding.count == 1536)
  }
}
