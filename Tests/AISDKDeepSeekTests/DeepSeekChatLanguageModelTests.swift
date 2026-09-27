import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKDeepSeek

private let chatURL = "https://api.deepseek.com/chat/completions"
private let betaChatURL = "https://api.deepseek.com/beta/chat/completions"
private let testPrompt: LanguageModelV4Prompt = [.user([.text(LanguageModelV4TextPart(text: "Hello"))])]

private func fixture(_ name: String, _ ext: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func jsonFixture(_ name: String) throws -> MockHTTPClient.Response {
  .jsonValue(try JSONValue(jsonString: try fixture(name, "json")))
}

private func chunksFixture(_ name: String) throws -> MockHTTPClient.Response {
  let lines = try fixture(name, "chunks.txt").split(separator: "\n", omittingEmptySubsequences: false)
  return .streamChunks(lines.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"])
}

private func makeProvider(_ client: MockHTTPClient, baseURL: String? = nil) -> DeepSeekProvider {
  createDeepSeek(
    DeepSeekProviderSettings(apiKey: "test-api-key", baseURL: baseURL, httpClient: client, generateId: { "gen-id" }))
}

private func simpleResponse(model: String = "deepseek-chat", content: String = "Hello") -> MockHTTPClient.Response {
  .jsonValue([
    "id": "test-id",
    "choices": [["finish_reason": "stop", "index": 0, "message": ["content": .string(content), "role": "assistant"]]],
    "created": 0,
    "model": .string(model),
    "object": "chat.completion",
    "usage": ["completion_tokens": 1, "prompt_tokens": 1, "total_tokens": 2],
  ])
}

@Suite struct DeepSeekGenerateTests {
  @Test(arguments: ["deepseek-v4-flash", "deepseek-v4-pro"])
  func forwardsModelId(modelId: String) async throws {
    let client = MockHTTPClient([chatURL: simpleResponse(model: modelId)])
    _ = try await makeProvider(client).chat(modelId).doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.bodyJSON?["model"] == .string(modelId))
  }

  @Test func supportsHTTPImageURLs() async throws {
    let model = makeProvider(MockHTTPClient()).chat("deepseek-chat")
    #expect(try await model.supportedUrls == ["image/*": ["^https?://.*$"]])
  }

  @Test func rejectsResponseWithoutChoices() async throws {
    let client = MockHTTPClient([
      chatURL: .jsonValue(["id": "x", "object": "chat.completion", "created": 0, "model": "deepseek-chat", "choices": []])
    ])
    await #expect {
      _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      (error as? InvalidResponseDataError)?.message == "Response did not contain any choices."
    }
  }

  @Test func sendsRequestBodyAndHeaders() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-text")])
    _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.system("You are a helpful assistant."), .user([.text(LanguageModelV4TextPart(text: "Hello"))])],
        temperature: 0.5, topP: 0.3, headers: ["X-Request": "1"]))

    let request = try #require(client.lastRequest)
    #expect(
      request.bodyJSON == [
        "messages": [
          ["content": "You are a helpful assistant.", "role": "system"],
          ["content": "Hello", "role": "user"],
        ],
        "model": "deepseek-chat",
        "temperature": 0.5,
      ])
    #expect(request.headers["authorization"] == "Bearer test-api-key")
    #expect(request.headers["x-request"] == "1")
    #expect(request.headers["user-agent"]?.hasPrefix("ai-sdk/deepseek/") == true)
  }

  @Test func extractsTextUsageAndMetadata() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-text")])
    let result = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt))

    guard case .text(let text) = result.content.first else {
      Issue.record("expected text")
      return
    }
    #expect(text.text.hasPrefix("## **Holiday Name: Gratitude of Small Things Day"))
    #expect(result.finishReason == LanguageModelV4FinishReason(unified: .length, raw: "length"))
    #expect(result.usage.inputTokens == .init(total: 13, noCache: 13, cacheRead: 0, cacheWrite: nil))
    #expect(result.usage.outputTokens == .init(total: 300, text: 300, reasoning: 0))
    #expect(result.usage.raw?["prompt_cache_miss_tokens"] == 13)
    #expect(result.providerMetadata?["deepseek"]?["promptCacheMissTokens"] == 13)
    #expect(result.providerMetadata?["deepseek"]?["systemFingerprint"] == "fp_eaab8d114b_prod0820_fp8_kvcache")
    #expect(result.response?.id == "00f10ecd-60b3-4707-b5db-e4bcadf7aea1")
    #expect(result.response?.metadata.timestamp == Date(timeIntervalSince1970: 1_764_656_316))
  }

  @Test func appliesThinkingModeSamplingRules() async throws {
    let client = MockHTTPClient([chatURL: simpleResponse()])
    let result = try await makeProvider(client).chat("deepseek-v4-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, temperature: 0.2, topP: 0.4, presencePenalty: 0.6, frequencyPenalty: 0.5))

    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "deepseek-v4-flash",
        "messages": [["role": "user", "content": "Hello"]],
        "top_p": 0.4,
      ])
    #expect(result.warnings.count == 4)
    #expect(result.warnings.contains { if case .compatibility(feature: "topP", _) = $0 { true } else { false } })
    #expect(result.warnings.contains { if case .deprecated(setting: "frequencyPenalty", _) = $0 { true } else { false } })
    #expect(result.warnings.contains { if case .unsupported(feature: "temperature", _) = $0 { true } else { false } })
  }

  @Test func appliesNonThinkingSamplingRules() async throws {
    let client = MockHTTPClient([chatURL: simpleResponse()])
    _ = try await makeProvider(client).chat("deepseek-v4-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, temperature: 0.2, topP: 0.4,
        providerOptions: ["deepseek": ["thinking": ["type": "disabled"]]]))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["temperature"] == 0.2)
    #expect(body["top_p"] == nil)
    #expect(body["thinking"] == ["type": "disabled"])
  }

  @Test func mapsTopLevelReasoning() async throws {
    let client = MockHTTPClient([chatURL: simpleResponse()])
    let model = makeProvider(client).chat("deepseek-chat")

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .high))
    #expect(client.lastRequest?.bodyJSON?["thinking"] == ["type": "enabled"])
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == "high")

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: LanguageModelV4ReasoningEffort.none))
    #expect(client.lastRequest?.bodyJSON?["thinking"] == ["type": "disabled"])
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == nil)

    let xhigh = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .xhigh))
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == "max")
    #expect(xhigh.warnings.contains { if case .compatibility(feature: "reasoning", _) = $0 { true } else { false } })

    let low = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .low))
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == "low")
    #expect(low.warnings.isEmpty)

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.bodyJSON?["thinking"] == nil)
  }

  @Test func providerOptionsWinOverTopLevelReasoning() async throws {
    let client = MockHTTPClient([chatURL: simpleResponse()])
    let result = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, reasoning: .low,
        providerOptions: ["deepseek": ["thinking": ["type": "adaptive"], "reasoningEffort": "medium"]]))
    #expect(client.lastRequest?.bodyJSON?["thinking"] == ["type": "enabled"])
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == "high")
    #expect(result.warnings.count == 2)
  }

  @Test func sendsLogprobsAndUserId() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-logprobs")])
    let result = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, providerOptions: ["deepseek": ["topLogprobs": 2, "userId": "user_1"]]))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["logprobs"] == true)
    #expect(body["top_logprobs"] == 2)
    #expect(body["user_id"] == "user_1")
    #expect(result.providerMetadata?["deepseek"]?["logprobs"] != nil)
  }

  @Test func rejectsInvalidUserId() async throws {
    let client = MockHTTPClient([chatURL: simpleResponse()])
    await #expect(throws: InvalidArgumentError.self) {
      _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["deepseek": ["userId": "bad user!"]]))
    }
    #expect(client.requests.isEmpty)
  }

  @Test func extractsReasoningBeforeText() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-reasoning")])
    let result = try await makeProvider(client).chat("deepseek-reasoner").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt))
    guard case .reasoning = result.content.first, case .text = result.content.last else {
      Issue.record("expected reasoning then text, got \(result.content)")
      return
    }
  }

  @Test func sendsToolsAndExtractsToolCalls() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-tool-call")])
    let schema: JSONSchema = [
      "type": "object", "properties": ["location": ["type": "string"]], "required": ["location"],
    ]
    let result = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [.function(LanguageModelV4FunctionTool(name: "weather", inputSchema: schema))],
        toolChoice: .tool(toolName: "weather")))

    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(
      body["tools"] == [["type": "function", "function": ["name": "weather", "parameters": schema.value]]])
    #expect(body["tool_choice"] == ["type": "function", "function": ["name": "weather"]])
    #expect(result.content.contains { if case .toolCall(let call) = $0 { call.toolName == "weather" } else { false } })
    #expect(result.finishReason.unified == .toolCalls)
  }

  @Test func strictToolsRequireBetaEndpoint() async throws {
    let strictTool = LanguageModelV4Tool.function(
      LanguageModelV4FunctionTool(name: "t", inputSchema: ["type": "object"], strict: true))
    let client = MockHTTPClient([chatURL: simpleResponse(), betaChatURL: simpleResponse()])

    await #expect(throws: UnsupportedFunctionalityError.self) {
      _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, tools: [strictTool]))
    }
    #expect(client.requests.isEmpty)

    _ = try await makeProvider(client, baseURL: "https://api.deepseek.com/beta").chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, tools: [strictTool]))
    #expect(client.lastRequest?.url.absoluteString == betaChatURL)
    #expect(client.lastRequest?.bodyJSON?["tools"]?[0]?["function"]?["strict"] == true)

    let mixed = LanguageModelV4Tool.function(LanguageModelV4FunctionTool(name: "u", inputSchema: ["type": "object"]))
    await #expect(throws: UnsupportedFunctionalityError.self) {
      _ = try await makeProvider(client, baseURL: "https://api.deepseek.com/beta").chat("deepseek-chat").doStream(
        LanguageModelV4CallOptions(prompt: testPrompt, tools: [strictTool, mixed]))
    }
  }

  @Test func jsonResponseFormatInjectsSchema() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("deepseek-json")])
    let schema: JSONSchema = ["type": "object", "properties": ["name": ["type": "string"]]]
    let result = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: schema)))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["response_format"] == ["type": "json_object"])
    #expect(
      body["messages"]?[0]
        == [
          "role": "system",
          "content": .string("Return JSON that conforms to the following schema: \(schema.value.jsonString())"),
        ])
    #expect(result.warnings.contains { if case .compatibility(feature: "responseFormat JSON schema", _) = $0 { true } else { false } })

    _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json()))
    #expect(client.lastRequest?.bodyJSON?["messages"]?[0] == ["role": "system", "content": "Return JSON."])
  }

  @Test func assistantPrefixCompletionRequiresBeta() async throws {
    let prompt: LanguageModelV4Prompt = [
      .user([.text(LanguageModelV4TextPart(text: "Write code"))]),
      .assistant(
        [.text(LanguageModelV4TextPart(text: "```python\n"))],
        providerOptions: ["deepseek": ["prefix": true, "name": "coder"]]),
    ]
    let client = MockHTTPClient([chatURL: simpleResponse(), betaChatURL: simpleResponse()])
    await #expect(throws: UnsupportedFunctionalityError.self) {
      _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(LanguageModelV4CallOptions(prompt: prompt))
    }
    _ = try await makeProvider(client, baseURL: "https://api.deepseek.com/beta").chat("deepseek-chat").doGenerate(
      LanguageModelV4CallOptions(prompt: prompt))
    #expect(
      client.lastRequest?.bodyJSON?["messages"]?[1]
        == ["role": "assistant", "content": "```python\n", "name": "coder", "prefix": true])
  }

  @Test func apiErrorsBecomeAPICallErrors() async throws {
    let client = MockHTTPClient([
      chatURL: .error(statusCode: 401, body: #"{"error":{"message":"Authentication Fails","type":"authentication_error"}}"#)
    ])
    await #expect {
      _ = try await makeProvider(client).chat("deepseek-chat").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let error = error as? APICallError
      return error?.message == "Authentication Fails" && error?.statusCode == 401 && error?.isRetryable == false
    }
  }

  @Test func missingAPIKeyThrows() async throws {
    let provider = createDeepSeek(DeepSeekProviderSettings(httpClient: MockHTTPClient()))
    guard ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] == nil else { return }
    await #expect(throws: LoadAPIKeyError.self) {
      _ = try await provider.chat("deepseek-chat").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    }
  }
}

@Suite struct DeepSeekStreamTests {
  @Test func streamsText() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("deepseek-text")])
    let result = try await makeProvider(client).chat("deepseek-chat").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)

    #expect(parts.first == .streamStart(warnings: []))
    guard case .responseMetadata(let metadata) = parts[1] else {
      Issue.record("expected response metadata")
      return
    }
    #expect(metadata.modelId == "deepseek-chat")
    #expect(parts[2] == .textStart(id: "txt-0"))

    let text = parts.compactMap { part -> String? in
      if case .textDelta(_, let delta, _) = part { return delta }
      return nil
    }.joined()
    #expect(!text.isEmpty)

    guard case .finish(let usage, let finishReason, let providerMetadata) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(parts[parts.count - 2] == .textEnd(id: "txt-0"))
    #expect(usage.inputTokens.total != nil)
    #expect(finishReason.raw != nil)
    #expect(providerMetadata?["deepseek"]?["responseObject"] == "chat.completion.chunk")

    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["stream"] == true)
    #expect(body["stream_options"] == ["include_usage": true])
  }

  @Test func streamsReasoningThenToolCall() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("deepseek-tool-call")])
    let result = try await makeProvider(client).chat("deepseek-reasoner").doStream(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [.function(LanguageModelV4FunctionTool(name: "weather", inputSchema: ["type": "object"]))],
        providerOptions: ["deepseek": ["thinking": ["type": "enabled"]]]))
    let parts = try await collect(result.stream)

    let reasoning = parts.compactMap { part -> String? in
      if case .reasoningDelta(_, let delta, _) = part { return delta }
      return nil
    }.joined()
    #expect(reasoning.hasPrefix("The user is asking for the weather in San"))
    #expect(parts.contains(.reasoningEnd(id: "reasoning-0")))

    let toolCall = parts.compactMap { part -> LanguageModelV4ToolCall? in
      if case .toolCall(let call) = part { return call }
      return nil
    }.first
    #expect(toolCall?.toolName == "weather")
    #expect(toolCall?.input == #"{"location": "San Francisco"}"#)

    guard case .finish(let usage, let finishReason, let metadata) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(finishReason == LanguageModelV4FinishReason(unified: .toolCalls, raw: "tool_calls"))
    #expect(usage.inputTokens == .init(total: 339, noCache: 19, cacheRead: 320, cacheWrite: nil))
    #expect(usage.outputTokens == .init(total: 83, text: 44, reasoning: 39))
    #expect(metadata?["deepseek"]?["toolCallTypes"] == ["function"])
  }

  @Test func streamsLogprobs() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("deepseek-logprobs")])
    let result = try await makeProvider(client).chat("deepseek-chat").doStream(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["deepseek": ["logprobs": true]]))
    let parts = try await collect(result.stream)
    guard case .finish(_, _, let metadata) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(metadata?["deepseek"]?["logprobs"]?["content"]?.arrayValue?.isEmpty == false)
  }

  @Test(arguments: [
    ("rate_limit_error", JSONValue.string("rate_limit_exceeded"), 429, true),
    ("rate_limit_error", JSONValue.string("insufficient_quota"), 429, false),
    ("rate_limit_error", JSONValue.string("429"), 429, true),
    ("invalid_request_error", JSONValue.null, 400, false),
  ])
  func classifiesStreamErrors(type: String, code: JSONValue, statusCode: Int, retryable: Bool) async throws {
    let data: JSONValue = ["error": ["message": "Rate limit reached", "type": .string(type), "code": code]]
    let client = MockHTTPClient([chatURL: .streamChunks(["data: \(data.jsonString())\n\n", "data: [DONE]\n\n"])])
    let result = try await makeProvider(client).chat("deepseek-chat").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    let parts = try await collect(result.stream)

    let error = parts.compactMap { part -> ProviderStreamError? in
      if case .error(let error) = part { return error as? ProviderStreamError }
      return nil
    }.first
    #expect(error?.message == "Rate limit reached")
    #expect(error?.type == type)
    #expect(error?.statusCode == statusCode)
    #expect(error?.isRetryable == retryable)
    #expect(error?.data == data)
    guard case .finish(_, let finishReason, _) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(finishReason.unified == .error)
  }

  @Test func includesRawChunksWhenRequested() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("deepseek-text")])
    let result = try await makeProvider(client).chat("deepseek-chat").doStream(
      LanguageModelV4CallOptions(prompt: testPrompt, includeRawChunks: true))
    let parts = try await collect(result.stream)
    #expect(parts.contains { if case .raw = $0 { true } else { false } })
  }
}

@Suite struct DeepSeekMessageConversionTests {
  @Test func dropsOldReasoningForNonV4Models() throws {
    let prompt: LanguageModelV4Prompt = [
      .user([.text(LanguageModelV4TextPart(text: "q1"))]),
      .assistant([.reasoning(LanguageModelV4ReasoningPart(text: "old")), .text(LanguageModelV4TextPart(text: "a1"))]),
      .user([.text(LanguageModelV4TextPart(text: "q2"))]),
    ]
    let chat = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-chat")
    #expect(chat.messages[1] == ["role": "assistant", "content": "a1"])

    let v4 = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-v4-flash")
    #expect(v4.messages[1] == ["role": "assistant", "content": "a1", "reasoning_content": "old"])
  }

  @Test func keepsReasoningDuringToolLoopAndAddsEmptyReasoningForV4() throws {
    let prompt: LanguageModelV4Prompt = [
      .user([.text(LanguageModelV4TextPart(text: "q"))]),
      .assistant([
        .reasoning(LanguageModelV4ReasoningPart(text: "think")),
        .toolCall(LanguageModelV4ToolCallPart(toolCallId: "c1", toolName: "weather", input: ["city": "SF"])),
      ]),
      .tool([.toolResult(LanguageModelV4ToolResultPart(toolCallId: "c1", toolName: "weather", output: .json(["t": 20])))]),
      .assistant([.text(LanguageModelV4TextPart(text: "done"))]),
    ]
    let chat = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-reasoner")
    #expect(
      chat.messages[1]
        == [
          "role": "assistant", "content": "", "reasoning_content": "think",
          "tool_calls": [["id": "c1", "type": "function", "function": ["name": "weather", "arguments": #"{"city":"SF"}"#]]],
        ])
    #expect(chat.messages[2] == ["role": "tool", "tool_call_id": "c1", "content": #"{"t":20}"#])

    let v4 = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-v4-pro")
    #expect(v4.messages[3] == ["role": "assistant", "content": "done", "reasoning_content": ""])
  }

  @Test func convertsImages() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
    let prompt: LanguageModelV4Prompt = [
      .user([
        .text(LanguageModelV4TextPart(text: "what is this?")),
        .file(LanguageModelV4FilePart(data: .data(png), mediaType: "image")),
        .file(
          LanguageModelV4FilePart(
            data: .url(URL(string: "https://x.dev/a.jpg")!), mediaType: "image/jpeg",
            providerOptions: ["deepseek": ["imageDetail": "low"]])),
      ])
    ]
    let result = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-v4-flash-vision-exp")
    #expect(
      result.messages[0]
        == [
          "role": "user",
          "content": [
            ["type": "text", "text": "what is this?"],
            ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(png.base64EncodedString())")]],
            ["type": "image_url", "image_url": ["url": "https://x.dev/a.jpg", "detail": "low"]],
          ],
        ])
  }

  @Test func rejectsUnsupportedImageTypes() {
    let prompt: LanguageModelV4Prompt = [
      .user([.file(LanguageModelV4FilePart(data: .url(URL(string: "https://x.dev/a.bmp")!), mediaType: "image/bmp"))])
    ]
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-chat")
    }
  }

  @Test func deniedToolCallsUseReason() throws {
    let prompt: LanguageModelV4Prompt = [
      .tool([
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "c", toolName: "t", output: .executionDenied())),
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "d", toolName: "t", output: .errorText("boom"))),
      ])
    ]
    let result = try convertToDeepSeekChatMessages(prompt: prompt, responseFormat: nil, modelId: "deepseek-chat")
    #expect(result.messages[0]["content"] == "Tool call execution denied.")
    #expect(result.messages[1]["content"] == "boom")
  }
}

@Suite struct DeepSeekEndToEndTests {
  @Test func streamTextReplaysRecordedReasoningStream() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("deepseek-reasoning")])
    let result = streamText(model: makeProvider(client)("deepseek-reasoner"), prompt: "Hello")

    let deltas = try await collect(result.textStream)
    #expect(!deltas.isEmpty)
    #expect(try await result.text == deltas.joined())
    #expect(try await result.reasoningText?.isEmpty == false)
    #expect(try await result.usage.inputTokens != nil)
    #expect(try await result.response.modelId == "deepseek-reasoner")
  }

  @Test func generateTextRunsToolLoopAgainstRecordedResponses() async throws {
    let client = MockHTTPClient()
    client.respond(
      to: chatURL,
      withSequence: [
        .jsonValue([
          "id": "r1", "object": "chat.completion", "created": 0, "model": "deepseek-v4-flash",
          "choices": [
            [
              "index": 0, "finish_reason": "tool_calls",
              "message": [
                "role": "assistant", "content": "", "reasoning_content": "Need weather.",
                "tool_calls": [
                  ["id": "call_1", "type": "function", "function": ["name": "weather", "arguments": #"{"city":"Beijing"}"#]]
                ],
              ],
            ]
          ],
          "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15],
        ]),
        simpleResponse(model: "deepseek-v4-flash", content: "Beijing is 25°C."),
      ])

    struct City: Codable, Sendable { var city: String }
    let deepseek = makeProvider(client)
    let result = try await generateText(
      model: deepseek("deepseek-v4-flash"),
      prompt: "What's the weather in Beijing?",
      tools: [
        "weather": tool(
          description: "Get the weather", inputSchema: Schema(City.self, jsonSchema: ["type": "object"])
        ) { input, _ in ["city": .string(input.city), "celsius": 25] as JSONValue }
      ],
      stopWhen: [.isStepCount(3)])

    #expect(result.text == "Beijing is 25°C.")
    #expect(result.steps.count == 2)
    #expect(result.steps[0].reasoningText == "Need weather.")

    let secondBody = try #require(client.requests.last?.bodyJSON)
    #expect(
      secondBody["messages"]?[1]
        == [
          "role": "assistant", "content": "", "reasoning_content": "Need weather.",
          "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "weather", "arguments": #"{"city":"Beijing"}"#]]],
        ])
    #expect(secondBody["messages"]?[2] == ["role": "tool", "tool_call_id": "call_1", "content": #"{"celsius":25,"city":"Beijing"}"#])
  }
}
