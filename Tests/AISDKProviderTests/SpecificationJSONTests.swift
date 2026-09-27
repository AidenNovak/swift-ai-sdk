import AISDKProvider
import Foundation
import Testing

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Suite struct SpecificationJSONTests {
  let metadata: SharedV4ProviderMetadata = ["test": ["key": "value"]]

  @Test func promptMessagesRoundTrip() throws {
    let prompt: LanguageModelV4Prompt = [
      .system("Be brief.", providerOptions: metadata),
      .user(
        [
          .text(LanguageModelV4TextPart(text: "Look", providerOptions: metadata)),
          .file(
            LanguageModelV4FilePart(
              data: .url(URL(string: "https://example.com/a.png")!), mediaType: "image/png", filename: "a.png")),
          .file(LanguageModelV4FilePart(data: .base64("aGk="), mediaType: "text/plain")),
          .file(LanguageModelV4FilePart(data: .reference(["openai": "file-1"]), mediaType: "application/pdf")),
        ]),
      .assistant([
        .reasoning(LanguageModelV4ReasoningPart(text: "Thinking", providerOptions: metadata)),
        .text(LanguageModelV4TextPart(text: "Calling")),
        .toolCall(
          LanguageModelV4ToolCallPart(toolCallId: "c1", toolName: "weather", input: ["city": "Paris"], providerExecuted: true)),
        .toolResult(
          LanguageModelV4ToolResultPart(toolCallId: "c1", toolName: "weather", output: .json(["temperature": 20]))),
        .custom(LanguageModelV4CustomPart(kind: "openai.compaction")),
        .reasoningFile(LanguageModelV4ReasoningFilePart(data: .text("notes"), mediaType: "text/plain")),
      ]),
      .tool([
        .toolResult(
          LanguageModelV4ToolResultPart(
            toolCallId: "c2", toolName: "search",
            output: .content([
              .text("found"), .file(data: .base64("iVBORw0KGgo="), mediaType: "image/png"), .custom(providerOptions: metadata),
            ]))),
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "c3", toolName: "x", output: .errorText("failed"))),
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "c4", toolName: "x", output: .executionDenied(reason: "no"))),
        .toolApprovalResponse(LanguageModelV4ToolApprovalResponsePart(approvalId: "a1", approved: false, reason: "no")),
      ]),
    ]
    #expect(try roundTrip(prompt) == prompt)
    #expect(prompt[1].json["content"]?[1]?["data"] == ["type": "url", "url": "https://example.com/a.png"])
  }

  @Test func callOptionsRoundTrip() throws {
    let options = LanguageModelV4CallOptions(
      prompt: [.user([.text(LanguageModelV4TextPart(text: "Hi"))])], maxOutputTokens: 100, temperature: 0.5,
      stopSequences: ["END"], topP: 0.9, topK: 3, presencePenalty: 0.1, frequencyPenalty: 0.2,
      responseFormat: .json(schema: ["type": "object"], name: "answer"), seed: 7,
      tools: [
        .function(
          LanguageModelV4FunctionTool(
            name: "weather", description: "Weather", inputSchema: ["type": "object"], inputExamples: [["city": "Paris"]],
            strict: true)),
        .provider(LanguageModelV4ProviderTool(id: "openai.web_search", name: "search", args: ["size": "low"])),
      ],
      toolChoice: .tool(toolName: "weather"), includeRawChunks: true, headers: ["x": "1"], reasoning: .high,
      providerOptions: metadata)
    #expect(try roundTrip(options) == options)
  }

  @Test func contentAndStreamPartsRoundTrip() throws {
    let content: [LanguageModelV4Content] = [
      .text(LanguageModelV4Text(text: "Hi", providerMetadata: metadata)),
      .reasoning(LanguageModelV4Reasoning(text: "Hmm")),
      .file(LanguageModelV4File(mediaType: "image/png", data: .base64("iVBORw0KGgo="))),
      .source(.url(id: "s1", url: "https://swift.org", title: "Swift")),
      .source(.document(id: "s2", mediaType: "application/pdf", title: "Doc", filename: "doc.pdf")),
      .toolCall(LanguageModelV4ToolCall(toolCallId: "c1", toolName: "weather", input: "{}", providerExecuted: true)),
      .toolResult(LanguageModelV4ToolResult(toolCallId: "c1", toolName: "weather", result: ["ok": true], isError: false)),
      .toolApprovalRequest(LanguageModelV4ToolApprovalRequest(approvalId: "a1", toolCallId: "c1")),
      .custom(LanguageModelV4CustomContent(kind: "anthropic.container_upload")),
    ]
    #expect(try roundTrip(content) == content)

    let usage = LanguageModelV4Usage(
      inputTokens: .init(total: 10, noCache: 8, cacheRead: 2), outputTokens: .init(total: 5, text: 3, reasoning: 2),
      raw: ["input_tokens": 10])
    let parts: [LanguageModelV4StreamPart] = [
      .streamStart(warnings: [.unsupported(feature: "seed"), .other(message: "note")]),
      .responseMetadata(
        LanguageModelV4ResponseMetadata(id: "r1", timestamp: Date(timeIntervalSince1970: 1_700_000_000), modelId: "m")),
      .textStart(id: "0"), .textDelta(id: "0", delta: "Hi"), .textEnd(id: "0", providerMetadata: metadata),
      .reasoningStart(id: "r"), .reasoningDelta(id: "r", delta: "x"), .reasoningEnd(id: "r"),
      .toolInputStart(LanguageModelV4ToolInputStart(id: "c1", toolName: "weather", providerExecuted: true, title: "W")),
      .toolInputDelta(id: "c1", delta: "{}"), .toolInputEnd(id: "c1"),
      .toolCall(LanguageModelV4ToolCall(toolCallId: "c1", toolName: "weather", input: "{}")),
      .raw(rawValue: ["anything": 1]),
      .finish(usage: usage, finishReason: LanguageModelV4FinishReason(unified: .toolCalls, raw: "tool_use")),
    ]
    #expect(try roundTrip(parts) == parts)
  }

  @Test func streamErrorsKeepTheirMessage() throws {
    let part = LanguageModelV4StreamPart.error(InvalidResponseDataError(data: nil, message: "Bad chunk"))
    #expect(part.json == ["type": "error", "error": "Bad chunk"])
    let decoded = try LanguageModelV4StreamPart(json: ["type": "error", "error": ["message": "Overloaded", "code": 529]])
    guard case .error(let error as DecodedStreamError) = decoded else {
      Issue.record("expected a decoded error")
      return
    }
    #expect(error.message == "Overloaded")
    #expect(decoded.json["error"]?["code"] == 529)
  }

  @Test func rejectsUnknownTypes() {
    #expect(throws: SpecificationDecodingError.self) { try LanguageModelV4Content(json: ["type": "mystery"]) }
    #expect(throws: SpecificationDecodingError.self) { try LanguageModelV4Message(json: ["role": "robot"]) }
  }
}
