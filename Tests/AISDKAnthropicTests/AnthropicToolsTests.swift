import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKAnthropic

private let messagesURL = "https://api.anthropic.com/v1/messages"

private func upstreamJSON(_ name: String) throws -> JSONValue {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/upstream"))
  return try JSONValue(jsonData: try Data(contentsOf: url))
}

private func provider(_ client: MockHTTPClient) throws -> AnthropicProvider {
  try createAnthropic(
    AnthropicProviderSettings(
      baseURL: ANTHROPIC_API_VERSIONED_URL, apiKey: "test-api-key", httpClient: client, generateId: { "gen-id" }))
}

private let endTurn: JSONValue = [
  "id": "msg_2", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5",
  "content": [["type": "text", "text": "Done."]], "stop_reason": "end_turn",
  "usage": ["input_tokens": 1, "output_tokens": 1],
]

@Suite struct AnthropicToolsTests {
  @Test func factoriesProduceAPIToolDefinitions() async throws {
    let client = MockHTTPClient([messagesURL: .jsonValue(endTurn)])
    let anthropic = try provider(client)
    _ = try await generateText(
      model: anthropic("claude-sonnet-4-5"), prompt: "Hi",
      tools: [
        "web_search": anthropic.tools.webSearch_20250305(
          maxUses: 2, allowedDomains: ["swift.org"], userLocation: AnthropicUserLocation(city: "Berlin", country: "DE")),
        "web_fetch": AnthropicTools.webFetch_20260318(citations: true, useCache: false, responseInclusion: "excluded"),
        "editor": AnthropicTools.textEditor_20250728(maxCharacters: 500),
        "screen": AnthropicTools.computer_20251124(displayWidthPx: 1280, displayHeightPx: 800, enableZoom: true),
        "toolset": AnthropicTools.computerToolset_20260801(configs: ["zoom": ["enabled": false]]),
        "advisor": AnthropicTools.advisor_20260301(model: "claude-opus-5", maxTokens: 2048),
        "memory": AnthropicTools.memory_20250818(),
      ])

    let request = try #require(client.lastRequest)
    #expect(
      request.bodyJSON?["tools"]
        == [
          [
            "type": "web_search_20250305", "name": "web_search", "max_uses": 2, "allowed_domains": ["swift.org"],
            "user_location": ["type": "approximate", "city": "Berlin", "country": "DE"],
          ],
          [
            "type": "web_fetch_20260318", "name": "web_fetch", "citations": ["enabled": true], "use_cache": false,
            "response_inclusion": "excluded",
          ],
          ["name": "str_replace_based_edit_tool", "type": "text_editor_20250728", "max_characters": 500],
          [
            "name": "computer", "type": "computer_20251124", "display_width_px": 1280, "display_height_px": 800,
            "enable_zoom": true,
          ],
          ["type": "computer_toolset_20260801", "configs": ["zoom": ["enabled": false]]],
          ["type": "advisor_20260301", "name": "advisor", "model": "claude-opus-5", "max_tokens": 2048],
          ["name": "memory", "type": "memory_20250818"],
        ])
    let betas = Set((request.headers["anthropic-beta"] ?? "").split(separator: ",").map(String.init))
    #expect(betas == ["computer-use-2025-11-24", "advisor-tool-2026-03-01", "context-management-2025-06-27"])
  }

  @Test func webSearchRoundTripsProviderExecutedResults() async throws {
    let client = MockHTTPClient()
    client.respond(
      to: messagesURL, withSequence: [.jsonValue(try upstreamJSON("anthropic-web-search-tool.1")), .jsonValue(endTurn)])
    let anthropic = try provider(client)

    let first = try await generateText(
      model: anthropic("claude-sonnet-4-5"), prompt: "Latest Swift release?",
      tools: ["search": AnthropicTools.webSearch_20250305()])
    let call = try #require(first.toolCalls.first)
    #expect(call.toolName == "search")
    #expect(call.providerExecuted == true)
    let result = try #require(first.toolResults.first)
    #expect(result.toolCallId == call.toolCallId)
    #expect(result.output.arrayValue?.first?["type"] == "web_search_result")
    #expect(!first.sources.isEmpty)

    _ = try await generateText(
      model: anthropic("claude-sonnet-4-5"),
      prompt: .messages(
        [.user(UserModelMessage(content: [.text(TextPart(text: "Latest Swift release?"))]))]
          + first.response.messages + [.user(UserModelMessage(content: [.text(TextPart(text: "Thanks"))]))]),
      tools: ["search": AnthropicTools.webSearch_20250305()])
    let assistant = try #require(client.lastRequest?.bodyJSON?["messages"]?[1]?["content"]?.arrayValue)
    let types = assistant.compactMap { $0["type"]?.stringValue }
    #expect(types.contains("server_tool_use"))
    #expect(types.contains("web_search_tool_result"))
    let serverToolUse = try #require(assistant.first { $0["type"] == "server_tool_use" })
    #expect(serverToolUse["name"] == "web_search")
    #expect(serverToolUse["id"]?.stringValue == call.toolCallId)
  }

  @Test func clientToolsExecuteInTheApp() async throws {
    let client = MockHTTPClient()
    client.respond(
      to: messagesURL,
      withSequence: [
        .jsonValue([
          "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5",
          "content": [["type": "tool_use", "id": "toolu_1", "name": "bash", "input": ["command": "ls"]]],
          "stop_reason": "tool_use", "usage": ["input_tokens": 1, "output_tokens": 1],
        ]),
        .jsonValue(endTurn),
      ])
    let bash = AnthropicTools.bash_20250124(execute: { input, _ in
      .string("ran \(input["command"]?.stringValue ?? "")")
    })
    let result = try await generateText(
      model: try provider(client)("claude-sonnet-4-5"), prompt: "List files", tools: ["bash": bash],
      stopWhen: [.isStepCount(2)])
    #expect(result.text == "Done.")
    let toolResult = try #require(client.lastRequest?.bodyJSON?["messages"]?[2]?["content"]?[0])
    #expect(toolResult["type"] == "tool_result")
    #expect(toolResult["content"] == "ran ls")
    #expect(client.lastRequest?.bodyJSON?["tools"]?[0] == ["name": "bash", "type": "bash_20250124"])
  }

  @Test func forwardsTheLastContainerId() {
    let options = forwardAnthropicContainerIdFromLastStep([
      ["anthropic": ["container": ["id": "c1"]]], nil, ["anthropic": ["container": .null]],
    ])
    #expect(options == ["anthropic": ["container": ["id": "c1"]]])
    #expect(forwardAnthropicContainerIdFromLastStep([nil]) == nil)
  }
}
