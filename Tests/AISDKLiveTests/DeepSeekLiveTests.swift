import AISDK
import AISDKAnthropic
import AISDKDeepSeek
import Foundation
import Testing

// Live tests against the DeepSeek API. They cost money and need network, so
// they only run with `AISDK_LIVE_TESTS=1` and `DEEPSEEK_API_KEY` set:
//
//   AISDK_LIVE_TESTS=1 DEEPSEEK_API_KEY=sk-... swift test --filter AISDKLiveTests

let liveEnabled =
  ProcessInfo.processInfo.environment["AISDK_LIVE_TESTS"] == "1"
  && ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] != nil

let deepseek = createDeepSeek()
let deepseekBeta = createDeepSeek(DeepSeekProviderSettings(baseURL: "https://api.deepseek.com/beta"))
let flash = "deepseek-flash"

struct CityInput: Codable, Sendable { var city: String }

let weatherTool = tool(
  description: "Get the current weather for a city.",
  inputSchema: Schema(
    CityInput.self,
    jsonSchema: [
      "type": "object", "properties": ["city": ["type": "string", "description": "City name"]], "required": ["city"],
    ])
) { input, _ in
  ["city": .string(input.city), "condition": "sunny", "celsius": 23] as JSONValue
}

/// A 64x64 solid red PNG.
let redPNG: Data = {
  func crc32(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
  }
  func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let typeBytes = Array(type.utf8)
    let length = UInt32(body.count).bigEndianBytes
    return length + typeBytes + body + crc32(typeBytes + body).bigEndianBytes
  }
  func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65521
      b = (b + a) % 65521
    }
    return (b << 16) | a
  }
  let size = 64
  var raw: [UInt8] = []
  for _ in 0..<size { raw += [0] + Array(repeating: [255, 0, 0], count: size).flatMap { $0 } }
  // Stored (uncompressed) deflate blocks.
  var deflate: [UInt8] = [0x78, 0x01]
  var offset = 0
  while offset < raw.count {
    let blockSize = min(65535, raw.count - offset)
    let isLast: UInt8 = offset + blockSize >= raw.count ? 1 : 0
    deflate += [isLast, UInt8(blockSize & 0xFF), UInt8(blockSize >> 8), UInt8(~blockSize & 0xFF), UInt8((~blockSize >> 8) & 0xFF)]
    deflate += raw[offset..<(offset + blockSize)]
    offset += blockSize
  }
  deflate += adler32(raw).bigEndianBytes
  let header = UInt32(size).bigEndianBytes + UInt32(size).bigEndianBytes + [8, 2, 0, 0, 0]
  let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", deflate) + chunk("IEND", [])
  return Data(png)
}()

extension UInt32 {
  var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] }
}

@Suite(.enabled(if: liveEnabled), .serialized) struct DeepSeekAccountLiveTests {
  @Test func listsModelsAndBalance() async throws {
    let models = try await deepseek.listModels()
    #expect(models.contains { $0.id == flash })
    let balance = try await deepseek.balance()
    #expect(balance.isAvailable)
    #expect(!balance.balanceInfos.isEmpty)
  }

  @Test func invalidKeyIsNonRetryable401() async throws {
    let bad = createDeepSeek(DeepSeekProviderSettings(apiKey: "sk-invalid"))
    await #expect {
      _ = try await generateText(model: bad(flash), prompt: "hi", maxRetries: 0)
    } throws: { error in
      let error = error as? APICallError
      return error?.statusCode == 401 && error?.isRetryable == false
    }
  }
}

@Suite(.enabled(if: liveEnabled), .serialized) struct DeepSeekChatLiveTests {
  @Test func generatesTextWithoutThinking() async throws {
    let result = try await generateText(
      model: deepseek(flash), prompt: "Reply with exactly the word: pong", maxOutputTokens: 20,
      reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.text.lowercased().contains("pong"))
    #expect(result.reasoningText == nil)
    #expect(result.usage.inputTokens ?? 0 > 0)
    #expect(result.finishReason == .stop)
  }

  @Test func thinkingReturnsReasoning() async throws {
    let result = try await generateText(
      model: deepseek(flash), prompt: "Which is larger, 9.11 or 9.8? Answer with the number only.",
      maxOutputTokens: 2000, reasoning: .low)
    #expect(result.text.contains("9.8"))
    #expect(result.reasoningText?.isEmpty == false)
    #expect(result.usage.outputTokenDetails.reasoningTokens ?? 0 > 0)
  }

  @Test func streamsText() async throws {
    let result = streamText(
      model: deepseek(flash), prompt: "Count from 1 to 5, separated by spaces.", maxOutputTokens: 50,
      reasoning: LanguageModelV4ReasoningEffort.none)
    var deltas: [String] = []
    for try await delta in result.textStream { deltas.append(delta) }
    #expect(deltas.count > 1)
    let text = try await result.text
    #expect(text.contains("1") && text.contains("5"))
    #expect(try await result.finishReason == .stop)
  }

  @Test func multiStepToolLoopWithThinking() async throws {
    let result = try await generateText(
      model: deepseek(flash), prompt: "What's the weather in Hangzhou? Use the tool, then answer briefly.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(4)])
    #expect(result.steps.count >= 2)
    #expect(result.toolCalls.first?.toolName == "weather")
    #expect(result.toolResults.first?.output["city"]?.stringValue?.lowercased().contains("hangzhou") == true)
    #expect(result.text.contains("23"))
  }

  @Test func followUpTurnPassesReasoningBackWithTools() async throws {
    let first = try await generateText(
      model: deepseek(flash), prompt: "Weather in Beijing? Use the tool.", tools: ["weather": weatherTool],
      maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(4)])
    let messages: [ModelMessage] =
      [.user("Weather in Beijing? Use the tool.")] + first.responseMessages + [.user("And in Shanghai?")]
    let second = try await generateText(
      model: deepseek(flash), prompt: .messages(messages), tools: ["weather": weatherTool], maxOutputTokens: 2000,
      reasoning: .low, stopWhen: [.isStepCount(4)])
    #expect(second.toolCalls.contains { $0.input["city"]?.stringValue?.lowercased().contains("shanghai") == true })
    #expect(!second.text.isEmpty)
  }

  @Test func streamsToolLoop() async throws {
    let result = streamText(
      model: deepseek(flash), prompt: "Use the weather tool for Shenzhen, then answer in one sentence.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(4)])
    var types: Set<String> = []
    for try await part in result.fullStream { types.insert(part.type) }
    #expect(types.isSuperset(of: ["tool-input-start", "tool-call", "tool-result", "reasoning-delta", "text-delta"]))
    #expect(try await result.steps.count >= 2)
  }

  @Test func jsonMode() async throws {
    let result = try await deepseek(flash).doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.user([.text(LanguageModelV4TextPart(text: "Give a JSON object with keys name and age for Alice, 30."))])],
        maxOutputTokens: 300,
        responseFormat: .json(schema: ["type": "object", "properties": ["name": ["type": "string"], "age": ["type": "number"]]]),
        reasoning: LanguageModelV4ReasoningEffort.none))
    guard case .text(let text)? = result.content.first(where: { if case .text = $0 { true } else { false } }) else {
      Issue.record("expected text")
      return
    }
    let json = try JSONValue(jsonString: text.text)
    #expect(json["age"]?.intValue == 30)
  }

  @Test func inlineImageInput() async throws {
    let result = try await generateText(
      model: deepseek(flash),
      prompt: .messages([
        .user([
          .text(TextPart(text: "What single color fills this image? One word.")),
          .file(FilePart(data: .data(redPNG), mediaType: "image/png")),
        ])
      ]),
      maxOutputTokens: 20, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.text.lowercased().contains("red"))
  }

  @Test func uploadedFileInput() async throws {
    let files = deepseek.files()
    let file = try await files.upload(data: redPNG, filename: "red.png", mediaType: "image/png", expiresAfterSeconds: 3600)
    #expect(try await files.retrieve(file.id).bytes == redPNG.count)
    #expect(try await files.list(limit: 20, order: "desc").data.contains { $0.id == file.id })

    let result = try await generateText(
      model: deepseek(flash),
      prompt: .messages([
        .user([
          .text(TextPart(text: "What single color fills this image? One word.")),
          .file(FilePart(data: .reference(file.reference), mediaType: "image")),
        ])
      ]),
      maxOutputTokens: 20, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.text.lowercased().contains("red"))
    #expect(try await files.delete(file.id))
  }

  @Test func assistantPrefixCompletionOnBeta() async throws {
    let result = try await generateText(
      model: deepseekBeta(flash),
      prompt: .messages([
        .user("Write a Python function that adds two numbers."),
        .assistant("```python\n", providerOptions: ["deepseek": ["prefix": true]]),
      ]),
      maxOutputTokens: 100, stopSequences: ["```"], reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.text.contains("def "))
  }

  @Test func strictToolsOnBeta() async throws {
    var strictWeather = weatherTool
    strictWeather.strict = true
    strictWeather.inputSchema = jsonSchema([
      "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"], "additionalProperties": false,
    ])
    let result = try await generateText(
      model: deepseekBeta(flash), prompt: "Weather in Chengdu? Use the tool.", tools: ["weather": strictWeather],
      maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(3)])
    #expect(result.toolCalls.first?.input["city"] != nil)
  }

  @Test func contextCacheHitsOnRepeatedPrefix() async throws {
    let longPrefix = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 120)
    let prompt: Prompt = .messages([.user(longPrefix + "\nReply with: ok")])
    _ = try await generateText(model: deepseek(flash), prompt: prompt, maxOutputTokens: 5, reasoning: LanguageModelV4ReasoningEffort.none)
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let second = try await generateText(
      model: deepseek(flash), prompt: prompt, maxOutputTokens: 5, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(second.usage.inputTokenDetails.cacheReadTokens ?? 0 > 0)
    #expect(second.providerMetadata?["deepseek"]?["promptCacheHitTokens"]?.intValue ?? 0 > 0)
  }

  @Test func cancellingStreamAborts() async throws {
    let result = streamText(
      model: deepseek(flash), prompt: "Write a 500 word essay about the sea.", maxOutputTokens: 2000,
      reasoning: LanguageModelV4ReasoningEffort.none)
    var last: TextStreamPart?
    for try await part in result.fullStream {
      last = part
      if case .textDelta = part { result.cancel() }
    }
    #expect(last?.type == "abort")
  }
}

@Suite(.enabled(if: liveEnabled), .serialized) struct DeepSeekFIMLiveTests {
  @Test func fillsTheMiddle() async throws {
    let result = try await generateText(
      model: deepseek.completion(flash), prompt: "def fib(a):", maxOutputTokens: 64,
      providerOptions: ["deepseek": ["suffix": "    return fib(a-1) + fib(a-2)"]])
    #expect(result.text.contains("return"))
  }

  @Test func streamsFIM() async throws {
    let result = streamText(
      model: deepseek.completion(flash), prompt: "def add(a, b):", maxOutputTokens: 32,
      providerOptions: ["deepseek": ["suffix": "\n\nprint(add(1, 2))"]])
    #expect(try await result.text.contains("return"))
  }
}

@Suite(.enabled(if: liveEnabled), .serialized) struct DeepSeekResponsesLiveTests {
  @Test func generatesText() async throws {
    let result = try await generateText(
      model: deepseek.responses(flash), instructions: "Answer with the number only.", prompt: "What is 12 * 12?",
      maxOutputTokens: 1000, reasoning: .low)
    #expect(result.text.contains("144"))
  }

  @Test func streamsReasoningAndText() async throws {
    let result = streamText(
      model: deepseek.responses(flash), prompt: "Is 97 prime? Answer yes or no.", maxOutputTokens: 1500, reasoning: .low)
    var types: Set<String> = []
    for try await part in result.fullStream { types.insert(part.type) }
    #expect(types.contains("text-delta"))
    #expect(try await result.text.lowercased().contains("yes"))
  }

  @Test func toolLoop() async throws {
    let result = try await generateText(
      model: deepseek.responses(flash), prompt: "What's the weather in Wuhan? Use the tool, then answer briefly.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(4)])
    #expect(result.steps.count >= 2)
    #expect(result.toolCalls.first?.toolName == "weather")
    #expect(result.text.contains("23"))
  }

  @Test func streamingToolLoop() async throws {
    let result = streamText(
      model: deepseek.responses(flash), prompt: "Use the weather tool for Xiamen, then answer in one sentence.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, reasoning: .low, stopWhen: [.isStepCount(4)])
    #expect(try await result.steps.count >= 2)
    #expect(try await result.toolResults.first?.toolName == "weather")
  }

  @Test func structuredOutputWithJsonSchema() async throws {
    let schema: JSONSchema = [
      "type": "object",
      "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
      "required": ["name", "age"], "additionalProperties": false,
    ]
    let result = try await deepseek.responses(flash).doGenerate(
      LanguageModelV4CallOptions(
        prompt: [.user([.text(LanguageModelV4TextPart(text: "Extract: Bob is 41 years old."))])],
        maxOutputTokens: 500, responseFormat: .json(schema: schema, name: "person"),
        reasoning: LanguageModelV4ReasoningEffort.none))
    let text = result.content.compactMap { part -> String? in
      if case .text(let text) = part { return text.text }
      return nil
    }.joined()
    let json = try JSONValue(jsonString: text)
    #expect(json["name"] == "Bob")
    #expect(json["age"]?.intValue == 41)
  }

  @Test func imageInput() async throws {
    let result = try await generateText(
      model: deepseek.responses(flash),
      prompt: .messages([
        .user([
          .text(TextPart(text: "What single color fills this image? One word.")),
          .file(FilePart(data: .data(redPNG), mediaType: "image/png")),
        ])
      ]),
      maxOutputTokens: 50, reasoning: LanguageModelV4ReasoningEffort.none)
    #expect(result.text.lowercased().contains("red"))
  }
}

@Suite(.enabled(if: liveEnabled), .serialized) struct DeepSeekAnthropicLiveTests {
  let provider: AnthropicProvider = {
    try! createAnthropic(
      AnthropicProviderSettings(
        baseURL: "https://api.deepseek.com/anthropic/v1",
        apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], name: "deepseek.messages"))
  }()

  @Test func generatesTextWithThinking() async throws {
    let result = try await generateText(
      model: provider(flash), prompt: "What is 7 * 8? Number only.", maxOutputTokens: 1000)
    #expect(result.text.contains("56"))
  }

  @Test func streamsText() async throws {
    let result = streamText(model: provider(flash), prompt: "Say hello in French, one word.", maxOutputTokens: 500)
    #expect(try await result.text.lowercased().contains("bonjour"))
  }

  @Test func toolLoopSendsThinkingSignaturesBack() async throws {
    let result = try await generateText(
      model: provider(flash), prompt: "What's the weather in Nanjing? Use the tool, then answer briefly.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, stopWhen: [.isStepCount(4)])
    #expect(result.steps.count >= 2)
    #expect(result.text.contains("23"))
  }

  @Test func streamingToolLoop() async throws {
    let result = streamText(
      model: provider(flash), prompt: "Use the weather tool for Suzhou, then answer in one sentence.",
      tools: ["weather": weatherTool], maxOutputTokens: 2000, stopWhen: [.isStepCount(4)])
    #expect(try await result.steps.count >= 2)
  }
}
