import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKAnthropic

private let messagesURL = "https://api.anthropic.com/v1/messages"
private let testPrompt: LanguageModelV4Prompt = [.user([.text(LanguageModelV4TextPart(text: "Hello"))])]

private func fixture(_ name: String, _ ext: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func jsonFixture(_ name: String) throws -> MockHTTPClient.Response {
  .jsonValue(try JSONValue(jsonString: try fixture(name, "json")))
}

private func chunksFixture(_ name: String) throws -> MockHTTPClient.Response {
  let lines = try fixture(name, "chunks.txt").split(separator: "\n").filter { !$0.isEmpty }
  return .streamChunks(lines.map { "data: \($0)\n\n" })
}

private func makeProvider(_ client: MockHTTPClient, baseURL: String? = nil, name: String? = nil) throws
  -> AnthropicProvider
{
  try createAnthropic(
    AnthropicProviderSettings(
      baseURL: baseURL ?? ANTHROPIC_API_VERSIONED_URL, apiKey: "test-api-key", name: name, httpClient: client, generateId: { "gen-id" }))
}

@Suite struct AnthropicGenerateTests {
  @Test func sendsModelIdSettingsAndHeaders() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    let result = try await makeProvider(client)("claude-3-haiku-20240307").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, maxOutputTokens: 100, temperature: 0.5, stopSequences: ["abc", "def"], topK: 1,
        frequencyPenalty: 0.15))

    let request = try #require(client.lastRequest)
    #expect(
      request.bodyJSON == [
        "max_tokens": 100,
        "messages": [["content": [["text": "Hello", "type": "text"]], "role": "user"]],
        "model": "claude-3-haiku-20240307",
        "stop_sequences": ["abc", "def"],
        "temperature": 0.5,
        "top_k": 1,
      ])
    #expect(result.warnings == [.unsupported(feature: "frequencyPenalty")])
    #expect(request.headers["x-api-key"] == "test-api-key")
    #expect(request.headers["anthropic-version"] == "2023-06-01")
    #expect(request.headers["user-agent"]?.hasPrefix("ai-sdk/anthropic/") == true)
  }

  @Test func extractsTextUsageAndMetadata() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))

    guard case .text(let text) = result.content.first else {
      Issue.record("expected text")
      return
    }
    #expect(!text.text.isEmpty)
    #expect(result.finishReason.unified == .stop)
    #expect(result.usage.inputTokens.noCache != nil)
    #expect(result.usage.inputTokens.cacheWrite == 0)
    #expect(result.providerMetadata?["anthropic"]?["usage"] != nil)
    #expect(result.response?.id?.hasPrefix("msg_") == true)
  }

  @Test func extractsToolCallsWithEmptyInput() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-tool-no-args")])
    let result = try await makeProvider(client)("claude-3-opus-20240229").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [.function(LanguageModelV4FunctionTool(name: "updateIssueList", inputSchema: ["type": "object"]))]))

    let call = result.content.compactMap { part -> LanguageModelV4ToolCall? in
      if case .toolCall(let call) = part { return call }
      return nil
    }.first
    #expect(call == LanguageModelV4ToolCall(toolCallId: "toolu_01LRmxn9vGM1d2DZSDBowdZ1", toolName: "updateIssueList", input: "{}"))
    #expect(result.finishReason == LanguageModelV4FinishReason(unified: .toolCalls, raw: "tool_use"))
    #expect(result.usage.inputTokens.total == 602)
    #expect(result.usage.outputTokens.total == 93)
  }

  @Test func mapsToolsAndToolChoice() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-tool-no-args")])
    let model = try makeProvider(client)("claude-3-haiku-20240307")
    let tools: [LanguageModelV4Tool] = [
      .function(
        LanguageModelV4FunctionTool(
          name: "weather", description: "Get weather", inputSchema: ["type": "object"],
          providerOptions: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]))
    ]

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, tools: tools, toolChoice: .required))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(
      body["tools"] == [
        [
          "name": "weather", "description": "Get weather", "input_schema": ["type": "object"],
          "cache_control": ["type": "ephemeral"],
        ]
      ])
    #expect(body["tool_choice"] == ["type": "any"])

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, tools: tools, toolChoice: .tool(toolName: "weather")))
    #expect(client.lastRequest?.bodyJSON?["tool_choice"] == ["type": "tool", "name": "weather"])

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, tools: tools, toolChoice: LanguageModelV4ToolChoice.none))
    #expect(client.lastRequest?.bodyJSON?["tools"] == nil)
  }

  @Test func clampsTemperatureAndHandlesTopPConflict() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, temperature: 1.5, topP: 0.9))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["temperature"] == 1)
    #expect(body["top_p"] == nil)
    #expect(result.warnings.count == 2)
  }

  @Test func thinkingAddsBudgetAndDropsSampling() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, maxOutputTokens: 1000, temperature: 0.5,
        providerOptions: ["anthropic": ["thinking": ["type": "enabled", "budgetTokens": 2000]]]))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["thinking"] == ["type": "enabled", "budget_tokens": 2000])
    #expect(body["max_tokens"] == 3000)
    #expect(body["temperature"] == nil)
    #expect(result.warnings.contains { if case .unsupported(feature: "temperature", _) = $0 { true } else { false } })
  }

  @Test func topLevelReasoningUsesAdaptiveThinkingOnNewModels() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    _ = try await makeProvider(client)("claude-sonnet-4-6").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .high))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
    #expect(body["output_config"] == ["effort": "high"])

    _ = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .low))
    #expect(client.lastRequest?.bodyJSON?["thinking"] == ["type": "enabled", "budget_tokens": 6400])
  }

  @Test func jsonResponseFormatUsesToolOnOlderModels() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-json-tool.1")])
    let schema: JSONSchema = ["type": "object", "properties": ["name": ["type": "string"]]]
    let result = try await makeProvider(client)("claude-3-haiku-20240307").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: schema)))

    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["tools"]?[0]?["name"] == "json")
    #expect(body["tool_choice"] == ["type": "any", "disable_parallel_tool_use": true])
    guard case .text(let text)? = result.content.last else {
      Issue.record("expected JSON text, got \(result.content)")
      return
    }
    #expect(isParsableJson(text.text))
    #expect(result.finishReason.unified == .stop)
  }

  @Test func jsonResponseFormatUsesOutputFormatOnNewModels() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-json-output-format.1")])
    let schema: JSONSchema = ["type": "object", "properties": ["name": ["type": "string"]]]
    _ = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: schema)))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["output_config"] == ["format": ["type": "json_schema", "schema": schema.value]])
    #expect(body["tools"] == nil)
  }

  @Test func refusalMapsToContentFilter() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-refusal")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(result.finishReason.unified == .contentFilter)
  }

  @Test func apiErrorsBecomeAPICallErrors() async throws {
    let client = MockHTTPClient([
      messagesURL: .error(
        statusCode: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
    ])
    await #expect {
      _ = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let error = error as? APICallError
      return error?.message == "Overloaded" && error?.statusCode == 529 && error?.isRetryable == true
    }
  }

  @Test func betasFromHeadersAreMerged() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    _ = try await makeProvider(client)("claude-sonnet-4-5").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [
          .user([.file(LanguageModelV4FilePart(data: .base64("JVBERi0="), mediaType: "application/pdf"))])
        ],
        headers: ["anthropic-beta": "custom-beta"]))
    #expect(client.lastRequest?.headers["anthropic-beta"] == "custom-beta,pdfs-2024-09-25")
  }

  @Test func rejectsApiKeyAndAuthTogether() {
    #expect(throws: InvalidArgumentError.self) {
      try createAnthropic(AnthropicProviderSettings(apiKey: "a", authToken: "b"))
    }
  }

  @Test func authTokenUsesBearerHeader() async throws {
    let client = MockHTTPClient([messagesURL: try jsonFixture("anthropic-text")])
    let provider = try createAnthropic(
      AnthropicProviderSettings(baseURL: ANTHROPIC_API_VERSIONED_URL, authToken: "tok", httpClient: client))
    _ = try await provider("claude-sonnet-4-5").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.headers["authorization"] == "Bearer tok")
    #expect(client.lastRequest?.headers["x-api-key"] == nil)
  }
}

@Suite struct AnthropicPromptTests {
  @Test func groupsToolResultsIntoUserTurnsWithCacheControl() throws {
    var warnings: [SharedV4Warning] = []
    let prompt: LanguageModelV4Prompt = [
      .system("sys", providerOptions: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]),
      .user([.text(LanguageModelV4TextPart(text: "q"))]),
      .assistant([
        .reasoning(
          LanguageModelV4ReasoningPart(text: "think", providerOptions: ["anthropic": ["signature": "sig"]])),
        .toolCall(LanguageModelV4ToolCallPart(toolCallId: "t1", toolName: "calc", input: ["a": 1])),
      ]),
      .tool([.toolResult(LanguageModelV4ToolResultPart(toolCallId: "t1", toolName: "calc", output: .errorText("bad")))]),
      .user([.text(LanguageModelV4TextPart(text: "again"))]),
      .assistant([.text(LanguageModelV4TextPart(text: "prefill  "))]),
    ]
    let result = try convertToAnthropicPrompt(
      prompt: prompt, sendReasoning: true, warnings: &warnings, validator: CacheControlValidator())

    #expect(result.prompt.system == [["type": "text", "text": "sys", "cache_control": ["type": "ephemeral"]]])
    #expect(result.prompt.messages.count == 4)
    #expect(
      result.prompt.messages[1]
        == [
          "role": "assistant",
          "content": [
            ["type": "thinking", "thinking": "think", "signature": "sig"],
            ["type": "tool_use", "id": "t1", "name": "calc", "input": ["a": 1]],
          ],
        ])
    #expect(
      result.prompt.messages[2]
        == [
          "role": "user",
          "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "bad", "is_error": true],
            ["type": "text", "text": "again"],
          ],
        ])
    #expect(result.prompt.messages[3]["content"]?[0]?["text"] == "prefill")
    #expect(warnings.isEmpty)
  }

  @Test func convertsImagesAndDocuments() throws {
    var warnings: [SharedV4Warning] = []
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0])
    let prompt: LanguageModelV4Prompt = [
      .user([
        .file(LanguageModelV4FilePart(data: .data(png), mediaType: "image")),
        .file(LanguageModelV4FilePart(data: .url(URL(string: "https://x.dev/a.pdf")!), mediaType: "application/pdf")),
        .file(
          LanguageModelV4FilePart(
            data: .text("doc body"), mediaType: "text/plain", filename: "notes.txt",
            providerOptions: ["anthropic": ["citations": ["enabled": true]]])),
      ])
    ]
    let result = try convertToAnthropicPrompt(
      prompt: prompt, sendReasoning: true, warnings: &warnings, validator: CacheControlValidator())
    let content = try #require(result.prompt.messages[0]["content"])
    #expect(content[0] == ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]])
    #expect(content[1] == ["type": "document", "source": ["type": "url", "url": "https://x.dev/a.pdf"]])
    #expect(
      content[2]
        == [
          "type": "document", "source": ["type": "text", "media_type": "text/plain", "data": "doc body"],
          "title": "notes.txt", "citations": ["enabled": true],
        ])
    #expect(result.betas == ["pdfs-2024-09-25"])
  }

  @Test func limitsCacheBreakpoints() throws {
    var warnings: [SharedV4Warning] = []
    let cached: SharedV4ProviderOptions = ["anthropic": ["cacheControl": ["type": "ephemeral"]]]
    let prompt: LanguageModelV4Prompt = [
      .user((0..<5).map { .text(LanguageModelV4TextPart(text: "p\($0)", providerOptions: cached)) })
    ]
    let validator = CacheControlValidator()
    _ = try convertToAnthropicPrompt(prompt: prompt, sendReasoning: true, warnings: &warnings, validator: validator)
    #expect(validator.warnings.count == 1)
  }
}

@Suite struct AnthropicStreamTests {
  @Test func streamsText() async throws {
    let client = MockHTTPClient([messagesURL: try chunksFixture("anthropic-text")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)

    #expect(parts.first == .streamStart(warnings: []))
    #expect(parts.contains(.textStart(id: "0")))
    let text = parts.compactMap { part -> String? in
      if case .textDelta(_, let delta, _) = part { return delta }
      return nil
    }.joined()
    #expect(text.hasPrefix("Hello"))
    guard case .finish(let usage, let reason, let metadata) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(reason.unified == .stop)
    #expect(usage.inputTokens.noCache == 12)
    #expect(metadata?["anthropic"]?["usage"]?["input_tokens"] == 12)
    #expect(client.lastRequest?.bodyJSON?["stream"] == true)
  }

  @Test func streamsToolCallWithEmptyInput() async throws {
    let client = MockHTTPClient([messagesURL: try chunksFixture("anthropic-tool-no-args")])
    let result = try await makeProvider(client)("claude-3-opus-20240229").doStream(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [.function(LanguageModelV4FunctionTool(name: "updateIssueList", inputSchema: ["type": "object"]))]))
    let parts = try await collect(result.stream)
    let call = parts.compactMap { part -> LanguageModelV4ToolCall? in
      if case .toolCall(let call) = part { return call }
      return nil
    }.first
    #expect(call?.toolName == "updateIssueList")
    #expect(call?.input == "{}")
    #expect(client.lastRequest?.bodyJSON?["tools"]?[0]?["eager_input_streaming"] == true)
  }

  @Test func streamsThinkingWithSignature() async throws {
    let client = MockHTTPClient([messagesURL: try chunksFixture("anthropic-clear-thinking.1")])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)
    #expect(parts.contains { if case .reasoningStart = $0 { true } else { false } })
    #expect(
      parts.contains { part in
        if case .reasoningDelta(_, "", let metadata) = part { return metadata?["anthropic"]?["signature"] != nil }
        return false
      })
  }

  @Test func initialStreamErrorBecomesRetryableAPICallError() async throws {
    let error = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
    let client = MockHTTPClient([messagesURL: .streamChunks(["data: \(error)\n\n"])])
    await #expect {
      _ = try await makeProvider(client)("claude-sonnet-4-5").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let error = error as? APICallError
      return error?.statusCode == 529 && error?.isRetryable == true && error?.message == "Overloaded"
    }
  }

  @Test func midStreamErrorsAreProviderStreamErrors() async throws {
    let start = #"{"type":"message_start","message":{"id":"m","model":"claude-x","usage":{"input_tokens":1}}}"#
    let error = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#
    let client = MockHTTPClient([messagesURL: .streamChunks(["data: \(start)\n\n", "data: \(error)\n\n"])])
    let result = try await makeProvider(client)("claude-sonnet-4-5").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)
    let streamError = parts.compactMap { part -> ProviderStreamError? in
      if case .error(let error) = part { return error as? ProviderStreamError }
      return nil
    }.first
    #expect(streamError?.statusCode == 429)
    #expect(streamError?.isRetryable == true)
  }
}

@Suite struct AnthropicCompatibleEndpointTests {
  @Test func deepSeekAnthropicEndpointRunsToolLoop() async throws {
    let deepseekURL = "https://api.deepseek.com/anthropic/v1/messages"
    let client = MockHTTPClient()
    client.respond(
      to: deepseekURL,
      withSequence: [
        .jsonValue([
          "id": "msg_1", "type": "message", "role": "assistant", "model": "deepseek-v4-flash",
          "content": [
            ["type": "thinking", "thinking": "Need the weather.", "signature": "sig-1"],
            ["type": "tool_use", "id": "toolu_1", "name": "weather", "input": ["city": "Beijing"]],
          ],
          "stop_reason": "tool_use", "usage": ["input_tokens": 20, "output_tokens": 10],
        ]),
        .jsonValue([
          "id": "msg_2", "type": "message", "role": "assistant", "model": "deepseek-v4-flash",
          "content": [["type": "text", "text": "It is 25°C in Beijing."]],
          "stop_reason": "end_turn", "usage": ["input_tokens": 40, "output_tokens": 8],
        ]),
      ])

    struct City: Codable, Sendable { var city: String }
    let deepseek = try makeProvider(client, baseURL: "https://api.deepseek.com/anthropic/v1", name: "deepseek.messages")
    let result = try await generateText(
      model: deepseek("deepseek-v4-flash"),
      prompt: "Weather in Beijing?",
      tools: [
        "weather": tool(inputSchema: Schema(City.self, jsonSchema: ["type": "object"])) { input, _ in
          ["city": .string(input.city), "celsius": 25] as JSONValue
        }
      ],
      maxOutputTokens: 1024,
      stopWhen: [.isStepCount(3)])

    #expect(result.text == "It is 25°C in Beijing.")
    #expect(result.steps[0].reasoningText == "Need the weather.")
    #expect(result.steps[0].providerMetadata?["deepseek"] != nil)

    let secondBody = try #require(client.requests.last?.bodyJSON)
    #expect(
      secondBody["messages"]?[1]
        == [
          "role": "assistant",
          "content": [
            ["type": "thinking", "thinking": "Need the weather.", "signature": "sig-1"],
            ["type": "tool_use", "id": "toolu_1", "name": "weather", "input": ["city": "Beijing"]],
          ],
        ])
    #expect(secondBody["messages"]?[2]?["content"]?[0]?["type"] == "tool_result")
  }
}
