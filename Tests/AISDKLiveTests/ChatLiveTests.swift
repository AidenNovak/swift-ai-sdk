import AISDK
import AISDKDeepSeek
import AISDKTestUtils
import AISDKUI
import Foundation
import Testing

@MainActor
@Suite(.enabled(if: liveEnabled), .serialized) struct ChatLiveTests {
  @Test func chatRunsAgentToolLoopInProcess() async throws {
    let agent = ToolLoopAgent(
      model: deepseek(flash), instructions: "Use the weather tool for weather questions.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, reasoning: .low)
    let chat = Chat(transport: DirectChatTransport(agent: agent), throttle: .milliseconds(30))

    try await chat.sendMessage(text: "What's the weather in Hangzhou?")

    #expect(chat.status == .ready, "\(String(describing: chat.error))")
    let assistant = try #require(chat.messages.last)
    #expect(assistant.role == .assistant)
    let weather = try #require(assistant.toolParts.first { $0.toolName == "weather" })
    #expect(weather.state == .outputAvailable)
    #expect(assistant.parts.filter { $0 == .stepStart }.count >= 2)
    #expect(assistant.text.contains("23") || assistant.text.lowercased().contains("sunny"))

    try await chat.sendMessage(text: "And in Qingdao? One sentence.")
    #expect(chat.status == .ready)
    #expect(chat.messages.count == 4)
  }

  @Test func chatApprovesToolCallsAndContinues() async throws {
    let deleteNote = Tool(
      description: "Delete a note by title.",
      inputSchema: jsonSchema(["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]),
      needsApproval: { _, _ in true },
      execute: { input, _ in ["deleted": input["title"] ?? .null] })
    let agent = ToolLoopAgent(
      model: deepseek(flash), instructions: "Use the deleteNote tool to delete notes.",
      tools: ["deleteNote": deleteNote], maxOutputTokens: 2000, reasoning: .low)
    let chat = Chat(
      transport: DirectChatTransport(agent: agent),
      sendAutomaticallyWhen: { lastAssistantMessageIsCompleteWithApprovalResponses($0) })

    try await chat.sendMessage(text: "Delete the note titled 'groceries'.")
    let request = try #require(chat.messages.last?.toolParts.first { $0.state == .approvalRequested })
    let approvalId = try #require(request.approval?.id)

    await chat.addToolApprovalResponse(id: approvalId, approved: true)
    for _ in 0..<600 where chat.status != .ready || chat.messages.last?.toolParts.first?.state != .outputAvailable {
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(chat.status == .ready, "\(String(describing: chat.error))")
    let tool = try #require(chat.messages.last?.toolParts.first { $0.toolCallId == request.toolCallId })
    #expect(tool.state == .outputAvailable)
    #expect(tool.output == ["deleted": "groceries"])
    #expect(chat.messages.last?.text.isEmpty == false)
  }

  @Test func serverResponseRoundTripsThroughTheWireProtocol() async throws {
    let result = streamText(
      model: deepseek(flash), prompt: "Reply with exactly: pong",
      providerOptions: ["deepseek": ["thinking": ["type": "disabled"]]])
    let response = result.toUIMessageStreamResponse(
      options: UIMessageStreamOptions(generateMessageId: { "server-message" }))
    #expect(response.headers["x-vercel-ai-ui-message-stream"] == "v1")

    let messages = try await collect(readUIMessageStream(stream: parseUIMessageStream(response.body)))
    let final = try #require(messages.last)
    #expect(final.id == "server-message")
    #expect(final.text.lowercased().contains("pong"))
  }
}
