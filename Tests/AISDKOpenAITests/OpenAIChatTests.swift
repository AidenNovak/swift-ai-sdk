import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKOpenAI

let chatURL = "https://api.openai.com/v1/chat/completions"
let testPrompt: LanguageModelV4Prompt = [.user([.text(LanguageModelV4TextPart(text: "Hello"))])]

func fixture(_ name: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

func jsonFixture(_ name: String) throws -> MockHTTPClient.Response {
  .jsonValue(try JSONValue(jsonString: try fixture("\(name).json")))
}

func chunksFixture(_ name: String) throws -> MockHTTPClient.Response {
  let lines = try fixture("\(name).chunks.txt").split(separator: "\n").filter { !$0.isEmpty }
  return .streamChunks(lines.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"])
}

func makeOpenAI(_ client: MockHTTPClient, organization: String? = nil, project: String? = nil) throws -> OpenAIProvider {
  try createOpenAI(
    OpenAIProviderSettings(
      baseURL: "https://api.openai.com/v1", apiKey: "test-api-key", organization: organization, project: project,
      headers: ["Custom-Provider-Header": "provider-header-value"], httpClient: client, generateId: { "id-0" }))
}

func sse(_ chunks: [String]) -> MockHTTPClient.Response {
  .streamChunks(chunks.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"])
}

private func chatResponse(
  content: String? = "", toolCalls: JSONValue? = nil, annotations: JSONValue? = nil, logprobs: JSONValue? = nil,
  finishReason: String = "stop",
  usage: JSONValue = ["prompt_tokens": 4, "total_tokens": 34, "completion_tokens": 30],
  headers: [String: String] = [:]
) -> MockHTTPClient.Response {
  .jsonValue(
    [
      "id": "chatcmpl-95ZTZkhr0mHNKqerQfiwkuox3PHAd",
      "object": "chat.completion",
      "created": 1_711_115_037,
      "model": "gpt-3.5-turbo-0125",
      "choices": [
        jsonObject([
          "index": 0,
          "message": jsonObject([
            "role": "assistant", "content": .optional(content), "tool_calls": toolCalls, "annotations": annotations,
          ]),
          "logprobs": logprobs.map { ["content": $0] },
          "finish_reason": .string(finishReason),
        ])
      ],
      "usage": usage,
      "system_fingerprint": "fp_3bc1b5746c",
    ], headers: headers)
}

private func body(_ client: MockHTTPClient) -> JSONValue? { client.lastRequest?.bodyJSON }

@Suite struct OpenAIChatGenerateTests {
  @Test func extractsTextFromRecordedResponse() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("openai-text")])
    let result = try await makeOpenAI(client).chat("gpt-4.1-nano").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    guard case .text(let text)? = result.content.first else {
      Issue.record("expected text")
      return
    }
    #expect(text.text.hasPrefix("**Holiday Name:** Galaxy Day"))
    #expect(result.response?.metadata.modelId == "gpt-4.1-nano-2025-04-14")
    #expect(result.finishReason.unified == .stop)
  }

  @Test func extractsAudioTranscriptAlongsideToolCalls() async throws {
    let client = MockHTTPClient([
      chatURL: .jsonValue([
        "choices": [
          [
            "message": [
              "role": "assistant", "content": .null, "audio": ["transcript": "Let me check."],
              "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "weather", "arguments": "{}"]]],
            ],
            "finish_reason": "tool_calls",
          ]
        ]
      ])
    ])
    let result = try await makeOpenAI(client).chat("gpt-4o-audio-preview").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(
      result.content == [
        .text(LanguageModelV4Text(text: "Let me check.")),
        .toolCall(LanguageModelV4ToolCall(toolCallId: "call_1", toolName: "weather", input: "{}")),
      ])
  }

  @Test func extractsUsageCachedAndPredictionTokens() async throws {
    let client = MockHTTPClient([
      chatURL: chatResponse(
        usage: [
          "prompt_tokens": 15, "completion_tokens": 20, "total_tokens": 35,
          "prompt_tokens_details": ["cached_tokens": 1200],
          "completion_tokens_details": [
            "reasoning_tokens": 10, "accepted_prediction_tokens": 123, "rejected_prediction_tokens": 456,
          ],
        ])
    ])
    let result = try await makeOpenAI(client).chat("gpt-3.5-turbo").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(result.usage.inputTokens == .init(total: 15, noCache: -1185, cacheRead: 1200))
    #expect(result.usage.outputTokens == .init(total: 20, text: 10, reasoning: 10))
    #expect(result.providerMetadata == ["openai": ["acceptedPredictionTokens": 123, "rejectedPredictionTokens": 456]])
  }

  @Test func extractsLogprobsAndAnnotations() async throws {
    let logprobs: JSONValue = [["token": "Hello", "logprob": -0.1, "top_logprobs": []]]
    let client = MockHTTPClient([
      chatURL: chatResponse(
        content: "Based on search results",
        annotations: [
          ["type": "url_citation", "url_citation": ["start_index": 24, "end_index": 29, "url": "https://example.com/doc1.pdf", "title": "Document 1"]]
        ], logprobs: logprobs)
    ])
    let result = try await makeOpenAI(client).chat("gpt-4o").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["logprobs": 1]]))
    #expect(
      result.content == [
        .text(LanguageModelV4Text(text: "Based on search results")),
        .source(.url(id: "id-0", url: "https://example.com/doc1.pdf", title: "Document 1")),
      ])
    #expect(result.providerMetadata?["openai"]?["logprobs"] == logprobs)
    #expect(body(client)?["logprobs"] == true)
    #expect(body(client)?["top_logprobs"] == 1)
  }

  @Test func rejectsResponseWithoutChoices() async throws {
    let client = MockHTTPClient([chatURL: .jsonValue(["id": "x", "choices": []])])
    await #expect {
      _ = try await makeOpenAI(client).chat("gpt-4o").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      (error as? InvalidResponseDataError)?.message == "Response did not contain any choices."
    }
  }

  @Test func sendsSettingsAndHeaders() async throws {
    let client = MockHTTPClient([chatURL: chatResponse()])
    let result = try await makeOpenAI(client, organization: "test-organization", project: "test-project")
      .chat("gpt-3.5-turbo").doGenerate(
        LanguageModelV4CallOptions(
          prompt: testPrompt, maxOutputTokens: 100, temperature: 0.5, stopSequences: ["END"], topP: 0.9, topK: 2,
          presencePenalty: 0.1, frequencyPenalty: 0.2, seed: 42, headers: ["Custom-Request-Header": "request-header-value"],
          providerOptions: [
            "openai": [
              "logitBias": ["50256": -100], "parallelToolCalls": false, "user": "test-user-id", "store": true,
              "metadata": ["custom": "value"], "prediction": ["type": "content", "content": "Hello"],
              "maxCompletionTokens": 255, "promptCacheKey": "k", "promptCacheRetention": "24h",
              "safetyIdentifier": "s", "textVerbosity": "low",
            ]
          ]))
    #expect(
      body(client) == [
        "model": "gpt-3.5-turbo", "messages": [["role": "user", "content": "Hello"]], "max_tokens": 100,
        "temperature": 0.5, "top_p": 0.9, "frequency_penalty": 0.2, "presence_penalty": 0.1, "stop": ["END"],
        "seed": 42, "logit_bias": ["50256": -100], "parallel_tool_calls": false, "user": "test-user-id",
        "store": true, "metadata": ["custom": "value"], "prediction": ["type": "content", "content": "Hello"],
        "max_completion_tokens": 255, "prompt_cache_key": "k", "prompt_cache_retention": "24h",
        "safety_identifier": "s", "verbosity": "low",
      ])
    #expect(result.warnings == [.unsupported(feature: "topK")])
    let headers = try #require(client.lastRequest?.headers)
    #expect(headers["authorization"] == "Bearer test-api-key")
    #expect(headers["openai-organization"] == "test-organization")
    #expect(headers["openai-project"] == "test-project")
    #expect(headers["custom-provider-header"] == "provider-header-value")
    #expect(headers["custom-request-header"] == "request-header-value")
    #expect(headers["user-agent"]?.hasPrefix("ai-sdk/openai/") == true)
  }

  @Test func mapsReasoningEffortSources() async throws {
    let client = MockHTTPClient([chatURL: chatResponse()])
    let provider = try makeOpenAI(client)
    _ = try await provider.chat("o4-mini").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .providerDefault))
    #expect(body(client)?["reasoning_effort"] == nil)
    _ = try await provider.chat("o4-mini").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .high))
    #expect(body(client)?["reasoning_effort"] == "high")
    _ = try await provider.chat("o4-mini").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, reasoning: .high, providerOptions: ["openai": ["reasoningEffort": "max"]]))
    #expect(body(client)?["reasoning_effort"] == "max")
  }

  @Test func passesToolsAndParsesToolCalls() async throws {
    let client = MockHTTPClient([
      chatURL: chatResponse(
        content: nil,
        toolCalls: [["id": "call_O17Uplv4lJvD6DVdIvFFeRMw", "type": "function", "function": ["name": "test-tool", "arguments": "{\"value\":\"Spark\"}"]]],
        finishReason: "tool_calls")
    ])
    let result = try await makeOpenAI(client).chat("gpt-3.5-turbo").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [
          .function(
            LanguageModelV4FunctionTool(
              name: "test-tool",
              inputSchema: JSONSchema([
                "type": "object", "properties": ["value": ["type": "string"]], "required": ["value"],
                "additionalProperties": false, "$schema": "http://json-schema.org/draft-07/schema#",
              ]), strict: true))
        ], toolChoice: .tool(toolName: "test-tool")))
    #expect(
      body(client)?["tools"] == [
        [
          "type": "function",
          "function": [
            "name": "test-tool",
            "parameters": [
              "type": "object", "properties": ["value": ["type": "string"]], "required": ["value"],
              "additionalProperties": false, "$schema": "http://json-schema.org/draft-07/schema#",
            ],
            "strict": true,
          ],
        ]
      ])
    #expect(body(client)?["tool_choice"] == ["type": "function", "function": ["name": "test-tool"]])
    #expect(
      result.content == [
        .toolCall(LanguageModelV4ToolCall(toolCallId: "call_O17Uplv4lJvD6DVdIvFFeRMw", toolName: "test-tool", input: "{\"value\":\"Spark\"}"))
      ])
    #expect(result.finishReason == LanguageModelV4FinishReason(unified: .toolCalls, raw: "tool_calls"))
  }

  @Test func sendsResponseFormats() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "{}")])
    let model = try makeOpenAI(client).chat("gpt-4o-2024-08-06")

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .text))
    #expect(body(client)?["response_format"] == nil)

    _ = try await model.doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: nil)))
    #expect(body(client)?["response_format"] == ["type": "json_object"])

    let schema = JSONSchema(["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]])
    _ = try await model.doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, responseFormat: .json(schema: schema, name: "test-name", description: "test description"),
        providerOptions: ["openai": ["strictJsonSchema": false]]))
    #expect(
      body(client)?["response_format"] == [
        "type": "json_schema",
        "json_schema": ["schema": schema.value, "strict": false, "name": "test-name", "description": "test description"],
      ])
  }

  @Test func normalizesPropertyNamesAndLookaroundPatterns() async throws {
    let client = MockHTTPClient([chatURL: chatResponse(content: "{}")])
    let schema = JSONSchema([
      "type": "object",
      "properties": [
        "tags": ["type": "object", "propertyNames": ["type": "string", "pattern": "^[a-z]+$"], "additionalProperties": ["type": "string"]],
        "password": ["type": "string", "pattern": "^(?=.*\\d).+$"],
        "literal": ["type": "string", "pattern": "^[(?=]$"],
      ],
    ])
    let result = try await makeOpenAI(client).chat("gpt-4o").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, responseFormat: .json(schema: schema)))
    #expect(
      body(client)?["response_format"]?["json_schema"]?["schema"] == [
        "type": "object",
        "properties": [
          "tags": ["type": "object", "additionalProperties": ["type": "string"]],
          "password": ["type": "string"],
          "literal": ["type": "string", "pattern": "^[(?=]$"],
        ],
      ])
    #expect(result.warnings.count == 2)
    await #expect(throws: UnsupportedFunctionalityError.self) {
      _ = try await makeOpenAI(client).chat("gpt-4o").doGenerate(
        LanguageModelV4CallOptions(
          prompt: testPrompt,
          responseFormat: .json(schema: JSONSchema(["type": "object", "propertyNames": ["enum": ["a"]]]))))
    }
  }

  @Test func clearsUnsupportedSettingsForReasoningModels() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("openai-text")])
    let provider = try makeOpenAI(client)
    let result = try await provider.chat("o4-mini").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, temperature: 0.5, topP: 0.7, presencePenalty: 0.3, frequencyPenalty: 0.2))
    #expect(body(client) == ["model": "o4-mini", "messages": [["role": "user", "content": "Hello"]]])
    #expect(
      result.warnings == [
        .unsupported(feature: "temperature", details: "temperature is not supported for reasoning models"),
        .unsupported(feature: "topP", details: "topP is not supported for reasoning models"),
        .unsupported(feature: "frequencyPenalty", details: "frequencyPenalty is not supported for reasoning models"),
        .unsupported(feature: "presencePenalty", details: "presencePenalty is not supported for reasoning models"),
      ])

    _ = try await provider.chat("o4-mini").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt, maxOutputTokens: 1000))
    #expect(body(client) == ["model": "o4-mini", "messages": [["role": "user", "content": "Hello"]], "max_completion_tokens": 1000])
  }

  @Test func allowsSamplingWhenReasoningIsNoneOnGpt51() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("openai-text")])
    let provider = try makeOpenAI(client)
    let result = try await provider.chat("gpt-5.1").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, temperature: 0.5, reasoning: LanguageModelV4ReasoningEffort.none))
    #expect(
      body(client) == [
        "model": "gpt-5.1", "messages": [["role": "user", "content": "Hello"]],
        "reasoning_effort": "none", "temperature": 0.5,
      ])
    #expect(result.warnings.isEmpty)

    let o4 = try await provider.chat("o4-mini").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, temperature: 0.5, reasoning: LanguageModelV4ReasoningEffort.none))
    #expect(body(client) == ["model": "o4-mini", "messages": [["role": "user", "content": "Hello"]], "reasoning_effort": "none"])
    #expect(o4.warnings == [.unsupported(feature: "temperature", details: "temperature is not supported for reasoning models")])
  }

  @Test func handlesGpt6ReasoningEfforts() async throws {
    let client = MockHTTPClient([chatURL: try jsonFixture("openai-text")])
    let provider = try makeOpenAI(client)

    for modelId in ["gpt-6-sol", "gpt-6-luna"] {
      let result = try await provider.chat(modelId).doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["reasoningEffort": "none"]]))
      #expect(body(client)?["reasoning_effort"] == "none")
      #expect(result.warnings.isEmpty)
    }

    let astra = try await provider.chat("gpt-6-astra").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["reasoningEffort": "minimal"]]))
    #expect(body(client) == ["model": "gpt-6-astra", "messages": [["role": "user", "content": "Hello"]]])
    #expect(
      astra.warnings == [
        .unsupported(
          feature: "reasoningEffort",
          details: "gpt-6-astra only supports the following reasoning efforts: low, medium, high, xhigh, max")
      ])

    let stripped = try await provider.chat("gpt-6-astra").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, temperature: 0.5, topP: 0.7,
        providerOptions: ["openai": ["reasoningEffort": "low", "logprobs": 5, "promptCacheRetention": "24h"]]))
    #expect(body(client) == ["model": "gpt-6-astra", "messages": [["role": "user", "content": "Hello"]], "reasoning_effort": "low"])
    #expect(
      stripped.warnings == [
        .unsupported(
          feature: "promptCacheRetention",
          details: "promptCacheRetention is not supported by GPT-6 and later models; use promptCacheOptions instead"),
        .unsupported(feature: "temperature", details: "temperature is not supported for reasoning models"),
        .unsupported(feature: "topP", details: "topP is not supported for reasoning models"),
        .other(message: "logprobs is not supported for reasoning models"),
        .other(message: "topLogprobs is not supported for reasoning models"),
      ])
  }

  @Test func choosesSystemMessageMode() async throws {
    let client = MockHTTPClient([chatURL: chatResponse()])
    let provider = try makeOpenAI(client)
    let prompt: LanguageModelV4Prompt = [.system("You are a helpful assistant."), .user([.text(LanguageModelV4TextPart(text: "Hello"))])]

    _ = try await provider.chat("gpt-4o").doGenerate(LanguageModelV4CallOptions(prompt: prompt))
    #expect(body(client)?["messages"]?[0]?["role"] == "system")
    _ = try await provider.chat("o1").doGenerate(LanguageModelV4CallOptions(prompt: prompt))
    #expect(body(client)?["messages"]?[0]?["role"] == "developer")
    _ = try await provider.chat("stealth-reasoner").doGenerate(
      LanguageModelV4CallOptions(prompt: prompt, temperature: 0.3, providerOptions: ["openai": ["forceReasoning": true]]))
    #expect(body(client)?["messages"]?[0]?["role"] == "developer")
    #expect(body(client)?["temperature"] == nil)
    let removed = try await provider.chat("gpt-4o").doGenerate(
      LanguageModelV4CallOptions(prompt: prompt, providerOptions: ["openai": ["systemMessageMode": "remove"]]))
    #expect(body(client)?["messages"] == [["role": "user", "content": "Hello"]])
    #expect(removed.warnings == [.other(message: "system messages are removed for this model")])
  }

  @Test func removesTemperatureForSearchPreviewModels() async throws {
    let client = MockHTTPClient([chatURL: chatResponse()])
    for modelId in ["gpt-4o-search-preview", "gpt-4o-mini-search-preview", "gpt-4o-mini-search-preview-2025-03-11"] {
      let result = try await makeOpenAI(client).chat(modelId).doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, temperature: 0.7))
      #expect(body(client)?["temperature"] == nil)
      #expect(
        result.warnings == [
          .unsupported(
            feature: "temperature", details: "temperature is not supported for the search preview models and has been removed.")
        ])
    }
  }

  @Test func validatesServiceTiers() async throws {
    let client = MockHTTPClient([chatURL: chatResponse()])
    let provider = try makeOpenAI(client)

    let flexOK = try await provider.chat("o4-mini").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["serviceTier": "flex"]]))
    #expect(body(client)?["service_tier"] == "flex")
    #expect(flexOK.warnings.isEmpty)

    let flexBad = try await provider.chat("gpt-4o-mini").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["serviceTier": "flex"]]))
    #expect(body(client)?["service_tier"] == nil)
    #expect(flexBad.warnings == [.unsupported(feature: "serviceTier", details: "flex processing is only available for o3, o4-mini, and gpt-5 models")])

    for tier in ["priority", "fast"] {
      let ok = try await provider.chat("gpt-4o").doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["serviceTier": .string(tier)]]))
      #expect(body(client)?["service_tier"] == .string(tier))
      #expect(ok.warnings.isEmpty)
      let bad = try await provider.chat("gpt-3.5-turbo").doGenerate(
        LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["serviceTier": .string(tier)]]))
      #expect(body(client)?["service_tier"] == nil)
      #expect(bad.warnings.count == 1)
    }

    _ = try await provider.chat("gpt-5.6-sol").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, providerOptions: ["openai": ["serviceTier": "ultrafast"]]))
    #expect(body(client)?["service_tier"] == "ultrafast")
  }

  @Test func surfacesAPIErrors() async throws {
    let client = MockHTTPClient([
      chatURL: .error(statusCode: 400, body: try fixture("reasoning-model-legacy-parameter-error.json"))
    ])
    await #expect {
      _ = try await makeOpenAI(client).chat("o4-mini").doGenerate(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let apiError = error as? APICallError
      return apiError?.statusCode == 400 && apiError?.isRetryable == false
        && apiError?.message.hasPrefix("Unsupported parameter: 'max_tokens'") == true
    }
  }
}

@Suite struct OpenAIChatStreamTests {
  private func streamParts(_ client: MockHTTPClient, model: String = "gpt-3.5-turbo", options: LanguageModelV4CallOptions? = nil)
    async throws -> [LanguageModelV4StreamPart]
  {
    let result = try await makeOpenAI(client).chat(model).doStream(options ?? LanguageModelV4CallOptions(prompt: testPrompt))
    return try await collect(result.stream)
  }

  @Test func streamsRecordedText() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("openai-text")])
    let parts = try await streamParts(client, model: "gpt-4.1-nano")
    #expect(body(client)?["stream"] == true)
    #expect(body(client)?["stream_options"] == ["include_usage": true])
    let text = parts.compactMap { part -> String? in
      if case .textDelta(_, let delta, _) = part { return delta }
      return nil
    }.joined()
    #expect(text.hasPrefix("**Holiday Name:**"))
    guard case .finish(let usage, let finishReason, _)? = parts.last else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason.unified == .stop)
    #expect((usage.outputTokens.total ?? 0) > 0)
  }

  @Test func setsModelIdFromAzureModelRouter() async throws {
    let client = MockHTTPClient([chatURL: try chunksFixture("azure-model-router.1")])
    let parts = try await streamParts(client, model: "test-azure-model-router")
    let metadata = parts.compactMap { part -> LanguageModelV4ResponseMetadata? in
      if case .responseMetadata(let metadata) = part { return metadata }
      return nil
    }
    #expect(metadata.count == 1)
    #expect(metadata.first?.modelId?.isEmpty == false)
  }

  @Test func streamsTextAfterAzureContentFilterChunk() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        #"{"choices":[],"created":0,"id":"","model":"","object":"","prompt_filter_results":[{"prompt_index":0,"content_filter_results":{}}]}"#,
        #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1702657020,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1702657020,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
      ])
    ])
    let parts = try await streamParts(client)
    #expect(parts.contains(.textDelta(id: "0", delta: "Hello")))
    let metadata = parts.compactMap { part -> String? in
      if case .responseMetadata(let metadata) = part { return metadata.id }
      return nil
    }
    #expect(metadata == ["chatcmpl-1"])
  }

  @Test func streamsToolDeltasAndAnnotations() async throws {
    let prefix = #"{"id":"chatcmpl-96aZqmeDpA9IPD6tACY8djkMsJCMP","object":"chat.completion.chunk","created":1711357598,"model":"gpt-3.5-turbo-0125","system_fingerprint":"fp_3bc1b5746c","choices":[{"index":0,"delta":"#
    let client = MockHTTPClient([
      chatURL: sse([
        prefix + #"{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_O17Uplv4lJvD6DVdIvFFeRMw","type":"function","function":{"name":"test-tool","arguments":""}}]},"logprobs":null,"finish_reason":null}]}"#,
        prefix + #"{"tool_calls":[{"index":0,"function":{"arguments":"{\""}}]},"logprobs":null,"finish_reason":null}]}"#,
        prefix + #"{"tool_calls":[{"index":0,"function":{"arguments":"value\":\"Spark\"}"}}]},"logprobs":null,"finish_reason":null}]}"#,
        prefix + #"{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com","title":"Example"}}]},"finish_reason":null}]}"#,
        prefix + #"{},"logprobs":null,"finish_reason":"tool_calls"}]}"#,
        #"{"id":"chatcmpl-96aZqmeDpA9IPD6tACY8djkMsJCMP","object":"chat.completion.chunk","created":1711357598,"model":"gpt-3.5-turbo-0125","choices":[],"usage":{"prompt_tokens":53,"completion_tokens":17,"total_tokens":70}}"#,
      ])
    ])
    let parts = try await streamParts(client)
    let id = "call_O17Uplv4lJvD6DVdIvFFeRMw"
    let expected: [LanguageModelV4StreamPart] = [
      .toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: "test-tool")),
      .toolInputDelta(id: id, delta: "{\""),
      .toolInputDelta(id: id, delta: "value\":\"Spark\"}"),
      .source(.url(id: "id-0", url: "https://example.com", title: "Example")),
      .toolInputEnd(id: id),
      .toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: "test-tool", input: "{\"value\":\"Spark\"}")),
    ]
    #expect(Array(parts.dropFirst(2).dropLast()) == expected)
    guard case .finish(let usage, let finishReason, let metadata)? = parts.last else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason == LanguageModelV4FinishReason(unified: .toolCalls, raw: "tool_calls"))
    #expect(usage.inputTokens.total == 53)
    #expect(metadata == ["openai": [:]])
  }

  @Test func streamsToolCallWithoutTypeField() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        #"{"id":"c","created":1,"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":null}]}"#,
        #"{"id":"c","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
      ])
    ])
    let parts = try await streamParts(client)
    #expect(parts.contains(.toolCall(LanguageModelV4ToolCall(toolCallId: "call_1", toolName: "lookup", input: "{}"))))
  }

  @Test func throwsAPIErrorWhenFirstChunkIsError() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        #"{"error":{"message": "The server had an error processing your request.","type":"server_error","param":null,"code":null}}"#
      ])
    ])
    await #expect {
      _ = try await makeOpenAI(client).chat("gpt-4o").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let apiError = error as? APICallError
      return apiError?.message == "The server had an error processing your request." && apiError?.statusCode == 500
        && apiError?.isRetryable == true
    }

    client.respond(to: chatURL, with: sse([#"{"error":{"message":"bad request","type":"provider_error","param":null,"code":400}}"#]))
    await #expect {
      _ = try await makeOpenAI(client).chat("gpt-4o").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let apiError = error as? APICallError
      return apiError?.statusCode == 400 && apiError?.isRetryable == false
    }

    client.respond(
      to: chatURL, with: sse([#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#]))
    await #expect {
      _ = try await makeOpenAI(client).chat("gpt-4o").doStream(LanguageModelV4CallOptions(prompt: testPrompt))
    } throws: { error in
      let apiError = error as? APICallError
      return apiError?.statusCode == 429 && apiError?.isRetryable == false
    }
  }

  @Test func forwardsErrorPartsAfterOutputStarted() async throws {
    let client = MockHTTPClient([
      chatURL: sse([
        #"{"id":"chatcmpl-error-after-output","object":"chat.completion.chunk","created":1702657020,"model":"gpt-3.5-turbo-0613","system_fingerprint":null,"choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}"#,
        #"{"error":{"message":"stream failed after output","type":"server_error","param":null,"code":null}}"#,
      ])
    ])
    let parts = try await streamParts(client)
    #expect(parts.count == 7)
    #expect(parts[2] == .textStart(id: "0"))
    #expect(parts[3] == .textDelta(id: "0", delta: "Hello"))
    guard case .error(let error) = parts[4], let streamError = error as? ProviderStreamError else {
      Issue.record("expected provider stream error")
      return
    }
    #expect(streamError.message == "stream failed after output")
    #expect(streamError.statusCode == 500)
    #expect(streamError.isRetryable == true)
    #expect(streamError.type == "server_error")
    #expect(streamError.code == nil)
    #expect(parts[5] == .textEnd(id: "0"))
    guard case .finish(let usage, let finishReason, let metadata) = parts[6] else {
      Issue.record("missing finish")
      return
    }
    #expect(finishReason == LanguageModelV4FinishReason(unified: .error))
    #expect(usage == LanguageModelV4Usage())
    #expect(metadata == ["openai": [:]])
  }

  @Test func handlesUnparsableChunks() async throws {
    let client = MockHTTPClient([chatURL: sse(["{unparsable}"])])
    let parts = try await streamParts(client)
    #expect(parts.count == 3)
    guard case .error = parts[1], case .finish(_, let finishReason, _) = parts[2] else {
      Issue.record("expected error then finish")
      return
    }
    #expect(finishReason.unified == .error)
  }

  @Test func includesRawChunksWhenRequested() async throws {
    let chunk = #"{"id":"c","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
    let client = MockHTTPClient([chatURL: sse([chunk])])
    let parts = try await streamParts(client, options: LanguageModelV4CallOptions(prompt: testPrompt, includeRawChunks: true))
    #expect(parts.contains(.raw(rawValue: try JSONValue(jsonString: chunk))))
  }

  @Test func worksEndToEndWithStreamTextAndTools() async throws {
    struct Input: Codable, Sendable { var value: String }
    let client = MockHTTPClient()
    client.respond(
      to: chatURL,
      withSequence: [
        sse([
          #"{"id":"c1","created":1,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\"value\":\"hi\"}"}}]},"finish_reason":null}]}"#,
          #"{"id":"c1","created":1,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]),
        sse([
          #"{"id":"c2","created":1,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Echoed hi"},"finish_reason":"stop"}]}"#
        ]),
      ])
    let echo = tool(
      description: "Echo",
      inputSchema: Schema(Input.self, jsonSchema: ["type": "object", "properties": ["value": ["type": "string"]]])
    ) { input, _ in JSONValue.string(input.value) }
    let result = streamText(
      model: try makeOpenAI(client).chat("gpt-4o"), prompt: "Echo hi", tools: ["echo": echo], stopWhen: [.isStepCount(3)])
    #expect(try await result.text == "Echoed hi")
    #expect(try await result.steps.count == 2)
    #expect(client.requests.last?.bodyJSON?["messages"]?[2] == ["role": "tool", "tool_call_id": "call_1", "content": "hi"])
  }
}

@Suite struct OpenAIChatMessageTests {
  @Test func convertsFilePartsAndCacheBreakpoints() throws {
    let breakpoint: SharedV4ProviderOptions = ["openai": ["promptCacheBreakpoint": ["mode": "explicit"]]]
    let converted = try convertToOpenAIChatMessages([
      .system("sys", providerOptions: breakpoint),
      .user([
        .text(LanguageModelV4TextPart(text: "Look", providerOptions: breakpoint)),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "image/png", providerOptions: ["openai": ["imageDetail": "low"]])),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "audio/wav")),
        .file(LanguageModelV4FilePart(data: .base64("AAECAw=="), mediaType: "application/pdf")),
        .file(LanguageModelV4FilePart(data: .reference(["openai": "file-abc"]), mediaType: "application/pdf")),
      ]),
    ])
    #expect(
      converted.messages == [
        ["role": "system", "content": [["type": "text", "text": "sys", "prompt_cache_breakpoint": ["mode": "explicit"]]]],
        [
          "role": "user",
          "content": [
            ["type": "text", "text": "Look", "prompt_cache_breakpoint": ["mode": "explicit"]],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAECAw==", "detail": "low"]],
            ["type": "input_audio", "input_audio": ["data": "AAECAw==", "format": "wav"]],
            ["type": "file", "file": ["filename": "part-3.pdf", "file_data": "data:application/pdf;base64,AAECAw=="]],
            ["type": "file", "file": ["file_id": "file-abc"]],
          ],
        ],
      ])
  }

  @Test func convertsAssistantAndToolMessages() throws {
    let converted = try convertToOpenAIChatMessages([
      .assistant([
        .reasoning(LanguageModelV4ReasoningPart(text: "hidden")),
        .toolCall(LanguageModelV4ToolCallPart(toolCallId: "c1", toolName: "t", input: ["a": 1])),
        .toolCall(LanguageModelV4ToolCallPart(toolCallId: "c2", toolName: "t", input: "not-an-object")),
      ]),
      .tool([
        .toolResult(LanguageModelV4ToolResultPart(toolCallId: "c1", toolName: "t", output: .text("ok"))),
        .toolResult(
          LanguageModelV4ToolResultPart(
            toolCallId: "c2", toolName: "t", output: .errorText("bad", providerOptions: ["openai": ["promptCacheBreakpoint": ["mode": "explicit"]]]))),
      ]),
    ])
    #expect(
      converted.messages == [
        [
          "role": "assistant", "content": .null,
          "tool_calls": [
            ["id": "c1", "type": "function", "function": ["name": "t", "arguments": "{\"a\":1}"]],
            ["id": "c2", "type": "function", "function": ["name": "t", "arguments": "{}"]],
          ],
        ],
        ["role": "tool", "tool_call_id": "c1", "content": "ok"],
        ["role": "tool", "tool_call_id": "c2", "content": [["type": "text", "text": "bad", "prompt_cache_breakpoint": ["mode": "explicit"]]]],
      ])
  }

  @Test func rejectsUnsupportedFiles() {
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToOpenAIChatMessages([.user([.file(LanguageModelV4FilePart(data: .url(URL(string: "https://x.com/a.pdf")!), mediaType: "application/pdf"))])])
    }
    #expect(throws: UnsupportedFunctionalityError.self) {
      try convertToOpenAIChatMessages([.user([.file(LanguageModelV4FilePart(data: .base64("AA=="), mediaType: "audio/ogg"))])])
    }
  }
}

@Suite struct OpenAICapabilityTests {
  @Test func detectsModelFamilies() {
    #expect(getOpenAILanguageModelCapabilities("o3-mini").isReasoningModel)
    #expect(getOpenAILanguageModelCapabilities("gpt-5").isReasoningModel)
    #expect(!getOpenAILanguageModelCapabilities("gpt-5-chat-latest").isReasoningModel)
    #expect(getOpenAILanguageModelCapabilities("gpt-5.1-chat-latest").isReasoningModel)
    #expect(!getOpenAILanguageModelCapabilities("gpt-4o").isReasoningModel)
    #expect(!getOpenAILanguageModelCapabilities("ft:gpt-4o:org").isReasoningModel)
    #expect(!getOpenAILanguageModelCapabilities("gpt-5-nano").supportsPriorityProcessing)
    #expect(getOpenAILanguageModelCapabilities("gpt-5.1").supportsNonReasoningParameters)
    #expect(!getOpenAILanguageModelCapabilities("gpt-6-sol").supportsNonReasoningParameters)
    #expect(getOpenAILanguageModelCapabilities("gpt-6-sol").supportedReasoningEfforts?.first == "none")
    #expect(getOpenAILanguageModelCapabilities("gpt-6-astra").supportsAsyncToolCalling)
  }

  @Test func detectsRegexLookaround() {
    #expect(containsRegexLookaround("^(?=.*\\d)"))
    #expect(containsRegexLookaround("(?<!x)y"))
    #expect(!containsRegexLookaround("\\(?=x"))
    #expect(!containsRegexLookaround("[(?=]"))
    #expect(!containsRegexLookaround("(?:abc)"))
  }

  @Test func validatesBaseURL() {
    #expect(throws: InvalidArgumentError.self) { _ = try createOpenAI(OpenAIProviderSettings(baseURL: "not a url")) }
  }
}
