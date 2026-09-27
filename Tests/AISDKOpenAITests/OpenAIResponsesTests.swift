import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKOpenAI

private let responsesURL = "https://api.openai.com/v1/responses"

@Suite struct OpenAIResponsesTests {
  @Test func providerDefaultsToResponsesModel() throws {
    let openai = try makeOpenAI(MockHTTPClient())
    #expect(openai("gpt-5.4").provider == "openai.responses")
    #expect(try openai.languageModel("gpt-5.4").provider == "openai.responses")
    #expect(openai.chat("gpt-5.4").provider == "openai.chat")
  }

  @Test func sendsBuiltInToolsFromCoreToolSet() async throws {
    let client = MockHTTPClient([responsesURL: try jsonFixture("openai-web-search-tool.1")])
    let openai = try makeOpenAI(client)
    let result = try await generateText(
      model: openai("gpt-5-nano"), prompt: "What happened today?",
      tools: ["webSearch": openai.tools.webSearch(blockedDomains: ["example.com"], searchContextSize: "low")])

    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(
      body["tools"] == [
        ["type": "web_search", "filters": ["blocked_domains": ["example.com"]], "search_context_size": "low"]
      ])
    #expect(body["include"] == ["web_search_call.action.sources"])
    let toolResults = result.steps.flatMap(\.toolResults)
    #expect(!toolResults.isEmpty)
    #expect(toolResults.allSatisfy { $0.toolName == "webSearch" })
    #expect(!result.text.isEmpty)
    #expect(result.steps.count == 1)
  }

  @Test func mapsToolFactoryArguments() async throws {
    let client = MockHTTPClient([responsesURL: try jsonFixture("openai-phase.1")])
    let model = try makeOpenAI(client)("gpt-5.4")
    let tools: [String: Tool] = [
      "files": OpenAITools.fileSearch(vectorStoreIds: ["vs_1"], maxNumResults: 3, ranker: "auto", scoreThreshold: 0.2),
      "code": OpenAITools.codeInterpreter(container: .auto(fileIds: ["file-1"])),
      "image": OpenAITools.imageGeneration(outputFormat: "png", size: "1024x1024"),
      "mcp": OpenAITools.mcp(serverLabel: "docs", serverUrl: "https://example.com/mcp", requireApproval: "always"),
      "sql": OpenAITools.customTool(description: "SQL", format: ["type": "grammar", "syntax": "regex", "definition": "SELECT .+"]),
    ]
    _ = try await generateText(model: model, prompt: "Hi", tools: ToolSet(tools.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
    let sent = try #require(client.lastRequest?.bodyJSON?["tools"]?.arrayValue)
    let byType = Dictionary(uniqueKeysWithValues: sent.compactMap { tool in tool["type"]?.stringValue.map { ($0, tool) } })
    #expect(byType["code_interpreter"] == ["type": "code_interpreter", "container": ["type": "auto", "file_ids": ["file-1"]]])
    #expect(
      byType["file_search"] == [
        "type": "file_search", "vector_store_ids": ["vs_1"], "max_num_results": 3,
        "ranking_options": ["ranker": "auto", "score_threshold": 0.2],
      ])
    #expect(byType["image_generation"] == ["type": "image_generation", "output_format": "png", "size": "1024x1024"])
    #expect(
      byType["mcp"] == [
        "type": "mcp", "server_label": "docs", "server_url": "https://example.com/mcp", "require_approval": "always",
      ])
    #expect(
      byType["custom"] == [
        "type": "custom", "name": "sql", "description": "SQL",
        "format": ["type": "grammar", "syntax": "regex", "definition": "SELECT .+"],
      ])
  }

  @Test func rejectsMcpToolWithoutServer() async throws {
    let model = try makeOpenAI(MockHTTPClient())("gpt-5.4")
    await #expect(throws: TypeValidationError.self) {
      _ = try await model.doGenerate(
        LanguageModelV4CallOptions(
          prompt: testPrompt,
          tools: [.provider(LanguageModelV4ProviderTool(id: "openai.mcp", name: "mcp", args: ["serverLabel": "x"]))]))
    }
  }

  @Test func reportsChatCompletionsStreamMismatch() async throws {
    let client = MockHTTPClient([
      responsesURL: .streamChunks([
        #"data: {"choices":[],"created":0,"id":"","model":"","object":"","prompt_filter_results":[]}"# + "\n\n",
        "data: [DONE]\n\n",
      ])
    ])
    let result = try await makeOpenAI(client)("gpt-5.4").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)
    guard case .error(let error) = parts[1] else {
      Issue.record("expected error part")
      return
    }
    #expect((error as? APICallError)?.message.hasPrefix("Received a Chat Completions stream") == true)
  }

  @Test func escapesJSONDeltas() {
    #expect(escapeJSONDelta("a\"b\nc/d") == #"a\"b\nc/d"#)
  }

  @Test func expandsParallelWrapperOnlyForDeclaredTools() {
    let tools = [LanguageModelV4FunctionTool(name: "weather", inputSchema: ["type": "object"])]
    let input = #"{"tool_uses":[{"recipient_name":"functions.weather","parameters":{"location":"Rome"}}]}"#
    let expanded = expandParallelToolCall(
      toolCallId: "call_1", toolName: "parallel", input: input, tools: tools, providerOptionsName: "openai", itemId: "fc_1")
    #expect(expanded?.first?.toolCallId == "call_1_0")
    #expect(expanded?.first?.input == #"{"location":"Rome"}"#)
    #expect(
      expandParallelToolCall(
        toolCallId: "call_1", toolName: "parallel", input: input.replacingOccurrences(of: "weather", with: "other"),
        tools: tools, providerOptionsName: "openai", itemId: "fc_1") == nil)
  }
}
