import AISDKProviderUtils
import Foundation

/// Inputs to `convertToOpenAIResponsesInput`. Mirrors the upstream options object.
struct OpenAIResponsesInputOptions {
  var toolNameMapping: ToolNameMapping
  var systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode
  var providerOptionsName: String
  var explicitMessageItemType = false
  /// Soft-deprecated; use provider references instead.
  var fileIdPrefixes: [String]?
  var passThroughUnsupportedFiles = false
  var store: Bool
  /// Skips assistant items that already exist in the conversation.
  var hasConversation = false
  /// Skips reasoning and tool items that already exist in the response chain.
  var hasPreviousResponseId = false
  var hasLocalShellTool = false
  var hasShellTool = false
  var hasApplyPatchTool = false
  var hasComputerTool = false
  var toolSearchToolName: String?
  var customProviderToolNames: Set<String> = []
  var outputSchemaToolNames: Set<String> = []
  var configurationUpdateUnsupportedReason: String?
}

private func promptCacheBreakpoint(_ providerOptions: SharedV4ProviderOptions?, _ name: String) -> JSONValue? {
  providerOptions?[name]?["promptCacheBreakpoint"]
}

private func withBreakpoint(_ part: JSONObject, _ breakpoint: JSONValue?) -> JSONValue {
  var part = part
  if let breakpoint { part["prompt_cache_breakpoint"] = breakpoint }
  return .object(part)
}

private func mapToolCaller(_ caller: JSONValue?) -> JSONValue? {
  guard let caller, case .object = caller else { return nil }
  if caller["type"]?.stringValue == "program" {
    return ["type": "program", "caller_id": caller["callerId"] ?? .null]
  }
  return caller
}

private func parseToolInput(_ input: JSONValue) -> JSONValue {
  if case .string(let text) = input, let parsed = try? JSONValue(jsonString: text) { return parsed }
  return input
}

private func isFileId(_ data: String, _ prefixes: [String]?) -> Bool {
  prefixes?.contains { data.hasPrefix($0) } ?? false
}

private func dataURL(_ data: SharedV4FileData, mediaType: String) -> String {
  "data:\(mediaType);base64,\(data.base64String ?? "")"
}

private func isExecutionDenied(_ output: LanguageModelV4ToolResultOutput) -> Bool {
  switch output {
  case .executionDenied: true
  case .json(let value, _): value["type"]?.stringValue == "execution-denied"
  default: false
  }
}

private func scalarBreakpoint(
  _ output: LanguageModelV4ToolResultOutput, _ partOptions: SharedV4ProviderOptions?, _ name: String
) -> JSONValue? {
  switch output {
  case .content: nil
  case .text(_, let options), .json(_, let options), .executionDenied(_, let options), .errorText(_, let options),
    .errorJSON(_, let options):
    promptCacheBreakpoint(options, name) ?? promptCacheBreakpoint(partOptions, name)
  }
}

/// Converts `content` tool result parts to Responses input content, or `nil`
/// for unsupported parts (with a warning).
private func convertToolContentPart(
  _ item: LanguageModelV4ToolResultOutput.ContentPart, providerOptionsName: String, label: String,
  warnings: inout [SharedV4Warning]
) throws -> JSONValue? {
  switch item {
  case .text(let text, let options):
    return withBreakpoint(["type": "input_text", "text": .string(text)], promptCacheBreakpoint(options, providerOptionsName))
  case .file(let data, let mediaType, let filename, let options):
    let breakpoint = promptCacheBreakpoint(options, providerOptionsName)
    let isImage = getTopLevelMediaType(mediaType) == "image"
    let detail = options?[providerOptionsName]?["imageDetail"]
    switch data {
    case .reference(let reference) where label == "tool":
      let fileId = JSONValue.string(try resolveProviderReference(reference, provider: providerOptionsName))
      return withBreakpoint(
        isImage
          ? jsonObject(["type": "input_image", "file_id": fileId, "detail": detail]).objectValue ?? [:]
          : ["type": "input_file", "file_id": fileId], breakpoint)
    case .data, .base64:
      let fullMediaType = try resolveFullMediaType(
        LanguageModelV4FilePart(data: data, mediaType: mediaType, filename: filename))
      return withBreakpoint(
        isImage
          ? jsonObject(["type": "input_image", "image_url": .string(dataURL(data, mediaType: fullMediaType)), "detail": detail])
            .objectValue ?? [:]
          : [
            "type": "input_file", "filename": .string(filename ?? "data"),
            "file_data": .string(dataURL(data, mediaType: fullMediaType)),
          ], breakpoint)
    case .url(let url, _):
      return withBreakpoint(
        isImage
          ? jsonObject(["type": "input_image", "image_url": .string(url.absoluteString), "detail": detail]).objectValue ?? [:]
          : ["type": "input_file", "file_url": .string(url.absoluteString)], breakpoint)
    case .reference, .text:
      let dataType =
        switch data {
        case .reference: "reference"
        default: "text"
        }
      warnings.append(.other(message: "unsupported \(label) content part type: file with data type: \(dataType)"))
      return nil
    }
  case .custom:
    warnings.append(.other(message: "unsupported \(label) content part type: custom"))
    return nil
  }
}

/// Mirrors upstream `convertFunctionToolResultOutput`.
private func convertFunctionToolResultOutput(
  _ output: LanguageModelV4ToolResultOutput, toolName: String, outputSchemaToolNames: Set<String>,
  breakpoint: JSONValue?, providerOptionsName: String, warnings: inout [SharedV4Warning]
) throws -> JSONValue {
  let hasOutputSchema = outputSchemaToolNames.contains(toolName)
  func scalar(_ value: String) -> JSONValue {
    guard let breakpoint else { return .string(value) }
    return [["type": "input_text", "text": .string(value), "prompt_cache_breakpoint": breakpoint]]
  }
  switch output {
  case .text(let value, _), .errorText(let value, _):
    return scalar(hasOutputSchema ? JSONValue.string(value).jsonString() : value)
  case .executionDenied(let reason, _):
    let text = reason ?? "Tool call execution denied."
    return scalar(hasOutputSchema ? JSONValue.string(text).jsonString() : text)
  case .json(let value, _), .errorJSON(let value, _):
    return scalar(value.jsonString())
  case .content(let parts):
    return .array(
      try parts.compactMap {
        try convertToolContentPart($0, providerOptionsName: providerOptionsName, label: "tool", warnings: &warnings)
      })
  }
}

private struct ParallelToolResultGroup {
  var metadata: ParallelToolCallMetadata
  var results: [LanguageModelV4ToolResultPart]
}

/// Mirrors upstream `collectCompleteParallelToolResultGroups`.
private func collectCompleteParallelToolResultGroups(_ prompt: LanguageModelV4Prompt, providerOptionsName: String)
  -> [String: ParallelToolResultGroup]
{
  var pending: [String: (metadata: ParallelToolCallMetadata, results: [Int: LanguageModelV4ToolResultPart], invalid: Bool)] =
    [:]
  var order: [String] = []
  for case .tool(let content, _) in prompt {
    for case .toolResult(let part) in content {
      guard let metadata = ParallelToolCallMetadata(providerOptions: part.providerOptions, providerOptionsName: providerOptionsName)
      else { continue }
      guard var existing = pending[metadata.toolCallId] else {
        pending[metadata.toolCallId] = (metadata, [metadata.index: part], false)
        order.append(metadata.toolCallId)
        continue
      }
      if !existing.metadata.isSameCall(as: metadata) || existing.results[metadata.index] != nil {
        existing.invalid = true
      } else {
        existing.results[metadata.index] = part
      }
      pending[metadata.toolCallId] = existing
    }
  }

  var complete: [String: ParallelToolResultGroup] = [:]
  for toolCallId in order {
    guard let group = pending[toolCallId], !group.invalid, group.results.count == group.metadata.count else { continue }
    let results = (0..<group.metadata.count).compactMap { group.results[$0] }
    if results.count == group.metadata.count {
      complete[toolCallId] = ParallelToolResultGroup(metadata: group.metadata, results: results)
    }
  }
  return complete
}

/// Converts a prompt to Responses API input items. Mirrors upstream `convertToOpenAIResponsesInput`.
func convertToOpenAIResponsesInput(_ prompt: LanguageModelV4Prompt, options: OpenAIResponsesInputOptions) throws -> (
  input: [JSONValue], warnings: [SharedV4Warning]
) {
  let name = options.providerOptionsName
  let store = options.store
  var input: [JSONValue] = []
  var warnings: [SharedV4Warning] = []
  var processedApprovalIds: Set<String> = []
  var programmaticToolCallIds: Set<String> = []
  let parallelGroups =
    options.hasConversation || options.hasPreviousResponseId
    ? collectCompleteParallelToolResultGroups(prompt, providerOptionsName: name) : [:]
  var emittedParallelCalls: Set<String> = []
  var emittedParallelResults: Set<String> = []

  func messageItem(_ fields: JSONObject) -> JSONValue {
    var fields = fields
    if options.explicitMessageItemType { fields["type"] = "message" }
    return .object(fields)
  }

  for message in prompt {
    switch message {
    case .system(let content, let providerOptions):
      let messageOptions = providerOptions?[name] ?? (name != "openai" ? providerOptions?["openai"] : nil)
      if let effort = messageOptions?["reasoningEffortUpdate"]?.stringValue {
        let reason =
          !content.isEmpty
          ? "Message-level reasoningEffortUpdate requires empty system message content."
          : options.configurationUpdateUnsupportedReason
        if let reason {
          throw UnsupportedFunctionalityError(functionality: "Message-level reasoningEffortUpdate", message: reason)
        }
        input.append(["type": "configuration_update", "reasoning": ["effort": .string(effort)]])
        continue
      }
      switch options.systemMessageMode {
      case .system, .developer:
        let breakpoint = promptCacheBreakpoint(providerOptions, name)
        input.append(
          messageItem([
            "role": .string(options.systemMessageMode.rawValue),
            "content": breakpoint.map { [["type": "input_text", "text": .string(content), "prompt_cache_breakpoint": $0]] }
              ?? .string(content),
          ]))
      case .remove:
        warnings.append(.other(message: "system messages are removed for this model"))
      }

    case .user(let content, _):
      let parts = try content.enumerated().map { index, part -> JSONValue in
        switch part {
        case .text(let text):
          return withBreakpoint(["type": "input_text", "text": .string(text.text)], promptCacheBreakpoint(text.providerOptions, name))
        case .file(let file):
          let breakpoint = promptCacheBreakpoint(file.providerOptions, name)
          let detail = file.providerOptions?[name]?["imageDetail"]
          let isImage = getTopLevelMediaType(file.mediaType) == "image"
          switch file.data {
          case .reference(let reference):
            let fileId = JSONValue.string(try resolveProviderReference(reference, provider: name))
            return withBreakpoint(
              isImage
                ? jsonObject(["type": "input_image", "file_id": fileId, "detail": detail]).objectValue ?? [:]
                : ["type": "input_file", "file_id": fileId], breakpoint)
          case .text:
            throw UnsupportedFunctionalityError(functionality: "text file parts")
          case .url, .data, .base64:
            if isImage {
              var image: JSONObject = ["type": "input_image"]
              if case .url(let url, _) = file.data {
                image["image_url"] = .string(url.absoluteString)
              } else if case .base64(let string) = file.data, isFileId(string, options.fileIdPrefixes) {
                image["file_id"] = .string(string)
              } else {
                image["image_url"] = .string(dataURL(file.data, mediaType: try resolveFullMediaType(file)))
              }
              if let detail { image["detail"] = detail }
              return withBreakpoint(image, breakpoint)
            }
            if case .url(let url, _) = file.data {
              return withBreakpoint(["type": "input_file", "file_url": .string(url.absoluteString)], breakpoint)
            }
            let fullMediaType = try resolveFullMediaType(file)
            if fullMediaType != "application/pdf" && !options.passThroughUnsupportedFiles {
              throw UnsupportedFunctionalityError(functionality: "file part media type \(fullMediaType)")
            }
            if case .base64(let string) = file.data, isFileId(string, options.fileIdPrefixes) {
              return withBreakpoint(["type": "input_file", "file_id": .string(string)], breakpoint)
            }
            return withBreakpoint(
              [
                "type": "input_file",
                "filename": .string(file.filename ?? (fullMediaType == "application/pdf" ? "part-\(index).pdf" : "part-\(index)")),
                "file_data": .string(dataURL(file.data, mediaType: fullMediaType)),
              ], breakpoint)
          }
        }
      }
      input.append(messageItem(["role": "user", "content": .array(parts)]))

    case .assistant(let content, _):
      var reasoningIndex: [String: Int] = [:]
      for part in content {
        switch part {
        case .text(let text):
          let partOptions = text.providerOptions?[name]
          let id = partOptions?["itemId"]?.stringValue
          if options.hasConversation && id != nil { break }
          if store, let id {
            input.append(["type": "item_reference", "id": .string(id)])
            break
          }
          var fields: JSONObject = ["role": "assistant", "content": .string(text.text)]
          if let phase = partOptions?["phase"], phase != .null { fields["phase"] = phase }
          input.append(messageItem(fields))

        case .toolCall(let call):
          if let metadata = ParallelToolCallMetadata(providerOptions: call.providerOptions, providerOptionsName: name),
            let group = parallelGroups[metadata.toolCallId], group.metadata.isSameCall(as: metadata)
          {
            if !emittedParallelCalls.contains(group.metadata.toolCallId) {
              emittedParallelCalls.insert(group.metadata.toolCallId)
              if !options.hasConversation {
                input.append([
                  "type": "function_call", "call_id": .string(group.metadata.toolCallId),
                  "name": .string(group.metadata.toolName), "arguments": .string(group.metadata.input),
                ])
              }
            }
            break
          }

          let partOptions = call.providerOptions?[name]
          let id = partOptions?["itemId"]?.stringValue
          let namespace = partOptions?["namespace"]?.stringValue
          let isAsync = partOptions?["async"]?.boolValue
          let caller = partOptions?["caller"]
          if caller?["type"]?.stringValue == "program" { programmaticToolCallIds.insert(call.toolCallId) }
          if options.hasConversation && id != nil { break }

          let resolvedToolName = options.toolNameMapping.toProviderToolName(call.toolName)
          let parsedInput = parseToolInput(call.input)

          if call.toolName == options.toolSearchToolName {
            if store, let id {
              input.append(["type": "item_reference", "id": .string(id)])
              break
            }
            let callId = parsedInput["call_id"].flatMap { $0 == .null ? nil : $0 }
            input.append(
              jsonObject([
                "type": "tool_search_call", "id": .string(id ?? call.toolCallId),
                "execution": .string(callId != nil ? "client" : "server"), "call_id": callId ?? .null,
                "status": "completed", "arguments": parsedInput["arguments"],
              ]))
            break
          }

          if resolvedToolName == "programmatic_tool_calling" {
            if store, let id {
              input.append(["type": "item_reference", "id": .string(id)])
              break
            }
            input.append([
              "type": "program", "id": .string(id ?? call.toolCallId), "call_id": .string(call.toolCallId),
              "code": parsedInput["code"] ?? .null, "fingerprint": parsedInput["fingerprint"] ?? .null,
            ])
            break
          }

          if call.providerExecuted == true {
            if store, let id { input.append(["type": "item_reference", "id": .string(id)]) }
            if store || !options.hasShellTool || resolvedToolName != "shell" { break }
          }

          let isProviderDefinedToolCall =
            (options.hasLocalShellTool && resolvedToolName == "local_shell")
            || (options.hasShellTool && resolvedToolName == "shell")
            || (options.hasApplyPatchTool && resolvedToolName == "apply_patch")
            || (options.hasComputerTool && resolvedToolName == "computer")
            || options.customProviderToolNames.contains(resolvedToolName)

          if options.hasPreviousResponseId && store && id != nil && isProviderDefinedToolCall { break }
          if store, let id, isProviderDefinedToolCall {
            input.append(["type": "item_reference", "id": .string(id)])
            break
          }

          if options.hasLocalShellTool && resolvedToolName == "local_shell" {
            let action = parsedInput["action"]
            input.append(
              jsonObject([
                "type": "local_shell_call", "call_id": .string(call.toolCallId), "id": .optional(id),
                "action": jsonObject([
                  "type": "exec", "command": action?["command"], "timeout_ms": action?["timeoutMs"],
                  "user": action?["user"], "working_directory": action?["workingDirectory"], "env": action?["env"],
                ]),
              ]))
            break
          }
          if options.hasShellTool && resolvedToolName == "shell" {
            let action = parsedInput["action"]
            input.append(
              jsonObject([
                "type": "shell_call", "call_id": .string(call.toolCallId), "id": .optional(id), "status": "completed",
                "action": jsonObject([
                  "commands": action?["commands"], "timeout_ms": action?["timeoutMs"],
                  "max_output_length": action?["maxOutputLength"],
                ]),
              ]))
            break
          }
          if options.hasApplyPatchTool && resolvedToolName == "apply_patch" {
            input.append(
              jsonObject([
                "type": "apply_patch_call", "call_id": parsedInput["callId"], "id": .optional(id), "status": "completed",
                "operation": parsedInput["operation"],
              ]))
            break
          }
          if options.hasComputerTool && resolvedToolName == "computer" {
            let actions = (parsedInput["actions"]?.arrayValue ?? []).map { action -> JSONValue in
              guard action["type"]?.stringValue == "scroll" else { return action }
              return jsonObject([
                "type": "scroll", "x": action["x"], "y": action["y"], "scroll_x": action["scrollX"],
                "scroll_y": action["scrollY"], "keys": action["keys"],
              ])
            }
            let safetyChecks = (parsedInput["pendingSafetyChecks"]?.arrayValue ?? []).map {
              jsonObject(["id": $0["id"], "code": $0["code"], "message": $0["message"]])
            }
            input.append(
              jsonObject([
                "type": "computer_call", "call_id": .string(call.toolCallId), "id": .optional(id),
                "status": parsedInput["status"], "actions": .array(actions), "pending_safety_checks": .array(safetyChecks),
              ]))
            break
          }
          if options.customProviderToolNames.contains(resolvedToolName) {
            let text: String =
              if case .string(let value) = call.input { value } else { call.input.jsonString() }
            input.append(
              jsonObject([
                "type": "custom_tool_call", "call_id": .string(call.toolCallId), "name": .string(resolvedToolName),
                "input": .string(text), "async": .optional(isAsync), "id": .optional(id),
              ]))
            break
          }

          input.append(
            jsonObject([
              "type": "function_call", "call_id": .string(call.toolCallId), "name": .string(resolvedToolName),
              "arguments": .string(call.input.jsonString()), "async": .optional(isAsync),
              "namespace": .optional(namespace), "caller": mapToolCaller(caller),
            ]))

        case .toolResult(let result):
          if isExecutionDenied(result.output) || options.hasConversation { break }
          let resolvedToolName = options.toolNameMapping.toProviderToolName(result.toolName)
          let itemId = result.providerOptions?[name]?["itemId"]?.stringValue ?? result.toolCallId

          if result.toolName == options.toolSearchToolName {
            if store {
              input.append(["type": "item_reference", "id": .string(itemId)])
            } else if case .json(let value, _) = result.output {
              input.append([
                "type": "tool_search_output", "id": .string(itemId), "execution": "server", "call_id": .null,
                "status": "completed", "tools": value["tools"] ?? [],
              ])
            }
            break
          }
          if resolvedToolName == "programmatic_tool_calling" {
            if store {
              input.append(["type": "item_reference", "id": .string(itemId)])
            } else if case .json(let value, _) = result.output {
              input.append([
                "type": "program_output", "id": .string(itemId), "call_id": .string(result.toolCallId),
                "result": value["result"] ?? .null, "status": value["status"] ?? .null,
              ])
            }
            break
          }
          if options.hasShellTool && resolvedToolName == "shell" {
            if case .json(let value, _) = result.output {
              input.append([
                "type": "shell_call_output", "call_id": .string(result.toolCallId),
                "output": .array((value["output"]?.arrayValue ?? []).map(shellOutputItem)),
              ])
            }
            break
          }
          if store {
            input.append(["type": "item_reference", "id": .string(itemId)])
          } else {
            warnings.append(
              .other(message: "Results for OpenAI tool \(result.toolName) are not sent to the API when store is false"))
          }

        case .reasoning(let reasoning):
          let partOptions = reasoning.providerOptions?[name]
          let reasoningId = partOptions?["itemId"]?.stringValue
          let encrypted = partOptions?["reasoningEncryptedContent"].flatMap { $0 == .null ? nil : $0 }
          if (options.hasConversation || options.hasPreviousResponseId) && reasoningId != nil { break }

          guard let reasoningId else {
            if let encrypted {
              let summary: [JSONValue] =
                reasoning.text.isEmpty ? [] : [["type": "summary_text", "text": .string(reasoning.text)]]
              input.append(["type": "reasoning", "encrypted_content": encrypted, "summary": .array(summary)])
            } else {
              warnings.append(
                .other(
                  message: "Non-OpenAI reasoning parts are not supported. Skipping reasoning part: \(reasoningPartJSON(reasoning))."
                ))
            }
            break
          }

          if store {
            if reasoningIndex[reasoningId] == nil {
              reasoningIndex[reasoningId] = -1
              input.append(["type": "item_reference", "id": .string(reasoningId)])
            }
            break
          }

          var summary: [JSONValue] = []
          if !reasoning.text.isEmpty {
            summary.append(["type": "summary_text", "text": .string(reasoning.text)])
          } else if reasoningIndex[reasoningId] != nil {
            warnings.append(
              .other(
                message:
                  "Cannot append empty reasoning part to existing reasoning sequence. Skipping reasoning part: \(reasoningPartJSON(reasoning))."
              ))
          }
          if let index = reasoningIndex[reasoningId] {
            var item = input[index].objectValue ?? [:]
            item["summary"] = .array((item["summary"]?.arrayValue ?? []) + summary)
            if let encrypted { item["encrypted_content"] = encrypted }
            input[index] = .object(item)
          } else {
            reasoningIndex[reasoningId] = input.count
            input.append(
              jsonObject([
                "type": "reasoning", "id": .string(reasoningId), "encrypted_content": encrypted, "summary": .array(summary),
              ]))
          }

        case .custom(let custom) where custom.kind == "openai.compaction":
          let partOptions = custom.providerOptions?[name]
          guard let id = partOptions?["itemId"]?.stringValue else { break }
          if options.hasConversation { break }
          if store {
            input.append(["type": "item_reference", "id": .string(id)])
            break
          }
          input.append(["type": "compaction", "id": .string(id), "encrypted_content": partOptions?["encryptedContent"] ?? .null])

        case .file, .custom, .reasoningFile:
          break
        }
      }

    case .tool(let content, _):
      for part in content {
        switch part {
        case .toolApprovalResponse(let approval):
          guard !processedApprovalIds.contains(approval.approvalId) else { continue }
          processedApprovalIds.insert(approval.approvalId)
          if store && !options.hasConversation && !options.hasPreviousResponseId {
            input.append(["type": "item_reference", "id": .string(approval.approvalId)])
          }
          input.append([
            "type": "mcp_approval_response", "approval_request_id": .string(approval.approvalId),
            "approve": .bool(approval.approved),
          ])

        case .toolResult(let result):
          if let metadata = ParallelToolCallMetadata(providerOptions: result.providerOptions, providerOptionsName: name),
            let group = parallelGroups[metadata.toolCallId], group.metadata.isSameCall(as: metadata)
          {
            guard !emittedParallelResults.contains(group.metadata.toolCallId) else { continue }
            emittedParallelResults.insert(group.metadata.toolCallId)
            var outputs: [(text: String, breakpoint: JSONValue?)] = []
            for child in group.results {
              let converted = try convertFunctionToolResultOutput(
                child.output, toolName: child.toolName, outputSchemaToolNames: options.outputSchemaToolNames,
                breakpoint: nil, providerOptionsName: name, warnings: &warnings)
              let text: String = if case .string(let value) = converted { value } else { converted.jsonString() }
              outputs.append((text, scalarBreakpoint(child.output, child.providerOptions, name)))
            }
            let output: JSONValue =
              outputs.contains { $0.breakpoint != nil }
              ? .array(
                outputs.enumerated().map { index, entry in
                  withBreakpoint(
                    ["type": "input_text", "text": .string(index == 0 ? entry.text : "\n\(entry.text)")], entry.breakpoint)
                })
              : .string(outputs.map(\.text).joined(separator: "\n"))
            input.append(["type": "function_call_output", "call_id": .string(group.metadata.toolCallId), "output": output])
            continue
          }

          let output = result.output
          if case .executionDenied(_, let deniedOptions) = output, deniedOptions?["openai"]?["approvalId"]?.stringValue != nil {
            continue
          }
          let resolvedToolName = options.toolNameMapping.toProviderToolName(result.toolName)

          if result.toolName == options.toolSearchToolName, case .json(let value, _) = output {
            input.append([
              "type": "tool_search_output", "execution": "client", "call_id": .string(result.toolCallId),
              "status": "completed", "tools": value["tools"] ?? [],
            ])
            continue
          }
          if options.hasLocalShellTool && resolvedToolName == "local_shell", case .json(let value, _) = output {
            input.append([
              "type": "local_shell_call_output", "call_id": .string(result.toolCallId), "output": value["output"] ?? "",
            ])
            continue
          }
          if options.hasShellTool && resolvedToolName == "shell", case .json(let value, _) = output {
            input.append([
              "type": "shell_call_output", "call_id": .string(result.toolCallId),
              "output": .array((value["output"]?.arrayValue ?? []).map(shellOutputItem)),
            ])
            continue
          }
          if options.hasApplyPatchTool && result.toolName == "apply_patch", case .json(let value, _) = output {
            input.append(
              jsonObject([
                "type": "apply_patch_call_output", "call_id": .string(result.toolCallId), "status": value["status"],
                "output": value["output"],
              ]))
            continue
          }
          if options.hasComputerTool && resolvedToolName == "computer", case .json(let value, _) = output {
            let screenshot = value["output"]
            input.append(
              jsonObject([
                "type": "computer_call_output", "call_id": .string(result.toolCallId),
                "output": jsonObject([
                  "type": "computer_screenshot", "image_url": screenshot?["imageUrl"], "file_id": screenshot?["fileId"],
                  "detail": screenshot?["detail"],
                ]),
                "acknowledged_safety_checks": value["acknowledgedSafetyChecks"]?.arrayValue.map(safetyChecksJSON),
              ]))
            continue
          }
          if options.customProviderToolNames.contains(resolvedToolName) {
            let breakpoint = scalarBreakpoint(output, result.providerOptions, name)
            func scalar(_ value: String) -> JSONValue {
              guard let breakpoint else { return .string(value) }
              return [["type": "input_text", "text": .string(value), "prompt_cache_breakpoint": breakpoint]]
            }
            let outputValue: JSONValue
            switch output {
            case .text(let value, _), .errorText(let value, _): outputValue = scalar(value)
            case .executionDenied(let reason, _): outputValue = scalar(reason ?? "Tool call execution denied.")
            case .json(let value, _), .errorJSON(let value, _): outputValue = scalar(value.jsonString())
            case .content(let parts):
              outputValue = .array(
                try parts.compactMap { item -> JSONValue? in
                  if case .file(.reference, _, _, _) = item {
                    warnings.append(.other(message: "unsupported custom tool content part type: file with data type: reference"))
                    return nil
                  }
                  return try convertToolContentPart(item, providerOptionsName: name, label: "custom tool", warnings: &warnings)
                })
            }
            input.append(["type": "custom_tool_call_output", "call_id": .string(result.toolCallId), "output": outputValue])
            continue
          }

          let resultCaller = result.providerOptions?[name]?["caller"]
          if case .executionDenied = output,
            resultCaller?["type"]?.stringValue == "program" || programmaticToolCallIds.contains(result.toolCallId)
          {
            throw UnsupportedFunctionalityError(functionality: "execution-denied results for programmatic tool calls")
          }
          let contentValue = try convertFunctionToolResultOutput(
            output, toolName: result.toolName, outputSchemaToolNames: options.outputSchemaToolNames,
            breakpoint: scalarBreakpoint(output, result.providerOptions, name), providerOptionsName: name,
            warnings: &warnings)
          input.append(
            jsonObject([
              "type": "function_call_output", "call_id": .string(result.toolCallId), "output": contentValue,
              "caller": mapToolCaller(resultCaller),
            ]))
        }
      }
    }
  }

  if !store, input.contains(where: { $0["type"]?.stringValue == "reasoning" && ($0["encrypted_content"] ?? .null) == .null }) {
    warnings.append(
      .other(
        message:
          "Reasoning parts without encrypted content are not supported when store is false. Skipping reasoning parts."))
    input.removeAll { $0["type"]?.stringValue == "reasoning" && ($0["encrypted_content"] ?? .null) == .null }
  }

  return (input, warnings)
}

private func safetyChecksJSON(_ checks: [JSONValue]) -> JSONValue {
  .array(
    checks.map { check -> JSONValue in
      jsonObject(["id": check["id"], "code": check["code"], "message": check["message"]])
    })
}

private func shellOutputItem(_ item: JSONValue) -> JSONValue {
  let outcome: JSONValue =
    item["outcome"]?["type"]?.stringValue == "timeout"
    ? ["type": "timeout"] : ["type": "exit", "exit_code": item["outcome"]?["exitCode"] ?? .null]
  return ["stdout": item["stdout"] ?? "", "stderr": item["stderr"] ?? "", "outcome": outcome]
}

private func reasoningPartJSON(_ part: LanguageModelV4ReasoningPart) -> String {
  jsonObject([
    "type": "reasoning", "text": .string(part.text),
    "providerOptions": part.providerOptions.map { .object($0.mapValues(JSONValue.object)) },
  ]).jsonString()
}
