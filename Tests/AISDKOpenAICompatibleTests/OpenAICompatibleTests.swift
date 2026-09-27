import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKOpenAICompatible

private let baseURL = "https://my.api.com/v1"
private let chatURL = "\(baseURL)/chat/completions"
private let completionURL = "\(baseURL)/completions"
private let embeddingURL = "\(baseURL)/embeddings"
private let testPrompt: LanguageModelV4Prompt = [.user([.text(LanguageModelV4TextPart(text: "Hello"))])]

private func makeProvider(
  _ client: MockHTTPClient, name: String = "test-provider", includeUsage: Bool = false,
  supportsStructuredOutputs: Bool = false, queryParams: [String: String]? = nil,
  transformRequestBody: (@Sendable (JSONObject) -> JSONObject)? = nil,
  metadataExtractor: (any OpenAICompatibleMetadataExtractor)? = nil
) -> OpenAICompatibleProvider {
  createOpenAICompatible(
    OpenAICompatibleProviderSettings(
      baseURL: baseURL + "/", name: name, apiKey: "test-api-key", headers: ["Custom-Provider-Header": "provider"],
      queryParams: queryParams, httpClient: client, includeUsage: includeUsage,
      supportsStructuredOutputs: supportsStructuredOutputs, transformRequestBody: transformRequestBody,
      metadataExtractor: metadataExtractor))
}

private func chatResponse(
  content: JSONValue = "", reasoningContent: String? = nil, reasoning: String? = nil, toolCalls: [JSONValue]? = nil,
  finishReason: String = "stop", usage: JSONValue = ["prompt_tokens": 4, "total_tokens": 34, "completion_tokens": 30]
) -> MockHTTPClient.Response {
  .jsonValue([
    "id": "chatcmpl-95ZTZkhr0mHNKqerQfiwkuox3PHAd",
    "object": "chat.completion",
    "created": 1_711_115_037,
    "model": "grok-beta",
    "choices": [
      [
        "index": 0,
        "message": jsonObject([
          "role": "assistant", "content": content, "reasoning_content": .optional(reasoningContent),
          "reasoning": .optional(reasoning), "tool_calls": toolCalls.map(JSONValue.array),
        ]),
        "finish_reason": .string(finishReason),
      ]
    ],
    "usage": usage,
  ])
}

private func sse(_ chunks: [JSONValue]) -> MockHTTPClient.Response {
  .streamChunks(chunks.map { "data: \($0.jsonString())\n\n" } + ["data: [DONE]\n\n"])
}

private func chunk(_ delta: JSONValue, finishReason: String? = nil, usage: JSONValue? = nil) -> JSONValue {
  jsonObject([
    "id": "chatcmpl-e7f8e220-656c-4455-a132-dacfc1370798", "object": "chat.completion.chunk", "created": 1_711_357_598,
    "model": "grok-beta",
    "choices": [jsonObject(["index": 0, "delta": delta, "finish_reason": .optional(finishReason)])],
    "usage": usage,
  ])
}

private func parts(_ result: LanguageModelV4StreamResult) async throws -> [LanguageModelV4StreamPart] {
  try await collect(result.stream)
}

@Suite struct OpenAICompatibleChatGenerateTests {
  @Test func extractsTextReasoningUsageAndMetadata() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "Hello, World!", reasoningContent: "Think")])
    let result = try await makeProvider(client)("grok-beta").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(
      result.content == [.text(LanguageModelV4Text(text: "Hello, World!")), .reasoning(LanguageModelV4Reasoning(text: "Think"))])
    #expect(result.usage.inputTokens == .init(total: 4, noCache: 4, cacheRead: 0))
    #expect(result.usage.outputTokens == .init(total: 30, text: 30, reasoning: 0))
    #expect(result.finishReason == LanguageModelV4FinishReason(unified: .stop, raw: "stop"))
    #expect(result.response?.metadata.id == "chatcmpl-95ZTZkhr0mHNKqerQfiwkuox3PHAd")
    #expect(result.response?.metadata.modelId == "grok-beta")
    #expect(result.providerMetadata == ["test-provider": [:]])
  }

  @Test func acceptsReasoningFieldAndContentArrays() async throws {
    let client = MockHTTPClient([
      chatURL: chatResponse(
        content: [
          ["type": "thinking", "thinking": [["type": "text", "text": "Let me "], ["type": "text", "text": "think"]]],
          ["type": "text", "text": "Answer"],
        ], reasoning: "gpt-oss reasoning")
    ])
    let result = try await makeProvider(client)("m").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(
      result.content == [
        .reasoning(LanguageModelV4Reasoning(text: "Let me think")), .text(LanguageModelV4Text(text: "Answer")),
        .reasoning(LanguageModelV4Reasoning(text: "gpt-oss reasoning")),
      ])
  }

  @Test func extractsCachedAndReasoningTokens() async throws {
    let client = MockHTTPClient([
      chatURL: chatResponse(
        content: "x",
        usage: [
          "prompt_tokens": 20, "completion_tokens": 30, "total_tokens": 50,
          "prompt_tokens_details": ["cached_tokens": 5],
          "completion_tokens_details": [
            "reasoning_tokens": 10, "accepted_prediction_tokens": 3, "rejected_prediction_tokens": 1,
          ],
        ])
    ])
    let result = try await makeProvider(client)("m").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(result.usage.inputTokens == .init(total: 20, noCache: 15, cacheRead: 5))
    #expect(result.usage.outputTokens == .init(total: 30, text: 20, reasoning: 10))
    #expect(result.providerMetadata == ["test-provider": ["acceptedPredictionTokens": 3, "rejectedPredictionTokens": 1]])
  }

  @Test func sendsSettingsHeadersAndPassthroughOptions() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "x")])
    let result = try await makeProvider(client)("grok-beta").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.system("Be brief."), .user([.text(LanguageModelV4TextPart(text: "Hello"))])],
        maxOutputTokens: 100, temperature: 0.5, stopSequences: ["END"], topP: 0.9, topK: 3, presencePenalty: 0.1,
        frequencyPenalty: 0.2, seed: 7, headers: ["Custom-Request-Header": "request"],
        providerOptions: ["testProvider": ["user": "u1", "reasoningEffort": "low", "someCustomOption": "v"]]))
    let request = try #require(client.lastRequest)
    #expect(
      request.bodyJSON == [
        "model": "grok-beta",
        "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hello"]],
        "max_tokens": 100, "temperature": 0.5, "top_p": 0.9, "frequency_penalty": 0.2, "presence_penalty": 0.1,
        "stop": ["END"], "seed": 7, "user": "u1", "reasoning_effort": "low", "someCustomOption": "v",
      ])
    #expect(request.headers["authorization"] == "Bearer test-api-key")
    #expect(request.headers["custom-provider-header"] == "provider")
    #expect(request.headers["custom-request-header"] == "request")
    #expect(request.headers["user-agent"]?.hasPrefix("ai-sdk/openai-compatible/") == true)
    #expect(result.warnings == [.unsupported(feature: "topK")])
    #expect(result.providerMetadata?.keys.sorted() == ["testProvider"])
  }

  @Test func warnsOnDeprecatedProviderOptionKeys() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "x")])
    let result = try await makeProvider(client)("m").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        providerOptions: ["openai-compatible": ["user": "a"], "test-provider": ["textVerbosity": "low"]]))
    #expect(client.lastRequest?.bodyJSON?["user"] == "a")
    #expect(client.lastRequest?.bodyJSON?["verbosity"] == "low")
    #expect(
      result.warnings == [
        .deprecated(setting: "providerOptions key 'openai-compatible'", message: "Use 'openaiCompatible' instead."),
        .deprecated(setting: "providerOptions key 'test-provider'", message: "Use 'testProvider' instead."),
      ])
  }

  @Test func mapsReasoningSettingToReasoningEffort() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "x")])
    _ = try await makeProvider(client)("m").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .high))
    #expect(client.lastRequest?.bodyJSON?["reasoning_effort"] == "high")
  }

  @Test func sendsJsonObjectWithoutStructuredOutputs() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "{}")])
    let schema = JSONSchema(["type": "object", "properties": ["value": ["type": "string"]]])
    let result = try await makeProvider(client)("m").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: schema)))
    #expect(client.lastRequest?.bodyJSON?["response_format"] == ["type": "json_object"])
    #expect(
      result.warnings == [
        .unsupported(feature: "responseFormat", details: "JSON response format schema is only supported with structuredOutputs")
      ])
  }

  @Test func sendsJsonSchemaWithStructuredOutputs() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "{}")])
    let schema = JSONSchema(["type": "object"])
    let result = try await makeProvider(client, supportsStructuredOutputs: true)("m").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, responseFormat: .json(schema: schema, name: "test-name", description: "desc"),
        providerOptions: ["testProvider": ["strictJsonSchema": false]]))
    #expect(
      client.lastRequest?.bodyJSON?["response_format"] == [
        "type": "json_schema",
        "json_schema": ["schema": ["type": "object"], "strict": false, "name": "test-name", "description": "desc"],
      ])
    #expect(result.warnings.isEmpty)
  }

  @Test func sendsToolsAndParsesToolCalls() async throws {
    let client = MockHTTPClient([
      chatURL: chatResponse(
        content: .null,
        toolCalls: [
          [
            "id": "call_O17Uplv4lJvD6DVdIvFFeRMw", "type": "function",
            "function": ["name": "test-tool", "arguments": "{\"value\":\"Spark\"}"],
            "extra_content": ["google": ["thought_signature": "sig"]],
          ],
          ["id": "", "type": "function", "function": ["name": "other", "arguments": "{}"]],
        ], finishReason: "tool_calls")
    ])
    let result = try await makeProvider(client)("m").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [
          .function(
            LanguageModelV4FunctionTool(
              name: "test-tool",
              inputSchema: JSONSchema(["type": "object", "properties": ["value": ["type": "string"]]]), strict: true)),
          .provider(LanguageModelV4ProviderTool(id: "openai.web_search", name: "web_search", args: [:])),
        ],
        toolChoice: .tool(toolName: "test-tool")))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(
      body["tools"] == [
        [
          "type": "function",
          "function": [
            "name": "test-tool", "parameters": ["type": "object", "properties": ["value": ["type": "string"]]],
            "strict": true,
          ],
        ]
      ])
    #expect(body["tool_choice"] == ["type": "function", "function": ["name": "test-tool"]])
    #expect(result.warnings == [.unsupported(feature: "provider-defined tool openai.web_search")])
    #expect(result.finishReason.unified == .toolCalls)
    guard case .toolCall(let call) = result.content.first, case .toolCall(let second) = result.content.last else {
      Issue.record("expected tool calls")
      return
    }
    #expect(call.toolCallId == "call_O17Uplv4lJvD6DVdIvFFeRMw")
    #expect(call.input == "{\"value\":\"Spark\"}")
    #expect(call.providerMetadata == ["test-provider": ["thoughtSignature": "sig"]])
    #expect(!second.toolCallId.isEmpty)
  }

  @Test func appliesTransformRequestBodyAndMetadataExtractor() async throws {
    struct Extractor: OpenAICompatibleMetadataExtractor {
      func extractMetadata(parsedBody: JSONValue) async throws -> SharedV4ProviderMetadata? {
        ["test-provider": ["model": parsedBody["model"] ?? .null]]
      }
      func createStreamExtractor() -> any OpenAICompatibleStreamMetadataExtractor { StreamExtractor() }
    }
    final class StreamExtractor: OpenAICompatibleStreamMetadataExtractor {
      var count = 0
      func processChunk(_ parsedChunk: JSONValue) { count += 1 }
      func buildMetadata() -> SharedV4ProviderMetadata? { ["test-provider": ["chunks": .number(Double(count))]] }
    }

    let client = MockHTTPClient([chatURL: chatResponse(content: "x")])
    let provider = makeProvider(
      client,
      transformRequestBody: { body in
        var body = body
        body["extra"] = true
        return body
      }, metadataExtractor: Extractor())
    let result = try await provider("m").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.bodyJSON?["extra"] == true)
    #expect(result.providerMetadata == ["test-provider": ["model": "grok-beta"]])

    client.respond(to: chatURL, with: sse([chunk(["content": "a"]), chunk([:], finishReason: "stop")]))
    let streamed = try await parts(try await provider("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    guard case .finish(_, _, let metadata)? = streamed.last else {
      Issue.record("missing finish")
      return
    }
    #expect(metadata == ["test-provider": ["chunks": 2]])
  }

  @Test func appendsQueryParams() async throws {
    let client = MockHTTPClient(["\(chatURL)?api-version=2025": chatResponse(content: "x")])
    _ = try await makeProvider(client, queryParams: ["api-version": "2025"])("m").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.url.absoluteString == "\(chatURL)?api-version=2025")
  }

  @Test func surfacesAPIErrors() async throws {
    let client = MockHTTPClient([
      chatURL: .error(
        statusCode: 429, body: #"{"error":{"message":"Rate limited","type":"rate_limit","code":429}}"#)
    ])
    await #expect {
      _ = try await makeProvider(client)("m").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let apiError = error as? APICallError
      return apiError?.message == "Rate limited" && apiError?.statusCode == 429 && apiError?.isRetryable == true
    }
  }
}

@Suite struct OpenAICompatibleChatStreamTests {
  @Test func streamsReasoningThenText() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        chunk(["role": "assistant", "content": ""]),
        chunk(["reasoning_content": "Let me"]),
        chunk(["reasoning_content": " think"]),
        chunk(["content": "Hello"]),
        chunk(["content": ", world"]),
        chunk([:], finishReason: "stop", usage: ["prompt_tokens": 18, "completion_tokens": 439, "total_tokens": 457]),
      ])
    ])
    let result = try await makeProvider(client, includeUsage: true)("grok-beta").doStream(
      LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.bodyJSON?["stream"] == true)
    #expect(client.lastRequest?.bodyJSON?["stream_options"] == ["include_usage": true])
    let streamed = try await parts(result)
    #expect(Array(streamed.dropFirst(2).dropLast()) == [
      .reasoningStart(id: "reasoning-0"),
      .reasoningDelta(id: "reasoning-0", delta: "Let me"),
      .reasoningDelta(id: "reasoning-0", delta: " think"),
      .reasoningEnd(id: "reasoning-0"),
      .textStart(id: "txt-0"),
      .textDelta(id: "txt-0", delta: "Hello"),
      .textDelta(id: "txt-0", delta: ", world"),
      .textEnd(id: "txt-0"),
    ])
    guard case .finish(let usage, let finishReason, let metadata)? = streamed.last else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason == LanguageModelV4FinishReason(unified: .stop, raw: "stop"))
    #expect(usage.inputTokens.total == 18)
    #expect(usage.outputTokens.total == 439)
    #expect(metadata == ["test-provider": [:]])
  }

  @Test func omitsStreamOptionsByDefault() async throws {
    let client = MockHTTPClient([chatURL: sse([chunk(["content": "x"], finishReason: "stop")])])
    _ = try await parts(try await makeProvider(client)("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    #expect(client.lastRequest?.bodyJSON?["stream_options"] == nil)
  }

  @Test func streamsToolCallDeltas() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        chunk([
          "role": "assistant", "content": .null,
          "tool_calls": [
            [
              "index": 0, "id": "call_O17Uplv4lJvD6DVdIvFFeRMw", "type": "function",
              "function": ["name": "test-tool", "arguments": ""],
            ]
          ],
        ]),
        chunk(["tool_calls": [["index": 0, "function": ["arguments": "{\""]]]]),
        chunk(["tool_calls": [["index": 0, "function": ["arguments": "value\":\"Spark\"}"]]]]),
        chunk([:], finishReason: "tool_calls"),
      ])
    ])
    let streamed = try await parts(try await makeProvider(client)("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    let id = "call_O17Uplv4lJvD6DVdIvFFeRMw"
    #expect(Array(streamed.dropFirst(2).dropLast()) == [
      .toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: "test-tool")),
      .toolInputDelta(id: id, delta: "{\""),
      .toolInputDelta(id: id, delta: "value\":\"Spark\"}"),
      .toolInputEnd(id: id),
      .toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: "test-tool", input: "{\"value\":\"Spark\"}")),
    ])
  }

  @Test func buffersToolCallDeltasUntilNameArrives() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        chunk(["tool_calls": [["index": 0, "id": "call_1", "function": ["arguments": "{\"a\":"]]]]),
        chunk(["tool_calls": [["index": 0, "function": ["name": "lookup", "arguments": "1}"]]]]),
        chunk([:], finishReason: "tool_calls"),
      ])
    ])
    let streamed = try await parts(try await makeProvider(client)("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    #expect(streamed.contains(.toolCall(LanguageModelV4ToolCall(toolCallId: "call_1", toolName: "lookup", input: "{\"a\":1}"))))
  }

  @Test func reportsErrorChunksAndMissingFinishReason() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        chunk(["content": "partial"]),
        ["error": ["message": "Overloaded", "type": "server_error", "code": "overloaded"]],
      ])
    ])
    let streamed = try await parts(try await makeProvider(client)("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    let errors = streamed.compactMap { part -> String? in
      if case .error(let error) = part { return getErrorMessage(error) }
      return nil
    }
    #expect(errors.count == 1)
    #expect(errors.first?.contains("Overloaded") == true)
    guard case .finish(_, let finishReason, _)? = streamed.last else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason.unified == .error)

    client.respond(to: chatURL, with: sse([chunk(["content": "no finish"])]))
    let unfinished = try await parts(try await makeProvider(client)("m").doStream(LanguageModelV4CallOptions(prompt: testPrompt)))
    #expect(unfinished.contains { part in
      if case .error(let error) = part {
        return (error as? InvalidResponseDataError)?.message == "Response stream ended without a finish reason."
      }
      return false
    })
  }

  @Test func worksWithStreamText() async throws {
    let client = MockHTTPClient([
      chatURL: sse([chunk(["content": "Hi"]), chunk(["content": " there"]), chunk([:], finishReason: "stop")])
    ])
    let result = streamText(model: makeProvider(client)("m"), prompt: "Hello")
    #expect(try await result.text == "Hi there")
  }
}

@Suite struct OpenAICompatibleMessageTests {
  @Test func convertsUserFileParts() throws {
    let messages = try convertToOpenAICompatibleChatMessages([
      .user([
        .text(LanguageModelV4TextPart(text: "Look")),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "image/png")),
        .file(LanguageModelV4FilePart(data: .url(URL(string: "https://example.com/a.jpg")!), mediaType: "image/jpeg")),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "audio/mpeg")),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "application/pdf", filename: "doc.pdf")),
        .file(LanguageModelV4FilePart(data: .base64("aGVsbG8="), mediaType: "text/plain")),
      ])
    ])
    #expect(
      messages == [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": "Look"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAECAw=="]],
            ["type": "image_url", "image_url": ["url": "https://example.com/a.jpg"]],
            ["type": "input_audio", "input_audio": ["data": "AAECAw==", "format": "mp3"]],
            ["type": "file", "file": ["filename": "doc.pdf", "file_data": "data:application/pdf;base64,AAECAw=="]],
            ["type": "text", "text": "hello"],
          ],
        ]
      ])
  }

  @Test func rejectsUnsupportedFiles() {
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToOpenAICompatibleChatMessages([
        .user([.file(LanguageModelV4FilePart(data: .url(URL(string: "https://x.com/a.wav")!), mediaType: "audio/wav"))])
      ])
    }
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToOpenAICompatibleChatMessages([
        .user([.file(LanguageModelV4FilePart(data: .base64("AA=="), mediaType: "application/zip"))])
      ])
    }
  }

  @Test func convertsAssistantToolCallsAndResults() throws {
    let messages = try convertToOpenAICompatibleChatMessages([
      .assistant([
        .reasoning(LanguageModelV4ReasoningPart(text: "plan")),
        .toolCall(
          LanguageModelV4ToolCallPart(
            toolCallId: "call-1", toolName: "search", input: ["q": "swift"],
            providerOptions: ["google": ["thoughtSignature": "sig"]])),
      ]),
      .tool([
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "call-1", toolName: "search", output: .json(["hits": 3]))),
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "call-2", toolName: "x", output: .executionDenied())),
      ]),
      .assistant([.text(LanguageModelV4TextPart(text: "Done"))], providerOptions: ["openaiCompatible": ["name": "bot"]]),
    ])
    #expect(
      messages == [
        [
          "role": "assistant", "content": .null, "reasoning_content": "plan",
          "tool_calls": [
            [
              "id": "call-1", "type": "function", "function": ["name": "search", "arguments": "{\"q\":\"swift\"}"],
              "extra_content": ["google": ["thought_signature": "sig"]],
            ]
          ],
        ],
        ["role": "tool", "tool_call_id": "call-1", "content": "{\"hits\":3}"],
        ["role": "tool", "tool_call_id": "call-2", "content": "Tool call execution denied."],
        ["role": "assistant", "content": "Done", "name": "bot"],
      ])
  }

  @Test func camelCasesProviderNames() {
    #expect(toCamelCase("test-provider") == "testProvider")
    #expect(toCamelCase("my_provider_x") == "myProviderX")
    #expect(toCamelCase("a__b") == "a_B")
    #expect(toCamelCase("already") == "already")
  }
}

@Suite struct OpenAICompatibleCompletionTests {
  static func response(_ text: String = "Hello") -> MockHTTPClient.Response {
    .jsonValue([
      "id": "cmpl-96cAM1v77r4jXa4qb2NSmRREV5oWB", "object": "text_completion", "created": 1_711_363_706,
      "model": "gpt-3.5-turbo-instruct",
      "choices": [["text": .string(text), "index": 0, "finish_reason": "stop"]],
      "usage": ["prompt_tokens": 4, "total_tokens": 34, "completion_tokens": 30],
    ])
  }

  @Test func rendersPromptAndStopSequences() async throws {
    let client = MockHTTPClient([completionURL: Self.response()])
    let result = try await makeProvider(client).completionModel("gpt-3.5-turbo-instruct").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [
          .system("Be nice."), .user([.text(LanguageModelV4TextPart(text: "Hi"))]),
          .assistant([.text(LanguageModelV4TextPart(text: "Hello"))]), .user([.text(LanguageModelV4TextPart(text: "Bye"))]),
        ], stopSequences: ["STOP"], providerOptions: ["testProvider": ["echo": true, "suffix": "!", "logitBias": ["50256": -100]]]))
    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "gpt-3.5-turbo-instruct",
        "prompt": "Be nice.\n\nuser:\nHi\n\nassistant:\nHello\n\nuser:\nBye\n\nassistant:\n",
        "stop": ["\nuser:", "STOP"], "echo": true, "suffix": "!", "logit_bias": ["50256": -100],
        "logitBias": ["50256": -100],
      ])
    #expect(result.content == [.text(LanguageModelV4Text(text: "Hello"))])
    #expect(result.usage.inputTokens == .init(total: 4, noCache: 4))
    #expect(result.usage.outputTokens == .init(total: 30, text: 30))
  }

  @Test func warnsOnUnsupportedSettings() async throws {
    let client = MockHTTPClient([completionURL: Self.response()])
    let result = try await makeProvider(client).completionModel("m").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, topK: 1, responseFormat: .json(schema: nil),
        tools: [.function(LanguageModelV4FunctionTool(name: "t", inputSchema: JSONSchema(["type": "object"])))],
        toolChoice: .auto))
    #expect(
      result.warnings == [
        .unsupported(feature: "topK"), .unsupported(feature: "tools"), .unsupported(feature: "toolChoice"),
        .unsupported(feature: "responseFormat", details: "JSON response format is not supported."),
      ])
  }

  @Test func rejectsToolMessages() {
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToOpenAICompatibleCompletionPrompt([
        .tool([.toolResult(LanguageModelV4ToolResultPart(toolCallId: "1", toolName: "t", output: .text("x")))])
      ])
    }
  }

  @Test func streamsText() async throws {
    let chunks: [JSONValue] = [
      ["id": "c1", "created": 1_711_363_440, "model": "m", "choices": [["text": "Hello", "index": 0, "finish_reason": .null]]],
      ["id": "c1", "created": 1_711_363_440, "model": "m", "choices": [["text": ", World!", "index": 0, "finish_reason": "stop"]]],
      ["id": "c1", "created": 1_711_363_440, "model": "m", "choices": [], "usage": ["prompt_tokens": 10, "completion_tokens": 362, "total_tokens": 372]],
    ]
    let client = MockHTTPClient([completionURL: sse(chunks)])
    let streamed = try await parts(
      try await makeProvider(client, includeUsage: true).completionModel("m").doStream(
        LanguageModelV4CallOptions(prompt: testPrompt)))
    #expect(client.lastRequest?.bodyJSON?["stream_options"] == ["include_usage": true])
    #expect(Array(streamed.dropFirst(2).dropLast()) == [
      .textStart(id: "0"), .textDelta(id: "0", delta: "Hello"), .textDelta(id: "0", delta: ", World!"), .textEnd(id: "0"),
    ])
    guard case .finish(let usage, let finishReason, _)? = streamed.last else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason.unified == .stop)
    #expect(usage.outputTokens.total == 362)
  }
}

@Suite struct OpenAICompatibleEmbeddingTests {
  static let response: MockHTTPClient.Response = .jsonValue([
    "object": "list",
    "data": [
      ["object": "embedding", "index": 0, "embedding": [0.1, 0.2]],
      ["object": "embedding", "index": 1, "embedding": [0.3, 0.4]],
    ],
    "model": "text-embedding-3-large",
    "usage": ["prompt_tokens": 8, "total_tokens": 8],
  ])

  @Test func embedsValues() async throws {
    let client = MockHTTPClient([embeddingURL: Self.response])
    let model = makeProvider(client).textEmbeddingModel("text-embedding-3-large")
    let result = try await model.doEmbed(
      EmbeddingModelV4CallOptions(
        values: ["sunny day", "rainy day"], providerOptions: ["openaiCompatible": ["dimensions": 64, "user": "u"]]))
    #expect(result.embeddings == [[0.1, 0.2], [0.3, 0.4]])
    #expect(result.usage == .init(tokens: 8))
    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "text-embedding-3-large", "input": ["sunny day", "rainy day"], "encoding_format": "float",
        "dimensions": 64, "user": "u",
      ])
    #expect(try await model.maxEmbeddingsPerCall == 2048)
  }

  @Test func rejectsTooManyValues() async throws {
    let model = OpenAICompatibleEmbeddingModel(
      modelId: "m",
      config: OpenAICompatibleEmbeddingConfig(
        provider: "p.embedding", headers: { [:] }, url: { baseURL + $0 }, httpClient: MockHTTPClient(),
        maxEmbeddingsPerCall: 1))
    await #expect(throws: TooManyEmbeddingValuesForCallError.self) {
      _ = try await model.doEmbed(EmbeddingModelV4CallOptions(values: ["a", "b"]))
    }
  }

  @Test func worksWithEmbedMany() async throws {
    let client = MockHTTPClient([embeddingURL: Self.response])
    let registry = createProviderRegistry(["compat": makeProvider(client)])
    let result = try await embedMany(model: try registry.embeddingModel("compat:e"), values: ["a", "b"])
    #expect(result.embeddings.count == 2)
    #expect(try registry.languageModel("compat:m").provider == "test-provider.chat")
  }
}
