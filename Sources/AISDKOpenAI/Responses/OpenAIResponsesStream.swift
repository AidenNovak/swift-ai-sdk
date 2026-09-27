import AISDKProviderUtils
import Foundation

/// Escapes text for embedding inside a JSON string literal. Mirrors upstream `escapeJSONDelta`.
func escapeJSONDelta(_ delta: String) -> String {
  String(JSONValue.string(delta).jsonString().dropFirst().dropLast())
}

private func isOutputChunk(_ chunk: JSONValue) -> Bool {
  switch chunk["type"]?.stringValue {
  case "response.created", "response.in_progress", "response.failed", "error", nil: false
  default: true
  }
}

private func isChatCompletionChunk(_ value: JSONValue) -> Bool {
  guard case .object(let object) = value, case .array? = object["choices"] else { return false }
  return object["type"]?.stringValue == nil
}

extension OpenAIResponsesLanguageModel {
  public func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult {
    let request = try prepareRequest(options)
    var body = request.args
    body["stream"] = true
    let url = config.url("/responses")

    let response = try await postJsonToApi(
      url: url, headers: combineHeaders(try config.headers(), options.headers), body: .object(body),
      failedResponseHandler: openaiFailedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(JSONValue.self), httpClient: config.httpClient)

    let chunks = try await throwIfOpenAIStreamErrorBeforeOutput(
      stream: response.value,
      getError: { chunk in
        let type = chunk["type"]?.stringValue
        if type == "error" { return chunk }
        if type == "response.failed", let error = chunk["response"]?["error"], error != .null { return chunk }
        return nil
      },
      isOutputChunk: isOutputChunk,
      isAcceptedChunk: { $0["type"]?.stringValue == "response.in_progress" },
      url: url, requestBodyValues: .object(body), responseHeaders: response.responseHeaders)

    let functionTools = (options.tools ?? []).compactMap { tool -> LanguageModelV4FunctionTool? in
      if case .function(let function) = tool { return function }
      return nil
    }
    let state = OpenAIResponsesStreamState(
      request: request, functionTools: functionTools,
      approvalMappingFromPrompt: extractApprovalRequestIdToToolCallIdMapping(options.prompt),
      wantsLogprobs: options.providerOptions?[request.providerOptionsName]?["logprobs"].map {
        $0 != .bool(false) && $0 != .null
      } ?? false,
      generateId: config.generateId, url: url, requestBody: .object(body), responseHeaders: response.responseHeaders)
    let includeRawChunks = options.includeRawChunks == true
    let warnings = request.warnings

    let (stream, continuation) = LanguageModelV4Stream.makeStream()
    let task = Task {
      continuation.yield(.streamStart(warnings: warnings))
      do {
        for try await chunk in chunks {
          if includeRawChunks { continuation.yield(.raw(rawValue: chunk.rawValue ?? .null)) }
          state.process(chunk) { continuation.yield($0) }
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

/// Mutable state for converting Responses API events into stream parts.
/// Mirrors the transform in upstream `OpenAIResponsesLanguageModel.doStream`.
final class OpenAIResponsesStreamState: @unchecked Sendable {
  private struct OngoingToolCall {
    var toolName: String
    var toolCallId: String
    var codeInterpreterContainerId: String?
    var applyPatch: (hasDiff: Bool, endEmitted: Bool)?
    var toolSearchExecution: String?
    var suppressInputStreaming = false
    var bufferedInputDeltas: [String] = []
    var async: JSONValue?
  }

  private enum SummaryStatus {
    case active, canConclude, concluded
  }

  private struct ActiveReasoning {
    var encryptedContent: JSONValue?
    var summaryParts: [Int: SummaryStatus]
  }

  typealias Emit = (LanguageModelV4StreamPart) -> Void

  private let request: OpenAIResponsesRequest
  private let name: String
  private let mapping: ToolNameMapping
  private let functionTools: [LanguageModelV4FunctionTool]
  private let approvalMappingFromPrompt: [String: String]
  private let wantsLogprobs: Bool
  private let generateId: IdGenerator
  private let url: String
  private let requestBody: JSONValue
  private let responseHeaders: [String: String]?

  private var approvalMappingFromStream: [String: String] = [:]
  private var finishReason = LanguageModelV4FinishReason(unified: .other)
  private var usage: JSONValue?
  private var logprobs: [JSONValue] = []
  private var responseId: JSONValue = .null
  private var ongoingToolCalls: [Int: OngoingToolCall] = [:]
  private var ongoingAnnotations: [JSONValue] = []
  private var activeMessagePhase: JSONValue?
  private var hasFunctionCall = false
  private var activeReasoning: [String: ActiveReasoning] = [:]
  private var activeOutputItemIds: [Int: String] = [:]
  private var serviceTier: String?
  private var reasoningContext: JSONValue?
  private var hostedToolSearchCallIds: [String] = []
  private var encounteredStreamError = false

  init(
    request: OpenAIResponsesRequest, functionTools: [LanguageModelV4FunctionTool],
    approvalMappingFromPrompt: [String: String], wantsLogprobs: Bool, generateId: @escaping IdGenerator, url: String,
    requestBody: JSONValue, responseHeaders: [String: String]?
  ) {
    self.request = request
    self.name = request.providerOptionsName
    self.mapping = request.toolNameMapping
    self.functionTools = functionTools
    self.approvalMappingFromPrompt = approvalMappingFromPrompt
    self.wantsLogprobs = wantsLogprobs
    self.generateId = generateId
    self.url = url
    self.requestBody = requestBody
    self.responseHeaders = responseHeaders
  }

  private var webSearchToolName: String { mapping.toCustomToolName(request.webSearchToolName ?? "web_search") }

  private func resolveItemId(_ itemId: String, _ outputIndex: Int?) -> String {
    guard let outputIndex else { return itemId }
    return activeOutputItemIds[outputIndex] ?? itemId
  }

  private func itemMetadata(_ item: JSONValue) -> SharedV4ProviderMetadata {
    [name: ["itemId": item["id"] ?? .null]]
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func process(_ chunk: ParseResult<JSONValue>, emit: Emit) {
    guard case .success(let value, _) = chunk else {
      encounteredStreamError = true
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(.error(chunk.error ?? NoContentGeneratedError()))
      return
    }
    if isChatCompletionChunk(value) {
      encounteredStreamError = true
      finishReason = LanguageModelV4FinishReason(unified: .error)
      emit(
        .error(
          APICallError(
            message:
              "Received a Chat Completions stream while using the OpenAI Responses API. The default OpenAI provider model uses the Responses API. If your custom baseURL targets a Chat Completions-compatible endpoint, use openai.chat('model-id') or createOpenAI(...).chat('model-id') instead. You can also use @ai-sdk/openai-compatible for OpenAI-compatible providers.",
            url: url, requestBodyValues: requestBody, responseHeaders: responseHeaders,
            responseBody: value.jsonString(sortedKeys: false), isRetryable: false, data: value)))
      return
    }

    let outputIndex = value["output_index"]?.intValue
    switch value["type"]?.stringValue {
    case "response.output_item.added":
      guard let item = value["item"], let outputIndex else { return }
      outputItemAdded(item, outputIndex: outputIndex, emit: emit)

    case "response.output_item.done":
      guard let item = value["item"], let outputIndex else { return }
      outputItemDone(item, outputIndex: outputIndex, emit: emit)

    case "response.function_call_arguments.delta":
      guard let outputIndex, var toolCall = ongoingToolCalls[outputIndex], let delta = value["delta"]?.stringValue else {
        return
      }
      if toolCall.suppressInputStreaming {
        toolCall.bufferedInputDeltas.append(delta)
        ongoingToolCalls[outputIndex] = toolCall
      } else {
        emit(.toolInputDelta(id: toolCall.toolCallId, delta: delta))
      }

    case "response.custom_tool_call_input.delta":
      guard let outputIndex, let toolCall = ongoingToolCalls[outputIndex], let delta = value["delta"]?.stringValue else {
        return
      }
      emit(.toolInputDelta(id: toolCall.toolCallId, delta: delta))

    case "response.apply_patch_call_operation_diff.delta":
      guard let outputIndex, var toolCall = ongoingToolCalls[outputIndex], toolCall.applyPatch != nil else { return }
      emit(.toolInputDelta(id: toolCall.toolCallId, delta: escapeJSONDelta(value["delta"]?.stringValue ?? "")))
      toolCall.applyPatch?.hasDiff = true
      ongoingToolCalls[outputIndex] = toolCall

    case "response.apply_patch_call_operation_diff.done":
      guard let outputIndex, var toolCall = ongoingToolCalls[outputIndex], let patch = toolCall.applyPatch,
        !patch.endEmitted
      else { return }
      if !patch.hasDiff {
        emit(.toolInputDelta(id: toolCall.toolCallId, delta: escapeJSONDelta(value["diff"]?.stringValue ?? "")))
      }
      emit(.toolInputDelta(id: toolCall.toolCallId, delta: "\"}}"))
      emit(.toolInputEnd(id: toolCall.toolCallId))
      toolCall.applyPatch = (true, true)
      ongoingToolCalls[outputIndex] = toolCall

    case "response.image_generation_call.partial_image":
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: value["item_id"]?.stringValue ?? "", toolName: mapping.toCustomToolName("image_generation"),
            result: ["result": value["partial_image_b64"] ?? .null], preliminary: true)))

    case "response.code_interpreter_call_code.delta":
      guard let outputIndex, let toolCall = ongoingToolCalls[outputIndex] else { return }
      emit(.toolInputDelta(id: toolCall.toolCallId, delta: escapeJSONDelta(value["delta"]?.stringValue ?? "")))

    case "response.code_interpreter_call_code.done":
      guard let outputIndex, let toolCall = ongoingToolCalls[outputIndex] else { return }
      emit(.toolInputDelta(id: toolCall.toolCallId, delta: "\"}"))
      emit(.toolInputEnd(id: toolCall.toolCallId))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCall.toolCallId, toolName: mapping.toCustomToolName("code_interpreter"),
            input: ["code": value["code"] ?? .null, "containerId": toolCall.codeInterpreterContainerId.map(JSONValue.string) ?? .null],
            providerExecuted: true)))

    case "response.created":
      responseId = value["response"]?["id"] ?? .null
      emit(
        .responseMetadata(
          createLanguageModelResponseMetadata(
            id: value["response"]?["id"]?.stringValue, model: value["response"]?["model"]?.stringValue,
            created: value["response"]?["created_at"]?.doubleValue)))

    case "response.output_text.delta":
      let itemId = resolveItemId(value["item_id"]?.stringValue ?? "", outputIndex)
      emit(.textDelta(id: itemId, delta: value["delta"]?.stringValue ?? ""))
      if wantsLogprobs, let partLogprobs = value["logprobs"], partLogprobs != .null { logprobs.append(partLogprobs) }

    case "response.reasoning_summary_part.added":
      let itemId = resolveItemId(value["item_id"]?.stringValue ?? "", outputIndex)
      guard let summaryIndex = value["summary_index"]?.intValue, summaryIndex > 0,
        var reasoning = activeReasoning[itemId]
      else { return }
      reasoning.summaryParts[summaryIndex] = .active
      for index in reasoning.summaryParts.keys.sorted() where reasoning.summaryParts[index] == .canConclude {
        emit(.reasoningEnd(id: "\(itemId):\(index)", providerMetadata: [name: ["itemId": .string(itemId)]]))
        reasoning.summaryParts[index] = .concluded
      }
      activeReasoning[itemId] = reasoning
      emit(
        .reasoningStart(
          id: "\(itemId):\(summaryIndex)",
          providerMetadata: [
            name: ["itemId": .string(itemId), "reasoningEncryptedContent": reasoning.encryptedContent ?? .null]
          ]))

    case "response.reasoning_summary_text.delta":
      let itemId = resolveItemId(value["item_id"]?.stringValue ?? "", outputIndex)
      emit(
        .reasoningDelta(
          id: "\(itemId):\(value["summary_index"]?.intValue ?? 0)", delta: value["delta"]?.stringValue ?? "",
          providerMetadata: [name: ["itemId": .string(itemId)]]))

    case "response.reasoning_summary_part.done":
      let itemId = resolveItemId(value["item_id"]?.stringValue ?? "", outputIndex)
      guard let summaryIndex = value["summary_index"]?.intValue, var reasoning = activeReasoning[itemId] else { return }
      if request.store == true {
        emit(.reasoningEnd(id: "\(itemId):\(summaryIndex)", providerMetadata: [name: ["itemId": .string(itemId)]]))
        reasoning.summaryParts[summaryIndex] = .concluded
      } else {
        reasoning.summaryParts[summaryIndex] = .canConclude
      }
      activeReasoning[itemId] = reasoning

    case "response.completed", "response.incomplete":
      let reason = value["response"]?["incomplete_details"]?["reason"]?.stringValue
      if !encounteredStreamError {
        finishReason = LanguageModelV4FinishReason(
          unified: mapOpenAIResponseFinishReason(reason, hasFunctionCall: hasFunctionCall), raw: reason)
      }
      usage = value["response"]?["usage"].flatMap { $0 == .null ? nil : $0 }
      if case .string(let tier)? = value["response"]?["service_tier"] { serviceTier = tier }
      if let context = value["response"]?["reasoning"]?["context"], context != .null { reasoningContext = context }

    case "response.failed":
      let responseValue = value["response"]
      let reason = responseValue?["incomplete_details"]?["reason"]?.stringValue
      finishReason = LanguageModelV4FinishReason(
        unified: reason.map { mapOpenAIResponseFinishReason($0, hasFunctionCall: hasFunctionCall) } ?? .error,
        raw: reason ?? "error")
      usage = responseValue?["usage"].flatMap { $0 == .null ? nil : $0 }
      if let context = responseValue?["reasoning"]?["context"], context != .null { reasoningContext = context }
      if !encounteredStreamError, let error = responseValue?["error"], error != .null {
        encounteredStreamError = true
        let frame: JSONValue = jsonObject([
          "type": "response.failed", "sequence_number": value["sequence_number"],
          "response": jsonObject([
            "error": error, "incomplete_details": responseValue?["incomplete_details"],
            "service_tier": responseValue?["service_tier"],
          ]),
        ])
        emit(.error(createOpenAIProviderStreamError(frame) ?? ProviderStreamError(message: frame.jsonString(), data: frame)))
      }

    case "response.output_text.annotation.added":
      guard let annotation = value["annotation"] else { return }
      ongoingAnnotations.append(annotation)
      if let source = openAIResponsesSource(annotation, id: generateId(), providerOptionsName: name) {
        emit(.source(source))
      }

    case "error":
      encounteredStreamError = true
      finishReason = LanguageModelV4FinishReason(unified: .error, raw: "error")
      emit(.error(createOpenAIProviderStreamError(value) ?? ProviderStreamError(message: value.jsonString(), data: value)))

    default:
      break
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func outputItemAdded(_ item: JSONValue, outputIndex: Int, emit: Emit) {
    let id = item["id"]?.stringValue ?? ""
    let callId = item["call_id"]?.stringValue
    switch item["type"]?.stringValue {
    case "function_call":
      let toolName = item["name"]?.stringValue ?? ""
      let suppress = isUndeclaredParallelToolCall(toolName: toolName, tools: functionTools)
      ongoingToolCalls[outputIndex] = OngoingToolCall(
        toolName: toolName, toolCallId: callId ?? id, suppressInputStreaming: suppress, async: item["async"])
      if !suppress { emit(.toolInputStart(LanguageModelV4ToolInputStart(id: callId ?? id, toolName: toolName))) }

    case "custom_tool_call":
      let toolName = mapping.toCustomToolName(item["name"]?.stringValue ?? "")
      ongoingToolCalls[outputIndex] = OngoingToolCall(toolName: toolName, toolCallId: callId ?? id, async: item["async"])
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: callId ?? id, toolName: toolName)))

    case "web_search_call":
      ongoingToolCalls[outputIndex] = OngoingToolCall(toolName: webSearchToolName, toolCallId: id)
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: webSearchToolName, providerExecuted: true)))
      emit(.toolInputEnd(id: id))
      emit(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: webSearchToolName, input: "{}", providerExecuted: true)))

    case "computer_call":
      let toolCallId = callId ?? id
      ongoingToolCalls[outputIndex] = OngoingToolCall(toolName: mapping.toCustomToolName("computer"), toolCallId: toolCallId)
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCallId, toolName: mapping.toCustomToolName("computer"))))

    case "code_interpreter_call":
      let containerId = item["container_id"]?.stringValue ?? ""
      let toolName = mapping.toCustomToolName("code_interpreter")
      ongoingToolCalls[outputIndex] = OngoingToolCall(
        toolName: toolName, toolCallId: id, codeInterpreterContainerId: containerId)
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: toolName, providerExecuted: true)))
      emit(.toolInputDelta(id: id, delta: "{\"containerId\":\"\(containerId)\",\"code\":\""))

    case "file_search_call":
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: id, toolName: mapping.toCustomToolName("file_search"), input: "{}", providerExecuted: true)))

    case "image_generation_call":
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: id, toolName: mapping.toCustomToolName("image_generation"), input: "{}", providerExecuted: true)))

    case "tool_search_call":
      let toolName = mapping.toCustomToolName("tool_search")
      let execution = item["execution"]?.stringValue
      ongoingToolCalls[outputIndex] = OngoingToolCall(
        toolName: toolName, toolCallId: id, toolSearchExecution: execution ?? "server")
      if execution == "server" {
        emit(.toolInputStart(LanguageModelV4ToolInputStart(id: id, toolName: toolName, providerExecuted: true)))
      }

    case "apply_patch_call":
      let operation = item["operation"] ?? .null
      let operationType = operation["type"]?.stringValue ?? ""
      let isDelete = operationType == "delete_file"
      let toolCallId = callId ?? id
      let toolName = mapping.toCustomToolName("apply_patch")
      ongoingToolCalls[outputIndex] = OngoingToolCall(
        toolName: toolName, toolCallId: toolCallId, applyPatch: (isDelete, isDelete))
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCallId, toolName: toolName)))
      if isDelete {
        emit(
          .toolInputDelta(
            id: toolCallId, delta: jsonObject(["callId": .string(toolCallId), "operation": operation]).jsonString()))
        emit(.toolInputEnd(id: toolCallId))
      } else {
        emit(
          .toolInputDelta(
            id: toolCallId,
            delta:
              "{\"callId\":\"\(escapeJSONDelta(toolCallId))\",\"operation\":{\"type\":\"\(escapeJSONDelta(operationType))\",\"path\":\"\(escapeJSONDelta(operation["path"]?.stringValue ?? ""))\",\"diff\":\""
          ))
      }

    case "shell_call":
      ongoingToolCalls[outputIndex] = OngoingToolCall(toolName: mapping.toCustomToolName("shell"), toolCallId: callId ?? id)

    case "message":
      activeOutputItemIds[outputIndex] = id
      ongoingAnnotations.removeAll()
      activeMessagePhase = item["phase"].flatMap { $0 == .null ? nil : $0 }
      var metadata: JSONObject = ["itemId": .string(id)]
      if let phase = activeMessagePhase { metadata["phase"] = phase }
      emit(.textStart(id: id, providerMetadata: [name: metadata]))

    case "reasoning":
      activeOutputItemIds[outputIndex] = id
      let encrypted = item["encrypted_content"].flatMap { $0 == .null ? nil : $0 }
      activeReasoning[id] = ActiveReasoning(encryptedContent: encrypted, summaryParts: [0: .active])
      emit(
        .reasoningStart(
          id: "\(id):0", providerMetadata: [name: ["itemId": .string(id), "reasoningEncryptedContent": encrypted ?? .null]]))

    default:
      break
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func outputItemDone(_ item: JSONValue, outputIndex: Int, emit: Emit) {
    let id = item["id"]?.stringValue ?? ""
    let callId = item["call_id"]?.stringValue
    switch item["type"]?.stringValue {
    case "message":
      let itemId = resolveItemId(id, outputIndex)
      let phase = item["phase"].flatMap { $0 == .null ? nil : $0 } ?? activeMessagePhase
      activeMessagePhase = nil
      var metadata: JSONObject = ["itemId": .string(itemId)]
      if let phase { metadata["phase"] = phase }
      if !ongoingAnnotations.isEmpty { metadata["annotations"] = .array(ongoingAnnotations) }
      emit(.textEnd(id: itemId, providerMetadata: [name: metadata]))
      activeOutputItemIds[outputIndex] = nil

    case "function_call":
      let ongoing = ongoingToolCalls.removeValue(forKey: outputIndex)
      hasFunctionCall = true
      let toolCallId = callId ?? id
      let toolName = item["name"]?.stringValue ?? ""
      let arguments = item["arguments"]?.stringValue ?? ""
      let suppress = ongoing?.suppressInputStreaming ?? isUndeclaredParallelToolCall(toolName: toolName, tools: functionTools)

      if suppress,
        let expanded = expandParallelToolCall(
          toolCallId: toolCallId, toolName: toolName, input: arguments, tools: functionTools, providerOptionsName: name,
          itemId: id)
      {
        for toolCall in expanded {
          emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCall.toolCallId, toolName: toolCall.toolName)))
          emit(.toolInputDelta(id: toolCall.toolCallId, delta: toolCall.input))
          emit(.toolInputEnd(id: toolCall.toolCallId))
          emit(.toolCall(toolCall))
        }
        return
      }

      if suppress {
        emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCallId, toolName: toolName)))
        let buffered = ongoing?.bufferedInputDeltas ?? []
        if !buffered.isEmpty {
          for delta in buffered { emit(.toolInputDelta(id: toolCallId, delta: delta)) }
        } else if !arguments.isEmpty {
          emit(.toolInputDelta(id: toolCallId, delta: arguments))
        }
      }
      let namespace = item["namespace"].flatMap { $0 == .null ? nil : $0 }
      emit(.toolInputEnd(id: toolCallId, providerMetadata: namespace.map { [name: ["namespace": $0]] }))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCallId, toolName: toolName, input: arguments,
            providerMetadata: [name: functionCallMetadata(item, async: ongoing?.async)])))

    case "program":
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName("programmatic_tool_calling"),
            input: ["code": item["code"] ?? .null, "fingerprint": item["fingerprint"] ?? .null], providerExecuted: true,
            providerMetadata: itemMetadata(item))))

    case "program_output":
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName("programmatic_tool_calling"),
            result: ["result": item["result"] ?? .null, "status": item["status"] ?? .null],
            providerMetadata: itemMetadata(item))))

    case "custom_tool_call":
      let ongoing = ongoingToolCalls.removeValue(forKey: outputIndex)
      hasFunctionCall = true
      var metadata: JSONObject = ["itemId": .string(id)]
      if let async = item["async"], async != .null {
        metadata["async"] = async
      } else if let async = ongoing?.async, async != .null {
        metadata["async"] = async
      }
      emit(.toolInputEnd(id: callId ?? id))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName(item["name"]?.stringValue ?? ""),
            input: (item["input"] ?? .null).jsonString(), providerMetadata: [name: metadata])))

    case "web_search_call":
      ongoingToolCalls[outputIndex] = nil
      emit(
        .toolResult(LanguageModelV4ToolResult(toolCallId: id, toolName: webSearchToolName, result: mapWebSearchOutput(item["action"]))))

    case "computer_call":
      ongoingToolCalls[outputIndex] = nil
      guard let callId else {
        let toolName = mapping.toCustomToolName("computer_use")
        emit(.toolInputEnd(id: id))
        emit(.toolCall(LanguageModelV4ToolCall(toolCallId: id, toolName: toolName, input: "", providerExecuted: true)))
        emit(
          .toolResult(
            LanguageModelV4ToolResult(
              toolCallId: id, toolName: toolName, result: ["type": "computer_use_tool_result", "status": item["status"] ?? .null])))
        return
      }
      hasFunctionCall = true
      let input = mapComputerCallInput(item).jsonString()
      emit(.toolInputDelta(id: callId, delta: input))
      emit(.toolInputEnd(id: callId))
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: callId, toolName: mapping.toCustomToolName("computer"), input: input,
            providerMetadata: itemMetadata(item))))

    case "file_search_call":
      ongoingToolCalls[outputIndex] = nil
      emit(
        .toolResult(
          LanguageModelV4ToolResult(toolCallId: id, toolName: mapping.toCustomToolName("file_search"), result: fileSearchResult(item))))

    case "code_interpreter_call":
      ongoingToolCalls[outputIndex] = nil
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: id, toolName: mapping.toCustomToolName("code_interpreter"), result: ["outputs": item["outputs"] ?? .null])))

    case "image_generation_call":
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: id, toolName: mapping.toCustomToolName("image_generation"), result: ["result": item["result"] ?? .null])))

    case "tool_search_call":
      if let toolCall = ongoingToolCalls[outputIndex] {
        let isHosted = item["execution"]?.stringValue == "server"
        let toolCallId = isHosted ? toolCall.toolCallId : (callId ?? id)
        if isHosted {
          hostedToolSearchCallIds.append(toolCallId)
        } else {
          emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCallId, toolName: toolCall.toolName)))
        }
        emit(.toolInputEnd(id: toolCallId))
        emit(
          .toolCall(
            LanguageModelV4ToolCall(
              toolCallId: toolCallId, toolName: toolCall.toolName,
              input: ["arguments": item["arguments"] ?? .null, "call_id": isHosted ? .null : .string(toolCallId)],
              providerExecuted: isHosted ? true : nil, providerMetadata: itemMetadata(item))))
      }
      ongoingToolCalls[outputIndex] = nil

    case "tool_search_output":
      let toolCallId = callId ?? (hostedToolSearchCallIds.isEmpty ? nil : hostedToolSearchCallIds.removeFirst()) ?? id
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: toolCallId, toolName: mapping.toCustomToolName("tool_search"),
            result: ["tools": item["tools"] ?? []], providerMetadata: itemMetadata(item))))

    case "mcp_call":
      ongoingToolCalls[outputIndex] = nil
      let toolCallId =
        item["approval_request_id"]?.stringValue.map { approvalMappingFromStream[$0] ?? approvalMappingFromPrompt[$0] ?? id }
        ?? id
      let toolName = "mcp.\(item["name"]?.stringValue ?? "")"
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: toolCallId, toolName: toolName, input: item["arguments"]?.stringValue ?? "",
            providerExecuted: true, dynamic: true)))
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: toolCallId, toolName: toolName, result: mcpCallResult(item), providerMetadata: itemMetadata(item))))

    case "mcp_list_tools":
      ongoingToolCalls[outputIndex] = nil

    case "apply_patch_call":
      if var toolCall = ongoingToolCalls[outputIndex], let patch = toolCall.applyPatch {
        if !patch.endEmitted, item["operation"]?["type"]?.stringValue != "delete_file" {
          if !patch.hasDiff {
            emit(
              .toolInputDelta(id: toolCall.toolCallId, delta: escapeJSONDelta(item["operation"]?["diff"]?.stringValue ?? "")))
          }
          emit(.toolInputDelta(id: toolCall.toolCallId, delta: "\"}}"))
          emit(.toolInputEnd(id: toolCall.toolCallId))
          toolCall.applyPatch = (true, true)
        }
        if item["status"]?.stringValue == "completed" {
          hasFunctionCall = true
          emit(
            .toolCall(
              LanguageModelV4ToolCall(
                toolCallId: toolCall.toolCallId, toolName: mapping.toCustomToolName("apply_patch"),
                input: ["callId": item["call_id"] ?? .null, "operation": item["operation"] ?? .null],
                providerMetadata: itemMetadata(item))))
        }
      }
      ongoingToolCalls[outputIndex] = nil

    case "mcp_approval_request":
      ongoingToolCalls[outputIndex] = nil
      let dummyToolCallId = generateId()
      let approvalRequestId = item["approval_request_id"]?.stringValue ?? id
      approvalMappingFromStream[approvalRequestId] = dummyToolCallId
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: dummyToolCallId, toolName: "mcp.\(item["name"]?.stringValue ?? "")",
            input: item["arguments"]?.stringValue ?? "", providerExecuted: true, dynamic: true)))
      emit(.toolApprovalRequest(LanguageModelV4ToolApprovalRequest(approvalId: approvalRequestId, toolCallId: dummyToolCallId)))

    case "local_shell_call":
      ongoingToolCalls[outputIndex] = nil
      let action = item["action"]
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName("local_shell"),
            input: [
              "action": jsonObject([
                "type": "exec", "command": action?["command"], "timeoutMs": action?["timeout_ms"],
                "user": action?["user"], "workingDirectory": action?["working_directory"], "env": action?["env"],
              ])
            ], providerMetadata: itemMetadata(item))))

    case "shell_call":
      ongoingToolCalls[outputIndex] = nil
      emit(
        .toolCall(
          LanguageModelV4ToolCall(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName("shell"),
            input: ["action": ["commands": item["action"]?["commands"] ?? []]],
            providerExecuted: request.isShellProviderExecuted ? true : nil, providerMetadata: itemMetadata(item))))

    case "shell_call_output":
      emit(
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: callId ?? id, toolName: mapping.toCustomToolName("shell"),
            result: ["output": .array((item["output"]?.arrayValue ?? []).map(mapShellOutputItem))])))

    case "reasoning":
      let itemId = resolveItemId(id, outputIndex)
      if let reasoning = activeReasoning.removeValue(forKey: itemId) {
        for index in reasoning.summaryParts.keys.sorted()
        where reasoning.summaryParts[index] == .active || reasoning.summaryParts[index] == .canConclude {
          emit(
            .reasoningEnd(
              id: "\(itemId):\(index)",
              providerMetadata: [
                name: ["itemId": .string(itemId), "reasoningEncryptedContent": item["encrypted_content"] ?? .null]
              ]))
        }
      }
      activeOutputItemIds[outputIndex] = nil

    case "compaction":
      emit(
        .custom(
          LanguageModelV4CustomContent(
            kind: "openai.compaction",
            providerMetadata: [
              name: ["type": "compaction", "itemId": .string(id), "encryptedContent": item["encrypted_content"] ?? .null]
            ])))

    default:
      break
    }
  }

  func finish(emit: Emit) {
    for index in ongoingToolCalls.keys.sorted() {
      guard let toolCall = ongoingToolCalls[index], toolCall.suppressInputStreaming else { continue }
      emit(.toolInputStart(LanguageModelV4ToolInputStart(id: toolCall.toolCallId, toolName: toolCall.toolName)))
      for delta in toolCall.bufferedInputDeltas { emit(.toolInputDelta(id: toolCall.toolCallId, delta: delta)) }
    }
    var metadata: JSONObject = ["responseId": responseId]
    if !logprobs.isEmpty { metadata["logprobs"] = .array(logprobs) }
    if let serviceTier { metadata["serviceTier"] = .string(serviceTier) }
    if let reasoningContext { metadata["reasoningContext"] = reasoningContext }
    emit(.finish(usage: convertOpenAIResponsesUsage(usage), finishReason: finishReason, providerMetadata: [name: metadata]))
  }
}
