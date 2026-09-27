import AISDKProviderUtils
import Foundation

/// Converts Anthropic stream events into stream parts. Mirrors the transform
/// in upstream `AnthropicLanguageModel.doStream`.
final class AnthropicStreamState: @unchecked Sendable {
  private struct ToolCallBlock {
    var toolCallId: String
    var toolName: String
    var input: String
    var providerExecuted: Bool?
    var dynamic: Bool?
    var firstDelta: Bool
    var providerToolName: String?
    var providerToolInputType: String?
    var toolset: (name: String, memberName: String)?
    var caller: JSONValue?
  }

  private enum Block {
    case text(citations: [JSONValue])
    case reasoning
    case toolCall(ToolCallBlock)
  }

  private let usesJsonResponseTool: Bool
  private let includeRawChunks: Bool
  private let generateId: IdGenerator
  private let toolNameMapping: ToolNameMapping
  private let markCodeExecutionDynamic: Bool
  private let makeProviderMetadata: (JSONObject) -> SharedV4ProviderMetadata
  private var converter: AnthropicContentConverter

  private var blocks: [Int: Block] = [:]
  private var blockType: String?
  private var isJsonResponseFromTool = false
  private var isMessageOpen = false
  private var activeMessageId: JSONValue?
  private var hasInvalidMessageSequence = false
  private var usage = AnthropicUsage(input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
  private var rawUsage: JSONObject?
  private var finishReason = LanguageModelV4FinishReason(unified: .other)
  private var stopSequence: JSONValue = .null
  private var stopDetails: JSONValue?
  private var inputTransformations: JSONValue?
  private var safeguardResults: JSONValue?
  private var container: JSONValue = .null
  private var contextManagement: JSONValue = .null
  private var iterations: JSONValue?

  init(
    usesJsonResponseTool: Bool, includeRawChunks: Bool, generateId: @escaping IdGenerator,
    toolNameMapping: ToolNameMapping, citationDocuments: [AnthropicCitationDocument], markCodeExecutionDynamic: Bool,
    providerMetadata: @escaping (JSONObject) -> SharedV4ProviderMetadata
  ) {
    self.usesJsonResponseTool = usesJsonResponseTool
    self.includeRawChunks = includeRawChunks
    self.generateId = generateId
    self.toolNameMapping = toolNameMapping
    self.markCodeExecutionDynamic = markCodeExecutionDynamic
    self.makeProviderMetadata = providerMetadata
    self.converter = AnthropicContentConverter(
      toolNameMapping: toolNameMapping, generateId: generateId, citationDocuments: citationDocuments)
  }

  func process(_ chunk: ParseResult<JSONValue>, emit: (LanguageModelV4StreamPart) -> Void) {
    if hasInvalidMessageSequence { return }
    if includeRawChunks { emit(.raw(rawValue: chunk.rawValue ?? .null)) }
    guard case .success(let value, _) = chunk else {
      emit(.error(chunk.error ?? NoContentGeneratedError()))
      return
    }

    switch value["type"]?.stringValue {
    case "content_block_start":
      contentBlockStart(value, emit: emit)
    case "content_block_stop":
      contentBlockStop(value, emit: emit)
    case "content_block_delta":
      contentBlockDelta(value, emit: emit)
    case "message_start":
      messageStart(value, emit: emit)
    case "message_delta":
      messageDelta(value)
    case "message_stop":
      messageStop(emit: emit)
    case "error":
      let error = value["error"] ?? [:]
      emit(.error(createAnthropicStreamError(error)))
    default:
      return
    }
  }

  // MARK: Blocks

  private func contentBlockStart(_ value: JSONValue, emit: (LanguageModelV4StreamPart) -> Void) {
    guard let index = value["index"]?.intValue, let part = value["content_block"] else { return }
    let type = part["type"]?.stringValue
    if type == "fallback" { return }
    blockType = type
    let id = String(index)

    switch type {
    case "text":
      guard !usesJsonResponseTool else { return }
      blocks[index] = .text(citations: [])
      emit(.textStart(id: id))
    case "thinking":
      blocks[index] = .reasoning
      emit(.reasoningStart(id: id))
    case "redacted_thinking":
      blocks[index] = .reasoning
      emit(.reasoningStart(id: id, providerMetadata: ["anthropic": ["redactedData": part["data"] ?? .null]]))
    case "compaction":
      blocks[index] = .text(citations: [])
      let signature = part["signature"].flatMap { $0.isNull ? nil : $0 }
      emit(
        .textStart(
          id: id,
          providerMetadata: ["anthropic": jsonObject(["type": "compaction", "signature": signature]).objectValue ?? [:]]))
      if signature != nil, let text = part["content"]?.stringValue, !text.isEmpty {
        emit(.textDelta(id: id, delta: text))
      }
    case "tool_use":
      toolUseStart(part, index: index, emit: emit)
    case "server_tool_use":
      serverToolUseStart(part, index: index, emit: emit)
    default:
      if let parts = converter.convert(part) {
        for content in parts {
          if let streamPart = streamPart(content) { emit(streamPart) }
        }
      }
    }
  }

  private func streamPart(_ content: LanguageModelV4Content) -> LanguageModelV4StreamPart? {
    switch content {
    case .toolCall(let call): .toolCall(call)
    case .toolResult(let result): .toolResult(result)
    case .source(let source): .source(source)
    default: nil
    }
  }

  private func hasNonEmptyInput(_ input: JSONValue?) -> Bool {
    input?.objectValue?.isEmpty == false
  }

  private func toolUseStart(_ part: JSONValue, index: Int, emit: (LanguageModelV4StreamPart) -> Void) {
    let name = part["name"]?.stringValue ?? ""
    let id = part["id"]?.stringValue ?? ""
    if usesJsonResponseTool && name == "json" {
      isJsonResponseFromTool = true
      blocks[index] = .text(citations: [])
      emit(.textStart(id: String(index)))
      return
    }
    let caller = anthropicCallerInfo(part["caller"])
    let initialInput = hasNonEmptyInput(part["input"]) ? part["input"]!.jsonString() : ""
    if let toolset = part["toolset_name"]?.stringValue {
      let toolName = toolNameMapping.toCustomToolName(toolset)
      blocks[index] = .toolCall(
        ToolCallBlock(
          toolCallId: id, toolName: toolName, input: initialInput, firstDelta: true, toolset: (toolset, name),
          caller: caller))
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: toolName)))
    } else {
      blocks[index] = .toolCall(
        ToolCallBlock(
          toolCallId: id, toolName: name, input: initialInput, firstDelta: initialInput.isEmpty, caller: caller))
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: name)))
    }
  }

  private func serverToolUseStart(_ part: JSONValue, index: Int, emit: (LanguageModelV4StreamPart) -> Void) {
    let name = part["name"]?.stringValue ?? ""
    let id = part["id"]?.stringValue ?? ""
    let caller = anthropicCallerInfo(part["caller"])
    switch name {
    case "web_fetch", "web_search", "code_execution", "text_editor_code_execution", "bash_code_execution":
      let isSubtool = name == "text_editor_code_execution" || name == "bash_code_execution"
      let providerToolName = isSubtool ? "code_execution" : name
      let inputType: String? = isSubtool ? name : (name == "code_execution" ? "programmatic-tool-call" : nil)
      let toolName = toolNameMapping.toCustomToolName(providerToolName)
      let finalInput = hasNonEmptyInput(part["input"]) ? part["input"]!.jsonString() : ""
      let dynamic: Bool? = markCodeExecutionDynamic && providerToolName == "code_execution" ? true : nil
      blocks[index] = .toolCall(
        ToolCallBlock(
          toolCallId: id, toolName: toolName, input: finalInput, providerExecuted: true, dynamic: dynamic,
          firstDelta: finalInput.isEmpty, providerToolName: providerToolName, providerToolInputType: inputType,
          caller: caller))
      emit(
        .toolInputStart(
          LanguageModelV4ToolInputStart(id: id, toolName: toolName, providerExecuted: true, dynamic: dynamic)))
    case "tool_search_tool_regex", "tool_search_tool_bm25":
      converter.serverToolCalls[id] = name
      let toolName = toolNameMapping.toCustomToolName(name)
      blocks[index] = .toolCall(
        ToolCallBlock(
          toolCallId: id, toolName: toolName, input: "", providerExecuted: true, firstDelta: true,
          providerToolName: name, caller: caller))
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: toolName, providerExecuted: true)))
    case "advisor":
      let toolName = toolNameMapping.toCustomToolName("advisor")
      blocks[index] = .toolCall(
        ToolCallBlock(
          toolCallId: id, toolName: toolName, input: "{}", providerExecuted: true, firstDelta: true,
          providerToolName: name, caller: caller))
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: toolName, providerExecuted: true)))
    default:
      return
    }
  }

  private func contentBlockStop(_ value: JSONValue, emit: (LanguageModelV4StreamPart) -> Void) {
    defer { blockType = nil }
    guard let index = value["index"]?.intValue, let block = blocks[index] else { return }
    let id = String(index)
    switch block {
    case .text(let citations):
      emit(.textEnd(id: id, providerMetadata: citations.isEmpty ? nil : ["anthropic": ["citations": .array(citations)]]))
    case .reasoning:
      emit(.reasoningEnd(id: id))
    case .toolCall(var call):
      guard !(usesJsonResponseTool && call.toolName == "json") else { break }
      if let toolset = call.toolset {
        if let memberInput = call.input.isEmpty ? [:] : try? JSONValue(jsonString: call.input) {
          call.input = toolsetMemberInput(memberName: toolset.memberName, input: memberInput).jsonString()
        }
        emit(.toolInputDelta(id: call.toolCallId, delta: call.input))
      }
      emit(.toolInputEnd(id: call.toolCallId))
      var finalInput = call.input.isEmpty ? "{}" : call.input
      if call.providerToolName == "code_execution", var parsed = (try? JSONValue(jsonString: finalInput))?.objectValue,
        parsed["code"] != nil, parsed["type"] == nil
      {
        parsed["type"] = "programmatic-tool-call"
        finalInput = JSONValue.object(parsed).jsonString()
      }
      var metadata: JSONObject = [:]
      if let toolset = call.toolset { metadata["toolsetName"] = .string(toolset.name) }
      if let caller = call.caller { metadata["caller"] = caller }
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: call.toolCallId, toolName: call.toolName, input: finalInput,
            providerExecuted: call.providerExecuted, dynamic: call.dynamic,
            providerMetadata: metadata.isEmpty ? nil : ["anthropic": metadata])))
    }
    blocks.removeValue(forKey: index)
  }

  private func contentBlockDelta(_ value: JSONValue, emit: (LanguageModelV4StreamPart) -> Void) {
    guard let index = value["index"]?.intValue, let delta = value["delta"] else { return }
    let id = String(index)
    switch delta["type"]?.stringValue {
    case "text_delta":
      guard !usesJsonResponseTool else { return }
      emit(.textDelta(id: id, delta: delta["text"]?.stringValue ?? ""))
    case "thinking_delta":
      emit(.reasoningDelta(id: id, delta: delta["thinking"]?.stringValue ?? ""))
    case "signature_delta":
      if blockType == "thinking" {
        emit(.reasoningDelta(id: id, delta: "", providerMetadata: ["anthropic": ["signature": delta["signature"] ?? .null]]))
      }
    case "compaction_delta":
      if let text = delta["content"]?.stringValue {
        emit(.textDelta(id: id, delta: text))
      }
    case "input_json_delta":
      guard var partial = delta["partial_json"]?.stringValue, !partial.isEmpty else { return }
      if isJsonResponseFromTool {
        guard case .text? = blocks[index] else { return }
        emit(.textDelta(id: id, delta: partial))
        return
      }
      guard case .toolCall(var call)? = blocks[index] else { return }
      if call.toolset != nil {
        call.input += partial
        blocks[index] = .toolCall(call)
        return
      }
      if call.firstDelta, let inputType = call.providerToolInputType {
        partial = "{\"type\": \"\(inputType)\",\(partial.dropFirst())"
      }
      emit(.toolInputDelta(id: call.toolCallId, delta: partial))
      call.input += partial
      call.firstDelta = false
      blocks[index] = .toolCall(call)
    case "citations_delta":
      guard let rawCitation = delta["citation"] else { return }
      let citation = normalizeCitation(rawCitation)
      if case .text(let citations)? = blocks[index], citation["type"] == "web_search_result_location" {
        blocks[index] = .text(citations: citations + [citation])
      }
      if let source = createCitationSource(citation, documents: converter.citationDocuments, generateId: generateId) {
        emit(.source(source))
      }
    default:
      return
    }
  }

  // MARK: Messages

  private func messageStart(_ value: JSONValue, emit: (LanguageModelV4StreamPart) -> Void) {
    guard let message = value["message"] else { return }
    if isMessageOpen {
      if activeMessageId == message["id"] { return }
      hasInvalidMessageSequence = true
      emit(
        .error(
          InvalidResponseDataError(
            data: value,
            message:
              "Received message_start for message \((message["id"] ?? .null).jsonString()) while message \((activeMessageId ?? .null).jsonString()) is still open."
          )))
      return
    }
    isMessageOpen = true
    activeMessageId = message["id"]

    let messageUsage = message["usage"]
    usage.input_tokens = messageUsage?["input_tokens"]?.intValue
    usage.cache_read_input_tokens = messageUsage?["cache_read_input_tokens"]?.intValue ?? 0
    usage.cache_creation_input_tokens = messageUsage?["cache_creation_input_tokens"]?.intValue ?? 0
    rawUsage = messageUsage?.objectValue ?? [:]
    if let transformations = normalizeInputTransformations(message["input_transformations"]) {
      inputTransformations = transformations
    }
    if let messageContainer = message["container"], !messageContainer.isNull {
      container = anthropicContainerMetadata(messageContainer, includeSkills: false)
    }
    if let stopReason = message["stop_reason"]?.stringValue {
      finishReason = LanguageModelV4FinishReason(
        unified: mapAnthropicStopReason(stopReason, isJsonResponseFromTool: isJsonResponseFromTool), raw: stopReason)
    }
    emit(.responseMetadata(LanguageModelV4ResponseMetadata(id: message["id"]?.stringValue, modelId: message["model"]?.stringValue)))

    for part in message["content"]?.arrayValue ?? [] where part["type"] == "tool_use" {
      let id = part["id"]?.stringValue ?? ""
      let name = part["name"]?.stringValue ?? ""
      let input = (part["input"].flatMap { $0.isNull ? nil : $0 } ?? [:]).jsonString()
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: name)))
      emit(.toolInputDelta(id: id, delta: input))
      emit(.toolInputEnd(id: id))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: id, toolName: name, input: input, providerMetadata: anthropicCallerMetadata(part["caller"]))))
    }
  }

  private func messageDelta(_ value: JSONValue) {
    let deltaUsage = value["usage"]
    if let input = deltaUsage?["input_tokens"]?.intValue { usage.input_tokens = input }
    usage.output_tokens = deltaUsage?["output_tokens"]?.intValue
    if let details = deltaUsage?["output_tokens_details"], !details.isNull {
      usage.output_tokens_details = AnthropicUsage.OutputTokensDetails(thinking_tokens: details["thinking_tokens"]?.intValue)
    }
    if let cacheRead = deltaUsage?["cache_read_input_tokens"]?.intValue { usage.cache_read_input_tokens = cacheRead }
    if let cacheCreation = deltaUsage?["cache_creation_input_tokens"]?.intValue {
      usage.cache_creation_input_tokens = cacheCreation
    }
    if let deltaIterations = deltaUsage?["iterations"], !deltaIterations.isNull {
      iterations = deltaIterations
      usage.iterations = try? deltaIterations.decode(as: [AnthropicUsage.Iteration].self)
    }

    let delta = value["delta"]
    let stopReason = delta?["stop_reason"]?.stringValue
    finishReason = LanguageModelV4FinishReason(
      unified: mapAnthropicStopReason(stopReason, isJsonResponseFromTool: isJsonResponseFromTool), raw: stopReason)
    stopSequence = delta?["stop_sequence"].flatMap { $0.isNull ? nil : $0 } ?? .null
    stopDetails = anthropicStopDetailsMetadata(delta?["stop_details"])
    container = anthropicContainerMetadata(delta?["container"])
    if let management = anthropicContextManagementMetadata(value["context_management"]) {
      contextManagement = management
    }
    if let transformations = normalizeInputTransformations(value["input_transformations"]) {
      inputTransformations = transformations
    }
    if let results = normalizeSafeguardResults(delta?["safeguard_results"]) {
      safeguardResults = results
    }
    var merged = rawUsage ?? [:]
    for (key, field) in normalizeRawUsage(deltaUsage?.objectValue ?? [:]) { merged[key] = field }
    rawUsage = merged
  }

  private func messageStop(emit: (LanguageModelV4StreamPart) -> Void) {
    isMessageOpen = false
    activeMessageId = nil
    let metadata = jsonObject([
      "usage": rawUsage.map(JSONValue.object) ?? .null,
      "stopSequence": stopSequence,
      "stopDetails": stopDetails,
      "inputTransformations": inputTransformations,
      "safeguardResults": safeguardResults,
      "iterations": anthropicIterationsMetadata(iterations),
      "container": container,
      "contextManagement": contextManagement,
    ])
    emit(
      .finish(
        usage: convertAnthropicUsage(usage, raw: rawUsage), finishReason: finishReason,
        providerMetadata: makeProviderMetadata(metadata.objectValue ?? [:])))
  }
}

/// Classifies a stream error, keeping explicit status and retry hints. Mirrors upstream `createAnthropicStreamError`.
func createAnthropicStreamError(_ error: JSONValue) -> ProviderStreamError {
  let type = error["type"]?.stringValue ?? ""
  let inferred = createAnthropicStreamError(type: type, message: "", data: nil)
  return ProviderStreamError(
    message: error["message"]?.stringValue ?? "", type: type,
    code: error["code"].flatMap { $0.isNull ? nil : $0 },
    statusCode: error["statusCode"]?.intValue ?? inferred.statusCode,
    isRetryable: error["isRetryable"]?.boolValue ?? inferred.isRetryable,
    data: error["data"] ?? error)
}
