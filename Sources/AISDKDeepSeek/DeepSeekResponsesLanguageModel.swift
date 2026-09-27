import AISDKProviderUtils
import Foundation

struct DeepSeekResponsesUsage: Decodable, Sendable {
  struct InputDetails: Decodable, Sendable { var cached_tokens: Int? }
  struct OutputDetails: Decodable, Sendable { var reasoning_tokens: Int? }

  var input_tokens: Int?
  var input_tokens_details: InputDetails?
  var output_tokens: Int?
  var output_tokens_details: OutputDetails?
  var total_tokens: Int?
}

struct DeepSeekResponsesOutputItem: Decodable, Sendable {
  struct Content: Decodable, Sendable {
    var type: String?
    var text: String?
    var logprobs: JSONValue?
  }

  var type: String
  var id: String?
  var status: String?
  var content: [Content]?
  var call_id: String?
  var name: String?
  var arguments: String?
  var input: String?
}

struct DeepSeekResponsesResponse: Decodable, Sendable {
  struct IncompleteDetails: Decodable, Sendable { var reason: String? }
  struct ErrorInfo: Decodable, Sendable {
    var code: String?
    var message: String?
  }

  var id: String?
  var created_at: Double?
  var model: String?
  var status: String?
  var error: ErrorInfo?
  var incomplete_details: IncompleteDetails?
  var output: [DeepSeekResponsesOutputItem]?
  var usage: DeepSeekResponsesUsage?
}

struct DeepSeekResponsesEvent: Decodable, Sendable {
  var type: String
  var response: DeepSeekResponsesResponse?
  var item: DeepSeekResponsesOutputItem?
  var item_id: String?
  var output_index: Int?
  var delta: String?
  var arguments: String?
  var message: String?
  var code: String?
}

/// DeepSeek through the OpenAI Responses API format (`POST /responses`).
///
/// The API is stateless: the full conversation is sent every time. Unlike
/// chat completions it supports `json_schema` structured output.
public struct DeepSeekResponsesLanguageModel: LanguageModelV4 {
  public let modelId: String
  let config: DeepSeekChatConfig

  public init(modelId: String, config: DeepSeekChatConfig) {
    self.modelId = modelId
    self.config = config
  }

  public var provider: String { "deepseek.responses" }

  public var supportedUrls: [String: [String]] {
    get async throws { ["image/*": ["^https?://.*$"]] }
  }

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message })
  }

  func getArgs(_ options: LanguageModelV4CallOptions) throws -> (args: JSONObject, warnings: [SharedV4Warning]) {
    let deepseekOptions =
      try parseProviderOptions(provider: "deepseek", providerOptions: options.providerOptions, as: DeepSeekChatOptions.self)
      ?? DeepSeekChatOptions()
    try deepseekOptions.validate()

    var warnings: [SharedV4Warning] = []
    if options.topK != nil { warnings.append(.unsupported(feature: "topK")) }
    if options.seed != nil { warnings.append(.unsupported(feature: "seed")) }
    if options.stopSequences != nil { warnings.append(.unsupported(feature: "stopSequences")) }
    if options.frequencyPenalty != nil { warnings.append(.unsupported(feature: "frequencyPenalty")) }
    if options.presencePenalty != nil { warnings.append(.unsupported(feature: "presencePenalty")) }

    let thinking = resolveDeepSeekThinking(
      modelId: modelId, supportsThinking: config.supportsThinking, thinkingType: deepseekOptions.thinking?.type,
      reasoningEffort: deepseekOptions.reasoningEffort, reasoning: options.reasoning, warnings: &warnings)
    let sampling = deepSeekSampling(
      temperature: options.temperature, topP: options.topP, isThinkingEnabled: thinking.isEnabled, warnings: &warnings)
    let effort: String? = thinking.type == "disabled" ? "none" : thinking.effort

    let input = try convertToResponsesInput(options.prompt, warnings: &warnings)

    var textFormat: JSONValue?
    if case .json(let schema, let name, let description)? = options.responseFormat {
      if let schema {
        textFormat = jsonObject([
          "type": "json_schema", "name": .string(name ?? "response"), "schema": schema.value,
          "description": .optional(description), "strict": .optional(deepseekOptions.strictJsonSchema),
        ])
      } else {
        textFormat = ["type": "json_object"]
      }
    }

    var tools: [JSONValue] = []
    for tool in options.tools ?? [] {
      switch tool {
      case .function(let function):
        tools.append(
          jsonObject([
            "type": "function", "name": .string(function.name), "description": .optional(function.description),
            "parameters": function.inputSchema.value, "strict": .optional(function.strict),
          ]))
      case .provider(let providerTool):
        warnings.append(.unsupported(feature: "provider-defined tool \(providerTool.id)"))
      }
    }
    let toolChoice: JSONValue? =
      switch options.toolChoice {
      case nil: nil
      case .some(.auto): "auto"
      case .some(.none): "none"
      case .some(.required): "required"
      case .some(.tool(let name)): ["type": "function", "name": .string(name)]
      }

    let args = jsonObject([
      "model": .string(modelId),
      "input": .array(input.items),
      "instructions": .optional(input.instructions),
      "max_output_tokens": .optional(options.maxOutputTokens),
      "temperature": .optional(sampling.temperature),
      "top_p": .optional(sampling.topP),
      "top_logprobs": .optional(deepseekOptions.topLogprobs),
      "reasoning": effort.map { ["effort": .string($0)] },
      "text": textFormat.map { ["format": $0] },
      "tools": tools.isEmpty ? nil : .array(tools),
      "tool_choice": tools.isEmpty ? nil : toolChoice,
      "user": .optional(deepseekOptions.userId),
    ])
    return (args.objectValue ?? [:], warnings)
  }

  private var responsesURL: String { config.url("/responses") }

  public func doGenerate(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4GenerateResult {
    let (args, warnings) = try getArgs(options)
    let response = try await postJsonToApi(
      url: responsesURL,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(args),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekResponsesResponse.self),
      httpClient: config.httpClient)

    let body = response.value
    if body.status == "failed" {
      throw APICallError(
        message: body.error?.message ?? "Response failed", url: responsesURL, requestBodyValues: .object(args),
        statusCode: 200, responseHeaders: response.responseHeaders, isRetryable: false, data: response.rawValue)
    }

    var content: [LanguageModelV4Content] = []
    var hasToolCalls = false
    for item in body.output ?? [] {
      switch item.type {
      case "reasoning":
        let text = (item.content ?? []).compactMap(\.text).joined()
        if !text.isEmpty { content.append(.reasoning(LanguageModelV4Reasoning(text: text))) }
      case "message":
        for part in item.content ?? [] where part.type == "output_text" {
          content.append(.text(LanguageModelV4Text(text: part.text ?? "")))
        }
      case "function_call":
        hasToolCalls = true
        content.append(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: item.call_id ?? config.generateId(), toolName: item.name ?? "",
              input: item.arguments ?? "{}")))
      default:
        continue
      }
    }

    return LanguageModelV4GenerateResult(
      content: content,
      finishReason: responsesFinishReason(body, hasToolCalls: hasToolCalls),
      usage: convertResponsesUsage(body.usage, raw: response.rawValue?["usage"]),
      providerMetadata: ["deepseek": ["responseId": .string(body.id ?? "")]],
      request: LanguageModelV4RequestInfo(body: .object(args)),
      response: LanguageModelV4ResponseInfo(
        metadata: createLanguageModelResponseMetadata(id: body.id, model: body.model, created: body.created_at),
        headers: response.responseHeaders, body: response.rawValue),
      warnings: warnings)
  }

  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let (args, warnings) = try getArgs(options)
    var body = args
    body["stream"] = true

    let response = try await postJsonToApi(
      url: responsesURL,
      headers: combineHeaders(try config.headers(), options.headers),
      body: .object(body),
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(DeepSeekResponsesEvent.self),
      httpClient: config.httpClient)

    let events = response.value
    let includeRawChunks = options.includeRawChunks == true
    let generateId = config.generateId
    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      let state = ResponsesStreamState(generateId: generateId)
      continuation.yield(.streamStart(warnings: warnings))
      do {
        for try await event in events {
          if includeRawChunks { continuation.yield(.raw(rawValue: event.rawValue ?? .null)) }
          state.process(event) { continuation.yield($0) }
        }
        state.finish { continuation.yield($0) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }

    return LanguageModelV4StreamResult(
      stream: stream, request: LanguageModelV4RequestInfo(body: .object(body)), responseHeaders: response.responseHeaders)
  }
}

func responsesFinishReason(_ response: DeepSeekResponsesResponse, hasToolCalls: Bool) -> LanguageModelV4FinishReason {
  switch response.status {
  case "completed":
    return LanguageModelV4FinishReason(unified: hasToolCalls ? .toolCalls : .stop, raw: "completed")
  case "incomplete":
    let reason = response.incomplete_details?.reason
    return LanguageModelV4FinishReason(
      unified: reason == "max_output_tokens" ? .length : reason == "content_filter" ? .contentFilter : .other,
      raw: reason ?? "incomplete")
  case "failed":
    return LanguageModelV4FinishReason(unified: .error, raw: "failed")
  default:
    return LanguageModelV4FinishReason(unified: .other, raw: response.status)
  }
}

func convertResponsesUsage(_ usage: DeepSeekResponsesUsage?, raw: JSONValue?) -> LanguageModelV4Usage {
  guard let usage else { return LanguageModelV4Usage() }
  let input = usage.input_tokens ?? 0
  let cached = usage.input_tokens_details?.cached_tokens ?? 0
  let output = usage.output_tokens ?? 0
  let reasoning = usage.output_tokens_details?.reasoning_tokens ?? 0
  return LanguageModelV4Usage(
    inputTokens: .init(total: input, noCache: input - cached, cacheRead: cached, cacheWrite: nil),
    outputTokens: .init(total: output, text: max(0, output - reasoning), reasoning: reasoning),
    raw: raw?.objectValue)
}

/// Converts a prompt to Responses API input items. System messages become
/// `instructions` when they lead the prompt, and `system` items otherwise.
func convertToResponsesInput(_ prompt: LanguageModelV4Prompt, warnings: inout [SharedV4Warning]) throws -> (
  instructions: String?, items: [JSONValue]
) {
  var items: [JSONValue] = []
  var leadingSystem: [String] = []

  for message in prompt {
    switch message {
    case .system(let text, _):
      if items.isEmpty {
        leadingSystem.append(text)
      } else {
        items.append(["role": "system", "content": .string(text)])
      }
    case .user(let parts, _):
      var content: [JSONValue] = []
      for part in parts {
        switch part {
        case .text(let text):
          content.append(["type": "input_text", "text": .string(text.text)])
        case .file(let file):
          content.append(try responsesImage(file))
        }
      }
      items.append(["role": "user", "content": .array(content)])
    case .assistant(let parts, _):
      var text: [JSONValue] = []
      func flushText() {
        if !text.isEmpty {
          items.append(["role": "assistant", "content": .array(text)])
          text = []
        }
      }
      for part in parts {
        switch part {
        case .text(let textPart):
          text.append(["type": "output_text", "text": .string(textPart.text)])
        case .reasoning(let reasoning):
          flushText()
          items.append([
            "type": "reasoning", "content": [["type": "reasoning_text", "text": .string(reasoning.text)]],
          ])
        case .toolCall(let call):
          flushText()
          items.append([
            "type": "function_call", "call_id": .string(call.toolCallId), "name": .string(call.toolName),
            "arguments": .string(call.input.jsonString()),
          ])
        default:
          warnings.append(.unsupported(feature: "assistant content part in Responses input"))
        }
      }
      flushText()
    case .tool(let parts, _):
      for case .toolResult(let result) in parts {
        let output: JSONValue
        switch result.output {
        case .text(let value, _), .errorText(let value, _): output = .string(value)
        case .json(let value, _), .errorJSON(let value, _): output = .string(value.jsonString())
        case .executionDenied(let reason, _): output = .string(reason ?? "Tool call execution denied.")
        case .content(let contentParts):
          output = .array(
            try contentParts.compactMap { part in
              switch part {
              case .text(let text, _):
                return ["type": "input_text", "text": .string(text)]
              case .file(let data, let mediaType, let filename, let options):
                return try responsesImage(
                  LanguageModelV4FilePart(data: data, mediaType: mediaType, filename: filename, providerOptions: options))
              case .custom:
                warnings.append(.unsupported(feature: "custom tool result content"))
                return nil
              }
            })
        }
        items.append(["type": "function_call_output", "call_id": .string(result.toolCallId), "output": output])
      }
    }
  }

  return (leadingSystem.isEmpty ? nil : leadingSystem.joined(separator: "\n\n"), items)
}

private func responsesImage(_ part: LanguageModelV4FilePart) throws -> JSONValue {
  guard getTopLevelMediaType(part.mediaType) == "image" else {
    throw UnsupportedFunctionalityError(
      functionality: "file input of type \(part.mediaType)",
      message: "The DeepSeek Responses API only accepts image files.")
  }
  let detail = part.providerOptions?["deepseek"]?["imageDetail"]
  switch part.data {
  case .reference(let reference):
    return ["type": "input_image", "file_id": .string(try resolveProviderReference(reference, provider: "deepseek"))]
  case .url(let url, _):
    return jsonObject(["type": "input_image", "image_url": .string(url.absoluteString), "detail": detail])
  case .data, .base64:
    let mediaType = try resolveFullMediaType(part)
    return jsonObject([
      "type": "input_image", "image_url": .string("data:\(mediaType);base64,\(part.data.base64String ?? "")"),
      "detail": detail,
    ])
  case .text:
    throw UnsupportedFunctionalityError(functionality: "text file input")
  }
}

/// Converts Responses API stream events into stream parts.
private final class ResponsesStreamState: @unchecked Sendable {
  enum Item {
    case reasoning
    case message
    case functionCall(callId: String, name: String, arguments: String)
  }

  let generateId: IdGenerator
  var items: [String: Item] = [:]
  var finalResponse: DeepSeekResponsesResponse?
  var rawUsage: JSONValue?
  var hasToolCalls = false
  var didFail = false

  init(generateId: @escaping IdGenerator) {
    self.generateId = generateId
  }

  func process(_ chunk: ParseResult<DeepSeekResponsesEvent>, emit: (LanguageModelV4StreamPart) -> Void) {
    guard case .success(let event, let raw) = chunk else {
      emit(.error(chunk.error ?? NoContentGeneratedError()))
      return
    }

    switch event.type {
    case "response.created":
      if let response = event.response {
        emit(
          .responseMetadata(
            createLanguageModelResponseMetadata(id: response.id, model: response.model, created: response.created_at)))
      }

    case "response.output_item.added":
      guard let item = event.item, let id = item.id else { return }
      switch item.type {
      case "reasoning":
        items[id] = .reasoning
        emit(.reasoningStart(id: id))
      case "message":
        items[id] = .message
        emit(.textStart(id: id))
      case "function_call":
        let callId = item.call_id ?? generateId()
        items[id] = .functionCall(callId: callId, name: item.name ?? "", arguments: item.arguments ?? "")
        hasToolCalls = true
        emit(.toolInputStart(LanguageModelV4ToolInputStart(id: callId, toolName: item.name ?? "")))
      default:
        return
      }

    case "response.reasoning_text.delta":
      if let id = event.item_id, let delta = event.delta { emit(.reasoningDelta(id: id, delta: delta)) }

    case "response.output_text.delta":
      if let id = event.item_id, let delta = event.delta { emit(.textDelta(id: id, delta: delta)) }

    case "response.function_call_arguments.delta":
      guard let id = event.item_id, let delta = event.delta,
        case .functionCall(let callId, let name, let arguments)? = items[id]
      else { return }
      items[id] = .functionCall(callId: callId, name: name, arguments: arguments + delta)
      emit(.toolInputDelta(id: callId, delta: delta))

    case "response.output_item.done":
      guard let item = event.item, let id = item.id, let tracked = items[id] else { return }
      switch tracked {
      case .reasoning:
        emit(.reasoningEnd(id: id))
      case .message:
        emit(.textEnd(id: id))
      case .functionCall(let callId, let name, let arguments):
        let finalArguments = item.arguments ?? arguments
        emit(.toolInputEnd(id: callId))
        emit(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: callId, toolName: name, input: finalArguments.isEmpty ? "{}" : finalArguments)))
      }
      items.removeValue(forKey: id)

    case "response.completed", "response.incomplete", "response.failed":
      finalResponse = event.response
      rawUsage = raw["response"]?["usage"]
      if event.type == "response.failed" {
        didFail = true
        emit(
          .error(
            ProviderStreamError(
              message: event.response?.error?.message ?? "Response failed", type: event.response?.error?.code,
              isRetryable: false, data: raw)))
      }

    case "error":
      emit(.error(ProviderStreamError(message: event.message ?? "Stream error", type: event.code, data: raw)))

    default:
      return
    }
  }

  func finish(emit: (LanguageModelV4StreamPart) -> Void) {
    let finishReason =
      finalResponse.map { responsesFinishReason($0, hasToolCalls: hasToolCalls) }
      ?? LanguageModelV4FinishReason(unified: didFail ? .error : .other)
    emit(
      .finish(
        usage: convertResponsesUsage(finalResponse?.usage, raw: rawUsage), finishReason: finishReason,
        providerMetadata: finalResponse?.id.map { ["deepseek": ["responseId": .string($0)]] }))
  }
}
