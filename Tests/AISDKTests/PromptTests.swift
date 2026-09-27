import AISDKTestUtils
import Foundation
import Testing

@testable import AISDK

@Suite struct ModelMessageCodableTests {
  @Test func encodesUpstreamJSONShape() throws {
    let messages: [ModelMessage] = [
      .system("be nice"),
      .user([.text(TextPart(text: "look")), .image(ImagePart(image: .url(URL(string: "https://x.dev/a.png")!)))]),
      .assistant([
        .reasoning(ReasoningPart(text: "hmm")),
        .toolCall(ToolCallPart(toolCallId: "c1", toolName: "weather", input: ["city": "Beijing"])),
      ]),
      .tool([.toolResult(ToolResultPart(toolCallId: "c1", toolName: "weather", output: .json(["temp": 25])))]),
    ]
    let json = JSONValue.array(messages.map(\.json)).jsonString(sortedKeys: true)
    #expect(
      json
        == #"[{"content":"be nice","role":"system"},{"content":[{"text":"look","type":"text"},{"image":"https://x.dev/a.png","type":"image"}],"role":"user"},{"content":[{"text":"hmm","type":"reasoning"},{"input":{"city":"Beijing"},"toolCallId":"c1","toolName":"weather","type":"tool-call"}],"role":"assistant"},{"content":[{"output":{"type":"json","value":{"temp":25}},"toolCallId":"c1","toolName":"weather","type":"tool-result"}],"role":"tool"}]"#
    )
  }

  @Test func roundTripsThroughCodable() throws {
    let messages: [ModelMessage] = [
      .user([.file(FilePart(data: .base64("aGk="), mediaType: "text/plain", filename: "a.txt"))]),
      .assistant([
        .text(TextPart(text: "hi", providerOptions: ["openai": ["itemId": "x"]])),
        .toolApprovalRequest(ToolApprovalRequest(approvalId: "a", toolCallId: "c", isAutomatic: false)),
      ]),
      .tool([
        .toolApprovalResponse(ToolApprovalResponse(approvalId: "a", approved: false, reason: "no")),
        .toolResult(ToolResultPart(toolCallId: "c", toolName: "t", output: .executionDenied(reason: "no"))),
        .toolResult(
          ToolResultPart(
            toolCallId: "d", toolName: "t",
            output: .content([.text("see"), .file(data: .base64("aGk="), mediaType: "image/png")]))),
      ]),
    ]
    let data = try JSONEncoder().encode(messages)
    #expect(try JSONDecoder().decode([ModelMessage].self, from: data) == messages)
  }

  @Test func decodesStringContent() throws {
    let message = try JSONDecoder().decode(ModelMessage.self, from: Data(#"{"role":"user","content":"hello"}"#.utf8))
    #expect(message == .user("hello"))
    let assistant = try ModelMessage(json: ["role": "assistant", "content": "hi"])
    #expect(assistant == .assistant("hi"))
  }

  @Test func rejectsUnknownRoles() {
    #expect(throws: MessageDecodingError.self) { try ModelMessage(json: ["role": "robot", "content": "x"]) }
  }
}

@Suite struct ConvertToLanguageModelPromptTests {
  @Test func convertsDataURLImagesAndDetectsMediaType() async throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).base64EncodedString()
    let prompt = StandardizedPrompt(
      instructions: nil,
      messages: [.user([.image(ImagePart(image: .url(URL(string: "data:image/png;base64,\(png)")!)))])])
    let result = try await convertToLanguageModelPrompt(prompt: prompt, supportedUrls: [:])
    #expect(
      result == [.user([.file(LanguageModelV4FilePart(data: .base64(png), mediaType: "image/png"))])])
  }

  @Test func downloadsUnsupportedURLsAndKeepsSupportedOnes() async throws {
    let requested = Recorder<[PlannedDownload]>()
    let download: DownloadFunction = { planned in
      requested.append(planned)
      return planned.map { $0.isUrlSupportedByModel ? nil : DownloadedFile(data: Data([0xFF, 0xD8, 0xFF]), mediaType: "image/jpeg") }
    }
    let prompt = StandardizedPrompt(
      instructions: nil,
      messages: [
        .user([
          .file(FilePart(data: .url(URL(string: "https://cdn.test/a")!), mediaType: "image")),
          .file(FilePart(data: .url(URL(string: "https://native.test/doc.pdf")!), mediaType: "application/pdf")),
        ])
      ])
    let result = try await convertToLanguageModelPrompt(
      prompt: prompt, supportedUrls: ["application/pdf": ["^https://native\\.test/"]], download: download)

    #expect(requested.values.first?.map(\.isUrlSupportedByModel) == [false, true])
    #expect(
      result == [
        .user([
          .file(LanguageModelV4FilePart(data: .data(Data([0xFF, 0xD8, 0xFF])), mediaType: "image/jpeg")),
          .file(
            LanguageModelV4FilePart(data: .url(URL(string: "https://native.test/doc.pdf")!), mediaType: "application/pdf")),
        ])
      ])
  }

  @Test func throwsForMissingToolResults() async throws {
    let prompt = StandardizedPrompt(
      instructions: nil,
      messages: [
        .user("p"),
        .assistant([.toolCall(ToolCallPart(toolCallId: "c1", toolName: "t", input: [:]))]),
        .user("next"),
      ])
    await #expect {
      _ = try await convertToLanguageModelPrompt(prompt: prompt, supportedUrls: [:])
    } throws: { error in
      (error as? MissingToolResultsError)?.message == "Tool result is missing for tool call c1."
    }
  }

  @Test func mergesConsecutiveToolMessagesAndDropsEmptyText() async throws {
    let prompt = StandardizedPrompt(
      instructions: .messages([SystemModelMessage(content: "sys")]),
      messages: [
        .user([.text(TextPart(text: "")), .text(TextPart(text: "q"))]),
        .assistant([
          .toolCall(ToolCallPart(toolCallId: "a", toolName: "t", input: [:])),
          .toolCall(ToolCallPart(toolCallId: "b", toolName: "t", input: [:])),
        ]),
        .tool([.toolResult(ToolResultPart(toolCallId: "a", toolName: "t", output: .text("1")))]),
        .tool([.toolResult(ToolResultPart(toolCallId: "b", toolName: "t", output: .text("2")))]),
      ])
    let result = try await convertToLanguageModelPrompt(prompt: prompt, supportedUrls: [:])
    #expect(result.count == 4)
    #expect(result[0] == .system("sys"))
    #expect(result[1] == .user([.text(LanguageModelV4TextPart(text: "q"))]))
    guard case .tool(let content, _) = result[3] else {
      Issue.record("expected merged tool message")
      return
    }
    #expect(content.count == 2)
  }

  @Test func approvedToolCallsDoNotNeedResults() async throws {
    let prompt = StandardizedPrompt(
      instructions: nil,
      messages: [
        .user("p"),
        .assistant([
          .toolCall(ToolCallPart(toolCallId: "c1", toolName: "t", input: [:])),
          .toolApprovalRequest(ToolApprovalRequest(approvalId: "a1", toolCallId: "c1")),
        ]),
        .tool([.toolApprovalResponse(ToolApprovalResponse(approvalId: "a1", approved: true))]),
      ])
    let result = try await convertToLanguageModelPrompt(prompt: prompt, supportedUrls: [:])
    #expect(result.count == 2)
  }
}

@Suite struct ToolSetTests {
  @Test func preservesDeclarationOrderAndSupportsMutation() {
    var tools: ToolSet = ["z": tool(inputSchema: valueSchema), "a": tool(inputSchema: valueSchema)]
    #expect(tools.names == ["z", "a"])
    tools["m"] = tool(inputSchema: valueSchema)
    tools["z"] = nil
    #expect(tools.names == ["a", "m"])
    #expect(tools.filtered(to: ["m"]).names == ["m"])
    #expect(tools.merging(["b": tool(inputSchema: valueSchema)]).names == ["a", "m", "b"])
  }

  @Test func usageAddsNilAware() {
    let a = LanguageModelUsage(inputTokens: 1, outputTokens: nil, totalTokens: 1)
    let b = LanguageModelUsage(inputTokens: 2, outputTokens: nil, totalTokens: 2)
    let sum = a + b
    #expect(sum.inputTokens == 3)
    #expect(sum.outputTokens == nil)
    #expect(sum.totalTokens == 3)
  }
}
