import Foundation
import Testing

@testable import AISDKProvider

private struct EchoModel: LanguageModelV4 {
  let provider = "test"
  let modelId = "echo"

  func doGenerate(_ options: LanguageModelV4CallOptions) async throws
    -> LanguageModelV4GenerateResult
  {
    LanguageModelV4GenerateResult(
      content: [.text(LanguageModelV4Text(text: lastUserText(options.prompt)))],
      finishReason: LanguageModelV4FinishReason(unified: .stop, raw: "stop"),
      usage: LanguageModelV4Usage(
        inputTokens: .init(total: 3), outputTokens: .init(total: 1, text: 1)))
  }

  func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let text = lastUserText(options.prompt)
    let stream = LanguageModelV4Stream { continuation in
      continuation.yield(.streamStart(warnings: []))
      continuation.yield(.textStart(id: "1"))
      continuation.yield(.textDelta(id: "1", delta: text))
      continuation.yield(.textEnd(id: "1"))
      continuation.yield(
        .finish(
          usage: LanguageModelV4Usage(), finishReason: LanguageModelV4FinishReason(unified: .stop)))
      continuation.finish()
    }
    return LanguageModelV4StreamResult(stream: stream)
  }

  private func lastUserText(_ prompt: LanguageModelV4Prompt) -> String {
    for message in prompt.reversed() {
      if case .user(let parts, _) = message {
        for part in parts {
          if case .text(let textPart) = part { return textPart.text }
        }
      }
    }
    return ""
  }
}

@Suite struct LanguageModelV4Tests {
  let options = LanguageModelV4CallOptions(prompt: [
    .system("You are terse."),
    .user([.text(LanguageModelV4TextPart(text: "hello"))]),
  ])

  @Test func defaultsApply() async throws {
    let model = EchoModel()
    #expect(model.specificationVersion == "v4")
    #expect(try await model.supportedUrls.isEmpty)
  }

  @Test func generatesContent() async throws {
    let result = try await EchoModel().doGenerate(options)
    #expect(result.content == [.text(LanguageModelV4Text(text: "hello"))])
    #expect(result.finishReason.unified == .stop)
    #expect(result.warnings.isEmpty)
  }

  @Test func streamsParts() async throws {
    let result = try await EchoModel().doStream(options)
    var parts: [LanguageModelV4StreamPart] = []
    for try await part in result.stream { parts.append(part) }
    #expect(
      parts == [
        .streamStart(warnings: []),
        .textStart(id: "1"),
        .textDelta(id: "1", delta: "hello"),
        .textEnd(id: "1"),
        .finish(
          usage: LanguageModelV4Usage(), finishReason: LanguageModelV4FinishReason(unified: .stop)),
      ])
  }

  @Test func errorPartsCompareByMessage() {
    let a = LanguageModelV4StreamPart.error(LoadAPIKeyError(message: "x"))
    let b = LanguageModelV4StreamPart.error(LoadAPIKeyError(message: "x"))
    let c = LanguageModelV4StreamPart.error(LoadAPIKeyError(message: "y"))
    #expect(a == b)
    #expect(a != c)
  }

  @Test func messageRoleAndProviderOptions() {
    let message = LanguageModelV4Message.assistant(
      [.text(LanguageModelV4TextPart(text: "hi"))],
      providerOptions: ["anthropic": ["cacheControl": ["type": "ephemeral"]]])
    #expect(message.role == .assistant)
    #expect(message.providerOptions?["anthropic"]?["cacheControl"]?["type"] == "ephemeral")
  }

  @Test func providerDefaultEmbeddingModelThrows() {
    struct OnlyLanguage: ProviderV4 {
      func languageModel(_ modelId: String) throws -> any LanguageModelV4 { EchoModel() }
    }
    #expect(throws: NoSuchModelError.self) { try OnlyLanguage().embeddingModel("e") }
    #expect(OnlyLanguage().specificationVersion == "v4")
  }

  @Test func fileDataEncodings() {
    let bytes = Data([0x68, 0x69])
    #expect(SharedV4FileData.data(bytes).base64String == "aGk=")
    #expect(SharedV4FileData.base64("aGk=").bytes == bytes)
    #expect(SharedV4FileData.text("hi").bytes == nil)
  }
}
