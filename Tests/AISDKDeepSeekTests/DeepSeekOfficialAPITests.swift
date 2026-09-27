import AISDK
import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKDeepSeek

private let base = "https://api.deepseek.com"
private let testPrompt: LanguageModelV4Prompt = [.user([.text(LanguageModelV4TextPart(text: "Hello"))])]

private func fixture(_ name: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func makeProvider(_ client: MockHTTPClient, baseURL: String? = nil) -> DeepSeekProvider {
  createDeepSeek(DeepSeekProviderSettings(apiKey: "test-api-key", baseURL: baseURL, httpClient: client))
}

private func chatResponse() -> MockHTTPClient.Response {
  .jsonValue([
    "id": "x", "object": "chat.completion", "created": 0, "model": "deepseek-flash",
    "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": "ok"]]],
  ])
}

@Suite struct DeepSeekThinkingMappingTests {
  @Test(arguments: [
    ("none", nil as String?, "disabled" as String?),
    ("minimal", "low", nil),
    ("low", "low", nil),
    ("medium", "high", nil),
    ("high", "high", nil),
    ("xhigh", "max", nil),
    ("max", "max", nil),
    ("ultra", "max", nil),
  ])
  func mapsProviderEffort(requested: String, effort: String?, thinking: String?) async throws {
    let client = MockHTTPClient(["\(base)/chat/completions": chatResponse()])
    _ = try await makeProvider(client).chat("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, providerOptions: ["deepseek": ["reasoningEffort": .string(requested)]]))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["reasoning_effort"] == effort.map(JSONValue.string))
    #expect(body["thinking"] == thinking.map { ["type": .string($0)] })
  }

  @Test func noneEffortEnablesTemperatureAndDropsTopP() async throws {
    let client = MockHTTPClient(["\(base)/chat/completions": chatResponse()])
    let result = try await makeProvider(client).chat("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, temperature: 0.3, topP: 0.97, reasoning: LanguageModelV4ReasoningEffort.none))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["temperature"] == 0.3)
    #expect(body["top_p"] == nil)
    #expect(result.warnings.contains { if case .unsupported(feature: "topP", _) = $0 { true } else { false } })
  }

  @Test func thinkingKeepsTopPWithoutWarningAtOrAbove095() async throws {
    let client = MockHTTPClient(["\(base)/chat/completions": chatResponse()])
    let result = try await makeProvider(client).chat("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt, topP: 0.97))
    #expect(client.lastRequest?.bodyJSON?["top_p"] == 0.97)
    #expect(result.warnings.isEmpty)
  }

  @Test func abortedFinishReasonMapsToOther() {
    #expect(mapDeepSeekFinishReason("aborted") == .other)
  }
}

@Suite struct DeepSeekResponsesTests {
  let url = "\(base)/responses"

  @Test func sendsRequestAndParsesRecordedResponse() async throws {
    let client = MockHTTPClient([url: .jsonValue(try JSONValue(jsonString: try fixture("deepseek-responses-text.json")))])
    let result = try await makeProvider(client).responses("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [
          .system("Answer in one short sentence."), .user([.text(LanguageModelV4TextPart(text: "What is 17 * 3?"))]),
        ],
        maxOutputTokens: 400, reasoning: .low))

    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(
      body == [
        "model": "deepseek-flash",
        "instructions": "Answer in one short sentence.",
        "input": [["role": "user", "content": [["type": "input_text", "text": "What is 17 * 3?"]]]],
        "max_output_tokens": 400,
        "reasoning": ["effort": "low"],
      ])

    let text = result.content.compactMap { part -> String? in
      if case .text(let text) = part { return text.text }
      return nil
    }.joined()
    #expect(text.contains("51"))
    #expect(result.finishReason == LanguageModelV4FinishReason(unified: .stop, raw: "completed"))
    #expect(result.usage.inputTokens.total != nil)
    #expect(result.response?.modelId == "deepseek-flash")
  }

  @Test func streamsRecordedToolCall() async throws {
    let client = MockHTTPClient([url: .streamChunks([try fixture("deepseek-responses-tool-call.sse.txt")])])
    let result = try await makeProvider(client).responses("deepseek-flash").doStream(
      LanguageModelV4CallOptions(
        prompt: testPrompt,
        tools: [.function(LanguageModelV4FunctionTool(name: "get_time", inputSchema: ["type": "object"]))]))
    let parts = try await collect(result.stream)

    let reasoning = parts.compactMap { part -> String? in
      if case .reasoningDelta(_, let delta, _) = part { return delta }
      return nil
    }.joined()
    #expect(!reasoning.isEmpty)
    let call = parts.compactMap { part -> LanguageModelV4ToolCall? in
      if case .toolCall(let call) = part { return call }
      return nil
    }.first
    #expect(call?.toolName == "get_time")
    #expect(call?.toolCallId.hasPrefix("call_") == true)
    #expect(call?.input == "{}")
    guard case .finish(let usage, let reason, _) = parts.last else {
      Issue.record("expected finish")
      return
    }
    #expect(reason.unified == .toolCalls)
    #expect(usage.outputTokens.reasoning != nil)
    #expect(client.lastRequest?.bodyJSON?["tools"] == [["type": "function", "name": "get_time", "parameters": ["type": "object"]]])
  }

  @Test func streamsRecordedText() async throws {
    let client = MockHTTPClient([url: .streamChunks([try fixture("deepseek-responses-text.sse.txt")])])
    let result = streamText(model: makeProvider(client).responses("deepseek-flash"), prompt: "Count from 1 to 5.")
    let text = try await result.text
    #expect(text.contains("1") && text.contains("5"))
    #expect(try await result.finishReason == .stop)
  }

  @Test func convertsConversationToInputItems() throws {
    var warnings: [SharedV4Warning] = []
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0])
    let prompt: LanguageModelV4Prompt = [
      .system("sys"),
      .user([
        .text(LanguageModelV4TextPart(text: "look")),
        .file(LanguageModelV4FilePart(data: .data(png), mediaType: "image", providerOptions: ["deepseek": ["imageDetail": "low"]])),
        .file(LanguageModelV4FilePart(data: .reference(["deepseek": "file-api-1"]), mediaType: "image")),
      ]),
      .assistant([
        .reasoning(LanguageModelV4ReasoningPart(text: "think")),
        .text(LanguageModelV4TextPart(text: "calling")),
        .toolCall(LanguageModelV4ToolCallPart(toolCallId: "c1", toolName: "calc", input: ["a": 1])),
      ]),
      .tool([.toolResult(LanguageModelV4ToolResultPart(toolCallId: "c1", toolName: "calc", output: .json(["r": 2])))]),
      .system("later instruction"),
    ]
    let input = try convertToResponsesInput(prompt, warnings: &warnings)
    #expect(input.instructions == "sys")
    #expect(
      input.items == [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": "look"],
            ["type": "input_image", "image_url": .string("data:image/png;base64,\(png.base64EncodedString())"), "detail": "low"],
            ["type": "input_image", "file_id": "file-api-1"],
          ],
        ],
        ["type": "reasoning", "content": [["type": "reasoning_text", "text": "think"]]],
        ["role": "assistant", "content": [["type": "output_text", "text": "calling"]]],
        ["type": "function_call", "call_id": "c1", "name": "calc", "arguments": #"{"a":1}"#],
        ["type": "function_call_output", "call_id": "c1", "output": #"{"r":2}"#],
        ["role": "system", "content": "later instruction"],
      ])
    #expect(warnings.isEmpty)
  }

  @Test func mapsJsonSchemaEffortAndToolChoice() async throws {
    let client = MockHTTPClient([url: .jsonValue(try JSONValue(jsonString: try fixture("deepseek-responses-text.json")))])
    let schema: JSONSchema = ["type": "object", "properties": ["n": ["type": "number"]]]
    _ = try await makeProvider(client).responses("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: testPrompt, responseFormat: .json(schema: schema, name: "answer"),
        tools: [.function(LanguageModelV4FunctionTool(name: "t", inputSchema: ["type": "object"]))],
        toolChoice: .tool(toolName: "t"), reasoning: LanguageModelV4ReasoningEffort.none,
        providerOptions: ["deepseek": ["userId": "u1", "topLogprobs": 3]]))
    let body = try #require(client.lastRequest?.bodyJSON)
    #expect(body["text"] == ["format": ["type": "json_schema", "name": "answer", "schema": schema.value]])
    #expect(body["reasoning"] == ["effort": "none"])
    #expect(body["tool_choice"] == ["type": "function", "name": "t"])
    #expect(body["user"] == "u1")
    #expect(body["top_logprobs"] == 3)
  }

  @Test func incompleteResponseMapsToLength() {
    let response = DeepSeekResponsesResponse(
      status: "incomplete", incomplete_details: .init(reason: "max_output_tokens"))
    #expect(responsesFinishReason(response, hasToolCalls: false).unified == .length)
  }
}

@Suite struct DeepSeekCompletionTests {
  @Test func sendsFIMRequestToBetaEndpoint() async throws {
    let client = MockHTTPClient([
      "\(base)/beta/completions": .jsonValue(try JSONValue(jsonString: try fixture("deepseek-fim.json")))
    ])
    let result = try await makeProvider(client).completion("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.user([.text(LanguageModelV4TextPart(text: "def fib(a):"))])], maxOutputTokens: 64,
        providerOptions: ["deepseek": ["suffix": "    return fib(a-1) + fib(a-2)"]]))

    #expect(
      client.lastRequest?.bodyJSON == [
        "model": "deepseek-flash", "prompt": "def fib(a):", "suffix": "    return fib(a-1) + fib(a-2)",
        "max_tokens": 64,
      ])
    guard case .text(let text)? = result.content.first else {
      Issue.record("expected text")
      return
    }
    #expect(text.text.contains("return"))
    #expect(result.usage.inputTokens.total != nil)
  }

  @Test func streamsRecordedFIM() async throws {
    let client = MockHTTPClient(["\(base)/beta/completions": .streamChunks([try fixture("deepseek-fim.sse.txt")])])
    let result = streamText(
      model: makeProvider(client).completion("deepseek-flash"), prompt: "def add(a, b):",
      providerOptions: ["deepseek": ["suffix": "\n\nprint(add(1, 2))"]])
    #expect(try await result.text.contains("return"))
    #expect(try await result.usage.inputTokens != nil)
    #expect(client.lastRequest?.bodyJSON?["stream_options"] == ["include_usage": true])
  }

  @Test func betaBaseURLIsNotDoubled() async throws {
    let client = MockHTTPClient([
      "\(base)/beta/completions": .jsonValue(try JSONValue(jsonString: try fixture("deepseek-fim.json")))
    ])
    _ = try await makeProvider(client, baseURL: "\(base)/beta").completion("deepseek-flash").doGenerate(
      LanguageModelV4CallOptions(prompt: testPrompt))
    #expect(client.lastRequest?.url.absoluteString == "\(base)/beta/completions")
  }

  @Test func rendersConversationsAsLabeledText() throws {
    let prompt: LanguageModelV4Prompt = [
      .system("be brief"),
      .user([.text(LanguageModelV4TextPart(text: "hi"))]),
      .assistant([.text(LanguageModelV4TextPart(text: "hello"))]),
      .user([.text(LanguageModelV4TextPart(text: "bye"))]),
    ]
    #expect(try convertToCompletionPrompt(prompt) == "be brief\n\nuser:\nhi\n\nassistant:\nhello\n\nuser:\nbye\n\nassistant:\n")
  }
}

@Suite struct DeepSeekAccountTests {
  @Test func listsModelsFromRecordedResponse() async throws {
    let client = MockHTTPClient(["\(base)/models": .jsonValue(try JSONValue(jsonString: try fixture("deepseek-models.json")))])
    let models = try await makeProvider(client).listModels()
    #expect(models.map(\.id).contains("deepseek-flash"))
    let flash = try #require(models.first { $0.id == "deepseek-flash" })
    #expect(flash.supportsImages)
    #expect(flash.effort?.supportedLevels == ["low", "high", "max"])
    #expect(flash.contextWindow == 1_048_576)
  }

  @Test func readsBalance() async throws {
    let client = MockHTTPClient([
      "\(base)/user/balance": .jsonValue([
        "is_available": true,
        "balance_infos": [
          ["currency": "CNY", "total_balance": "10.00", "granted_balance": "0.00", "topped_up_balance": "10.00"]
        ],
      ])
    ])
    let balance = try await makeProvider(client, baseURL: "\(base)/beta").balance()
    #expect(balance.isAvailable)
    #expect(balance.balanceInfos.first?.totalBalance == "10.00")
    #expect(client.lastRequest?.url.absoluteString == "\(base)/user/balance")
  }
}

@Suite struct DeepSeekFilesTests {
  let fileJSON: JSONValue = [
    "id": "file-api-1", "object": "file", "bytes": 168, "created_at": 1_790_480_818, "filename": "red.png",
    "purpose": "user_data", "expires_at": 1_790_484_418,
  ]

  @Test func uploadsMultipartForm() async throws {
    let client = MockHTTPClient(["\(base)/files": .jsonValue(fileJSON)])
    let file = try await makeProvider(client).files().upload(
      data: Data([1, 2, 3]), filename: "red.png", mediaType: "image/png", expiresAfterSeconds: 3600)

    #expect(file.id == "file-api-1")
    #expect(file.bytes == 168)
    #expect(file.expiresAt == Date(timeIntervalSince1970: 1_790_484_418))
    #expect(file.reference == ["deepseek": "file-api-1"])

    let request = try #require(client.lastRequest)
    let contentType = try #require(request.headers["content-type"])
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    let body = String(decoding: request.body ?? Data(), as: UTF8.self)
    #expect(body.contains("name=\"purpose\"\r\n\r\nuser_data"))
    #expect(body.contains("name=\"expires_after[seconds]\"\r\n\r\n3600"))
    #expect(body.contains("name=\"file\"; filename=\"red.png\"\r\nContent-Type: image/png"))
  }

  @Test func rejectsInvalidExpiry() async throws {
    await #expect(throws: InvalidArgumentError.self) {
      _ = try await makeProvider(MockHTTPClient()).files().upload(
        data: Data(), filename: "a.png", mediaType: "image/png", expiresAfterSeconds: 10)
    }
  }

  @Test func listsRetrievesAndDeletes() async throws {
    let client = MockHTTPClient([
      "\(base)/files?limit=2&order=desc": .jsonValue([
        "object": "list", "data": [fileJSON], "first_id": "file-api-1", "last_id": "file-api-1", "has_more": false,
      ]),
      "\(base)/files/file-api-1": .jsonValue(fileJSON),
    ])
    let files = makeProvider(client).files()
    let list = try await files.list(limit: 2, order: "desc")
    #expect(list.data.map(\.id) == ["file-api-1"])
    #expect(!list.hasMore)
    #expect(try await files.retrieve("file-api-1").filename == "red.png")

    client.respond(to: "\(base)/files/file-api-1", with: .jsonValue(["id": "file-api-1", "object": "file", "deleted": true]))
    #expect(try await files.delete("file-api-1"))
    #expect(client.lastRequest?.method == "DELETE")
  }
}
