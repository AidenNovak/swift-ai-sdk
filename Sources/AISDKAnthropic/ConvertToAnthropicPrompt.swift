import AISDKProviderUtils
import Foundation

/// Tracks cache breakpoints across tools and messages. Mirrors upstream `CacheControlValidator`.
final class CacheControlValidator {
  private static let maxBreakpoints = 4
  private var breakpointCount = 0
  private(set) var warnings: [SharedV4Warning] = []

  func cacheControl(_ options: SharedV4ProviderOptions?, type: String, canCache: Bool = true) -> JSONValue? {
    let anthropic = options?["anthropic"]
    guard let value = anthropic?["cacheControl"] ?? anthropic?["cache_control"] else { return nil }
    guard canCache else {
      warnings.append(
        .unsupported(
          feature: "cache_control on non-cacheable context",
          details: "cache_control cannot be set on \(type). It will be ignored."))
      return nil
    }
    breakpointCount += 1
    if breakpointCount > Self.maxBreakpoints {
      warnings.append(
        .unsupported(
          feature: "cacheControl breakpoint limit",
          details:
            "Maximum \(Self.maxBreakpoints) cache breakpoints exceeded (found \(breakpointCount)). This breakpoint will be ignored."
        ))
      return nil
    }
    return value
  }
}

struct AnthropicPrompt {
  var system: [JSONValue]?
  var messages: [JSONValue]
}

private enum Block {
  case system([LanguageModelV4Message])
  case assistant([LanguageModelV4Message])
  case user([LanguageModelV4Message])
}

/// Groups consecutive messages; tool messages join user blocks. Mirrors upstream `groupIntoBlocks`.
private func groupIntoBlocks(_ prompt: LanguageModelV4Prompt) -> [Block] {
  var blocks: [Block] = []
  for message in prompt {
    switch (message.role, blocks.last) {
    case (.system, .system(let messages)?):
      blocks[blocks.count - 1] = .system(messages + [message])
    case (.system, _):
      blocks.append(.system([message]))
    case (.assistant, .assistant(let messages)?):
      blocks[blocks.count - 1] = .assistant(messages + [message])
    case (.assistant, _):
      blocks.append(.assistant([message]))
    case (.user, .user(let messages)?), (.tool, .user(let messages)?):
      blocks[blocks.count - 1] = .user(messages + [message])
    case (.user, _), (.tool, _):
      blocks.append(.user([message]))
    }
  }
  return blocks
}

private func textFromBytes(_ data: SharedV4FileData) -> String {
  switch data {
  case .data(let bytes): String(decoding: bytes, as: UTF8.self)
  case .base64(let base64): String(decoding: convertBase64ToData(base64) ?? Data(), as: UTF8.self)
  case .text(let text): text
  case .url, .reference: ""
  }
}

/// The toolset a tool call belongs to: from the tools, or from the call's metadata.
private func toolsetName(_ toolName: String, options: SharedV4ProviderOptions?, toolsetNames: [String: String])
  -> String?
{
  toolsetNames[toolName] ?? options?["anthropic"]?["toolsetName"]?.stringValue
}

/// The caller of a tool call (direct or from programmatic tool calling). Mirrors upstream `getAnthropicCaller`.
private func caller(_ options: SharedV4ProviderOptions?) -> JSONValue? {
  guard let caller = options?["anthropic"]?["caller"], let type = caller["type"]?.stringValue else { return nil }
  if type == "code_execution_20250825" || type == "code_execution_20260120",
    let toolId = caller["toolId"]?.stringValue, !toolId.isEmpty
  {
    return ["type": .string(type), "tool_id": .string(toolId)]
  }
  return type == "direct" ? ["type": "direct"] : nil
}

private func toolInput(_ input: JSONValue) -> JSONObject {
  input.objectValue ?? ["rawInvalidInput": input]
}

/// The error code of a provider tool error output. Mirrors upstream `extractErrorValue`.
private func errorCode(_ value: JSONValue) -> String? {
  if let text = value.stringValue {
    return (try? JSONValue(jsonString: text))?["errorCode"]?.stringValue
  }
  return value["errorCode"]?.stringValue
}

extension LanguageModelV4ToolResultOutput.ContentPart {
  fileprivate var anthropicProviderOptions: SharedV4ProviderOptions? {
    switch self {
    case .text(_, let options), .file(_, _, _, let options), .custom(let options): options
    }
  }
}

/// Keeps thinking blocks in place and moves client tool uses to the end of
/// each segment between them. Mirrors upstream `moveToolUseBlocksToEnd`.
private func moveToolUseBlocksToEnd(_ content: [JSONValue]) -> [JSONValue] {
  var result: [JSONValue] = []
  var segment: [JSONValue] = []
  func flush() {
    result += segment.filter { $0["type"] != "tool_use" } + segment.filter { $0["type"] == "tool_use" }
    segment = []
  }
  for part in content {
    if part["type"] == "thinking" || part["type"] == "redacted_thinking" {
      flush()
      result.append(part)
    } else {
      segment.append(part)
    }
  }
  flush()
  return result
}

/// Converts a prompt to the Anthropic Messages format. Mirrors upstream `convertToAnthropicPrompt`.
func convertToAnthropicPrompt(
  prompt: LanguageModelV4Prompt,
  sendReasoning: Bool,
  warnings: inout [SharedV4Warning],
  validator: CacheControlValidator,
  toolNameMapping: ToolNameMapping = ToolNameMapping(tools: nil, providerToolNames: [:]),
  toolsetNames: [String: String] = [:]
) throws -> (prompt: AnthropicPrompt, betas: Set<String>) {
  var converter = AnthropicPromptConverter(
    sendReasoning: sendReasoning, validator: validator, toolNameMapping: toolNameMapping, toolsetNames: toolsetNames)
  let blocks = groupIntoBlocks(prompt)
  for (index, block) in blocks.enumerated() {
    switch block {
    case .system(let messages):
      try converter.convertSystem(messages, isFirstBlock: index == 0)
    case .user(let messages):
      try converter.convertUser(messages)
    case .assistant(let messages):
      try converter.convertAssistant(messages, isLastBlock: index == blocks.count - 1)
    }
  }
  warnings += converter.warnings
  return (AnthropicPrompt(system: converter.system, messages: converter.messages), converter.betas)
}

private struct AnthropicPromptConverter {
  let sendReasoning: Bool
  let validator: CacheControlValidator
  let toolNameMapping: ToolNameMapping
  let toolsetNames: [String: String]
  var system: [JSONValue]?
  var messages: [JSONValue] = []
  var betas = Set<String>()
  var warnings: [SharedV4Warning] = []

  init(
    sendReasoning: Bool, validator: CacheControlValidator, toolNameMapping: ToolNameMapping,
    toolsetNames: [String: String]
  ) {
    self.sendReasoning = sendReasoning
    self.validator = validator
    self.toolNameMapping = toolNameMapping
    self.toolsetNames = toolsetNames
  }

  // MARK: System

  private struct ConvertedSystemMessage {
    var content: [JSONValue]
    var clearAt: String?
    var effort: String?
    var toolChangeCount: Int
  }

  mutating func convertSystem(_ systemMessages: [LanguageModelV4Message], isFirstBlock: Bool) throws {
    var converted: [ConvertedSystemMessage] = []
    for case .system(let text, let providerOptions) in systemMessages {
      let options = try parseProviderOptions(
        provider: "anthropic", providerOptions: providerOptions, as: AnthropicSystemMessageOptions.self)
      let toolChanges = options?.toolChanges ?? []
      var content: [JSONValue] = []
      if !text.isEmpty || (toolChanges.isEmpty && options?.clearAt == nil && options?.effort == nil) {
        content.append(
          jsonObject([
            "type": "text", "text": .string(text),
            "cache_control": validator.cacheControl(providerOptions, type: "system message"),
          ]))
      }
      for change in toolChanges {
        content.append([
          "type": .string(change.type),
          "tool": ["type": "tool_reference", "name": .string(toolNameMapping.toProviderToolName(change.toolName))],
        ])
      }
      converted.append(
        ConvertedSystemMessage(
          content: content, clearAt: options?.clearAt, effort: options?.effort, toolChangeCount: toolChanges.count))
    }

    let toolChangeCount = converted.reduce(0) { $0 + $1.toolChangeCount }
    let hasInlineSystemOptions = converted.contains { $0.clearAt != nil || $0.effort != nil }

    if isFirstBlock || (system == nil && toolChangeCount == 0 && !hasInlineSystemOptions) {
      if toolChangeCount > 0 {
        warnings.append(
          .other(
            message:
              "tool changes on the initial system message are not supported by Anthropic. Configure the initial tool set via the tools option instead. The tool changes have been ignored."
          ))
      }
      for message in converted {
        if message.content.isEmpty && message.clearAt == nil, let effort = message.effort {
          messages.append(["role": "system", "content": [], "output_config": ["effort": .string(effort)]])
          betas.insert("mid-conversation-output-config-2026-07-01")
        } else if message.clearAt != nil || message.effort != nil {
          warnings.append(
            .other(
              message:
                "clearAt and effort on this initial system message are not supported by Anthropic. Use a separate effort-only system message with empty content to set effort. These options have been ignored."
            ))
        }
      }
      system = converted.flatMap { $0.content.filter { $0["type"] == "text" } }
    } else {
      betas.insert("mid-conversation-system-2026-04-07")
      for message in converted {
        messages.append(
          jsonObject([
            "role": "system", "content": .array(message.content), "clear_at": .optional(message.clearAt),
            "output_config": message.effort.map { ["effort": .string($0)] },
          ]))
        if message.toolChangeCount > 0 { betas.insert("mid-conversation-tool-changes-2026-07-01") }
        if message.clearAt != nil { betas.insert("mid-conversation-system-clear-at-2026-08-21") }
        if message.effort != nil { betas.insert("mid-conversation-output-config-2026-07-01") }
      }
    }
  }

  // MARK: User

  mutating func convertUser(_ userMessages: [LanguageModelV4Message]) throws {
    var content: [JSONValue] = []
    for message in userMessages {
      switch message {
      case .user(let parts, let messageOptions):
        for (index, part) in parts.enumerated() {
          let isLastPart = index == parts.count - 1
          let partOptions: SharedV4ProviderOptions? =
            switch part {
            case .text(let text): text.providerOptions
            case .file(let file): file.providerOptions
            }
          let cacheControl =
            validator.cacheControl(partOptions, type: "user message part")
            ?? (isLastPart ? validator.cacheControl(messageOptions, type: "user message") : nil)
          switch part {
          case .text(let text):
            content.append(jsonObject(["type": "text", "text": .string(text.text), "cache_control": cacheControl]))
          case .file(let file):
            content.append(try convertFilePart(file, cacheControl: cacheControl))
          }
        }
      case .tool(let parts, let messageOptions):
        for (index, part) in parts.enumerated() {
          guard case .toolResult(let result) = part else { continue }
          content.append(
            convertToolResult(result, messageOptions: messageOptions, isLastPart: index == parts.count - 1))
        }
      default:
        break
      }
    }
    messages.append(["role": "user", "content": .array(content)])
  }

  private mutating func convertFilePart(_ part: LanguageModelV4FilePart, cacheControl: JSONValue?) throws -> JSONValue {
    let options = try parseProviderOptions(
      provider: "anthropic", providerOptions: part.providerOptions, as: AnthropicFilePartOptions.self)
    let citations: JSONValue? = options?.citations?.enabled == true ? ["enabled": true] : nil
    let topLevel = getTopLevelMediaType(part.mediaType)
    func document(_ source: JSONValue) -> JSONValue {
      jsonObject([
        "type": "document", "source": source, "title": .optional(options?.title ?? part.filename),
        "context": .optional(options?.context.flatMap { $0.isEmpty ? nil : $0 }), "citations": citations,
        "cache_control": cacheControl,
      ])
    }

    switch part.data {
    case .reference(let reference):
      let fileId = try resolveProviderReference(reference, provider: "anthropic")
      betas.insert("files-api-2025-04-14")
      if options?.containerUpload == true {
        return ["type": "container_upload", "file_id": .string(fileId)]
      }
      return jsonObject([
        "type": topLevel == "image" ? "image" : "document", "source": ["type": "file", "file_id": .string(fileId)],
        "cache_control": cacheControl,
      ])
    case .text(let text):
      return document(["type": "text", "media_type": "text/plain", "data": .string(text)])
    case .url(let url, _):
      if topLevel == "image" {
        return jsonObject([
          "type": "image", "source": ["type": "url", "url": .string(url.absoluteString)], "cache_control": cacheControl,
        ])
      }
      if topLevel == "application" && part.mediaType == "application/pdf" {
        betas.insert("pdfs-2024-09-25")
        return document(["type": "url", "url": .string(url.absoluteString)])
      }
      if part.mediaType == "text/plain" {
        return document(["type": "url", "url": .string(url.absoluteString)])
      }
      throw UnsupportedFunctionalityError(functionality: "media type: \(part.mediaType)")
    case .data, .base64:
      if topLevel == "image" {
        return jsonObject([
          "type": "image",
          "source": [
            "type": "base64", "media_type": .string(try resolveFullMediaType(part)),
            "data": .string(part.data.base64String ?? ""),
          ],
          "cache_control": cacheControl,
        ])
      }
      if topLevel == "application", try resolveFullMediaType(part) == "application/pdf" {
        betas.insert("pdfs-2024-09-25")
        return document(["type": "base64", "media_type": "application/pdf", "data": .string(part.data.base64String ?? "")])
      }
      if part.mediaType == "text/plain" {
        return document(["type": "text", "media_type": "text/plain", "data": .string(textFromBytes(part.data))])
      }
      throw UnsupportedFunctionalityError(functionality: "media type: \(part.mediaType)")
    }
  }

  private mutating func convertToolResult(
    _ result: LanguageModelV4ToolResultPart, messageOptions: SharedV4ProviderOptions?, isLastPart: Bool
  ) -> JSONValue {
    let output = result.output
    let outputOptions: SharedV4ProviderOptions? =
      switch output {
      case .text(_, let options), .json(_, let options), .errorText(_, let options), .errorJSON(_, let options),
        .executionDenied(_, let options):
        options
      case .content(let parts):
        parts.lazy.compactMap(\.anthropicProviderOptions).first
      }
    let cacheControl =
      validator.cacheControl(result.providerOptions, type: "tool result part")
      ?? validator.cacheControl(outputOptions, type: "tool result output")
      ?? (isLastPart ? validator.cacheControl(messageOptions, type: "tool result message") : nil)

    let value: JSONValue
    var isError = false
    switch output {
    case .content(let parts):
      value = .array(parts.compactMap { convertToolContentPart($0) })
    case .text(let text, _):
      value = .string(text)
    case .errorText(let text, _):
      value = .string(text)
      isError = true
    case .executionDenied(let reason, _):
      value = .string(reason ?? "Tool call execution denied.")
    case .json(let json, _):
      value = .string(json.jsonString())
    case .errorJSON(let json, _):
      value = .string(json.jsonString())
      isError = true
    }

    return jsonObject([
      "type": "tool_result", "tool_use_id": .string(result.toolCallId),
      "toolset_name": .optional(toolsetName(result.toolName, options: result.providerOptions, toolsetNames: toolsetNames)),
      "content": value, "is_error": isError ? true : nil, "cache_control": cacheControl,
    ])
  }

  private mutating func convertToolContentPart(_ part: LanguageModelV4ToolResultOutput.ContentPart) -> JSONValue? {
    switch part {
    case .text(let text, _):
      return ["type": "text", "text": .string(text)]
    case .file(let data, let mediaType, _, _):
      let topLevel = getTopLevelMediaType(mediaType)
      switch data {
      case .url(let url, _):
        return ["type": topLevel == "image" ? "image" : "document", "source": ["type": "url", "url": .string(url.absoluteString)]]
      case .data, .base64:
        let fullType = (try? resolveFullMediaType(LanguageModelV4FilePart(data: data, mediaType: mediaType))) ?? mediaType
        if topLevel == "image" {
          return [
            "type": "image",
            "source": ["type": "base64", "media_type": .string(fullType), "data": .string(data.base64String ?? "")],
          ]
        }
        if fullType == "application/pdf" {
          betas.insert("pdfs-2024-09-25")
          return [
            "type": "document",
            "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64String ?? "")],
          ]
        }
        warnings.append(.other(message: "unsupported tool content part type: file with media type: \(mediaType)"))
        return nil
      case .reference:
        warnings.append(.other(message: "unsupported tool content part type: file with data type: reference"))
        return nil
      case .text:
        warnings.append(.other(message: "unsupported tool content part type: file with data type: text"))
        return nil
      }
    case .custom(let options):
      let anthropic = options?["anthropic"]
      if anthropic?["type"] == "tool-reference", let toolName = anthropic?["toolName"]?.stringValue {
        return ["type": "tool_reference", "tool_name": .string(toolName)]
      }
      warnings.append(.other(message: "unsupported custom tool content part"))
      return nil
    }
  }

  // MARK: Assistant

  mutating func convertAssistant(_ assistantMessages: [LanguageModelV4Message], isLastBlock: Bool) throws {
    var content: [JSONValue] = []
    var mcpToolUseIds = Set<String>()
    for (messageIndex, message) in assistantMessages.enumerated() {
      guard case .assistant(let parts, let messageOptions) = message else { continue }
      let isLastMessage = messageIndex == assistantMessages.count - 1
      for (partIndex, part) in parts.enumerated() {
        let isLastPart = partIndex == parts.count - 1
        let validator = validator
        func cacheControl(_ options: SharedV4ProviderOptions?) -> JSONValue? {
          validator.cacheControl(options, type: "assistant message part")
            ?? (isLastPart ? validator.cacheControl(messageOptions, type: "assistant message") : nil)
        }
        switch part {
        case .text(let text):
          let metadata = text.providerOptions?["anthropic"]
          if metadata?["type"] == "compaction" {
            if text.text.isEmpty { break }
            let signature = metadata?["signature"]?.stringValue
            if signature != nil { betas.insert("compact-2026-09-04") }
            content.append(
              jsonObject([
                "type": "compaction", "content": .string(text.text), "signature": .optional(signature),
                "cache_control": cacheControl(text.providerOptions),
              ]))
          } else {
            let trim = isLastBlock && isLastMessage && isLastPart
            content.append(
              jsonObject([
                "type": "text",
                "text": .string(trim ? text.text.trimmingCharacters(in: .whitespacesAndNewlines) : text.text),
                "citations": metadata?["citations"], "cache_control": cacheControl(text.providerOptions),
              ]))
          }
        case .reasoning(let reasoning):
          guard sendReasoning else {
            warnings.append(.other(message: "sending reasoning content is disabled for this model"))
            break
          }
          let metadata = try parseProviderOptions(
            provider: "anthropic", providerOptions: reasoning.providerOptions, as: AnthropicReasoningMetadata.self)
          if let signature = metadata?.signature {
            _ = validator.cacheControl(reasoning.providerOptions, type: "thinking block", canCache: false)
            content.append(["type": "thinking", "thinking": .string(reasoning.text), "signature": .string(signature)])
          } else if let redacted = metadata?.redactedData {
            _ = validator.cacheControl(reasoning.providerOptions, type: "redacted thinking block", canCache: false)
            content.append(["type": "redacted_thinking", "data": .string(redacted)])
          } else {
            warnings.append(.other(message: "unsupported reasoning metadata"))
          }
        case .toolCall(let call):
          if let block = convertToolCall(
            call, cacheControl: cacheControl(call.providerOptions), mcpToolUseIds: &mcpToolUseIds)
          {
            content.append(block)
          }
        case .toolResult(let result):
          if let block = try convertProviderToolResult(
            result, cacheControl: cacheControl(result.providerOptions), mcpToolUseIds: mcpToolUseIds)
          {
            content.append(block)
          }
        case .file, .reasoningFile, .custom:
          break
        }
      }
    }
    if !content.isEmpty {
      messages.append(["role": "assistant", "content": .array(moveToolUseBlocksToEnd(content))])
    }
  }

  private mutating func convertToolCall(
    _ call: LanguageModelV4ToolCallPart, cacheControl: JSONValue?, mcpToolUseIds: inout Set<String>
  ) -> JSONValue? {
    let caller = caller(call.providerOptions)
    guard call.providerExecuted == true else {
      if let toolset = toolsetName(call.toolName, options: call.providerOptions, toolsetNames: toolsetNames) {
        var input = toolInput(call.input)
        guard let action = input.removeValue(forKey: "action")?.stringValue else {
          warnings.append(.other(message: "toolset tool call for tool \(call.toolName) is missing the action"))
          return nil
        }
        return jsonObject([
          "type": "tool_use", "id": .string(call.toolCallId), "name": .string(action), "toolset_name": .string(toolset),
          "input": .object(input), "caller": caller, "cache_control": cacheControl,
        ])
      }
      return jsonObject([
        "type": "tool_use", "id": .string(call.toolCallId), "name": .string(call.toolName),
        "input": .object(toolInput(call.input)), "caller": caller, "cache_control": cacheControl,
      ])
    }

    let providerToolName = toolNameMapping.toProviderToolName(call.toolName)
    func serverToolUse(_ name: String, _ input: JSONValue) -> JSONValue {
      jsonObject([
        "type": "server_tool_use", "id": .string(call.toolCallId), "name": .string(name), "input": input,
        "caller": caller, "cache_control": cacheControl,
      ])
    }

    if call.providerOptions?["anthropic"]?["type"] == "mcp-tool-use" {
      mcpToolUseIds.insert(call.toolCallId)
      guard let serverName = call.providerOptions?["anthropic"]?["serverName"]?.stringValue else {
        warnings.append(.other(message: "mcp tool use server name is required and must be a string"))
        return nil
      }
      return jsonObject([
        "type": "mcp_tool_use", "id": .string(call.toolCallId), "name": .string(call.toolName), "input": call.input,
        "server_name": .string(serverName), "cache_control": cacheControl,
      ])
    }
    if providerToolName == "code_execution", var input = call.input.objectValue,
      let type = input["type"]?.stringValue
    {
      if type == "bash_code_execution" || type == "text_editor_code_execution" {
        input["type"] = nil
        return serverToolUse(type, .object(input))
      }
      if type == "programmatic-tool-call" {
        input["type"] = nil
        return serverToolUse("code_execution", .object(input))
      }
    }
    switch providerToolName {
    case "code_execution", "web_fetch", "web_search", "tool_search_tool_regex", "tool_search_tool_bm25":
      return serverToolUse(providerToolName, call.input)
    case "advisor":
      return serverToolUse("advisor", [:])
    default:
      warnings.append(.other(message: "provider executed tool call for tool \(call.toolName) is not supported"))
      return nil
    }
  }

  private mutating func unsupportedOutput(_ output: LanguageModelV4ToolResultOutput, toolName: String) {
    let type: String =
      switch output {
      case .text: "text"
      case .json: "json"
      case .errorText: "error-text"
      case .errorJSON: "error-json"
      case .executionDenied: "execution-denied"
      case .content: "content"
      }
    warnings.append(
      .other(message: "provider executed tool result output type \(type) for tool \(toolName) is not supported"))
  }

  private mutating func convertProviderToolResult(
    _ result: LanguageModelV4ToolResultPart, cacheControl: JSONValue?, mcpToolUseIds: Set<String>
  ) throws -> JSONValue? {
    let providerToolName = toolNameMapping.toProviderToolName(result.toolName)
    let caller = caller(result.providerOptions)
    let output = result.output
    func block(_ type: String, _ content: JSONValue, withCaller: Bool = false) -> JSONValue {
      jsonObject([
        "type": .string(type), "tool_use_id": .string(result.toolCallId), "content": content,
        "caller": withCaller ? caller : nil, "cache_control": cacheControl,
      ])
    }

    if mcpToolUseIds.contains(result.toolCallId) {
      switch output {
      case .json(let value, _), .errorJSON(let value, _):
        var isError = false
        if case .errorJSON = output { isError = true }
        // Upstream falls through to the unsupported-result warning after converting MCP results.
        warnings.append(.other(message: "provider executed tool result for tool \(result.toolName) is not supported"))
        return jsonObject([
          "type": "mcp_tool_result", "tool_use_id": .string(result.toolCallId), "is_error": .bool(isError),
          "content": value, "cache_control": cacheControl,
        ])
      default:
        unsupportedOutput(output, toolName: result.toolName)
        return nil
      }
    }

    switch providerToolName {
    case "code_execution":
      return try convertCodeExecutionResult(result, block: block)
    case "web_fetch":
      if case .errorJSON(let value, _) = output {
        return block(
          "web_fetch_tool_result",
          ["type": "web_fetch_tool_result_error", "error_code": .string(errorCode(value) ?? "unavailable")],
          withCaller: true)
      }
      guard case .json(let value, _) = output else {
        unsupportedOutput(output, toolName: result.toolName)
        return nil
      }
      let content = value["content"]
      let source = content?["source"]
      return block(
        "web_fetch_tool_result",
        jsonObject([
          "type": "web_fetch_result", "url": value["url"], "retrieved_at": value["retrievedAt"] ?? .null,
          "content": jsonObject([
            "type": "document", "title": content?["title"] ?? .null, "citations": content?["citations"],
            "source": jsonObject(["type": source?["type"], "media_type": source?["mediaType"], "data": source?["data"]]),
          ]),
        ]),
        withCaller: true)
    case "web_search":
      if case .errorJSON(let value, _) = output {
        return block(
          "web_search_tool_result",
          ["type": "web_search_tool_result_error", "error_code": .string(errorCode(value) ?? "unavailable")],
          withCaller: true)
      }
      guard case .json(let value, _) = output else {
        unsupportedOutput(output, toolName: result.toolName)
        return nil
      }
      let results = (value.arrayValue ?? []).map { item in
        jsonObject([
          "url": item["url"], "title": item["title"] ?? .null, "page_age": item["pageAge"] ?? .null,
          "encrypted_content": item["encryptedContent"], "type": item["type"],
        ])
      }
      return block("web_search_tool_result", .array(results), withCaller: true)
    case "tool_search_tool_regex", "tool_search_tool_bm25":
      guard case .json(let value, _) = output else {
        unsupportedOutput(output, toolName: result.toolName)
        return nil
      }
      let references = (value.arrayValue ?? []).map { reference -> JSONValue in
        ["type": "tool_reference", "tool_name": reference["toolName"] ?? .null]
      }
      return block(
        "tool_search_tool_result", ["type": "tool_search_tool_search_result", "tool_references": .array(references)])
    case "advisor":
      let value: JSONValue
      switch output {
      case .json(let json, _), .errorJSON(let json, _): value = json
      default:
        unsupportedOutput(output, toolName: result.toolName)
        return nil
      }
      switch value["type"]?.stringValue {
      case "advisor_result":
        return block(
          "advisor_tool_result",
          jsonObject(["type": "advisor_result", "text": value["text"], "stop_reason": value["stopReason"]]))
      case "advisor_redacted_result":
        return block(
          "advisor_tool_result",
          jsonObject([
            "type": "advisor_redacted_result", "encrypted_content": value["encryptedContent"],
            "stop_reason": value["stopReason"],
          ]))
      default:
        return block(
          "advisor_tool_result", jsonObject(["type": "advisor_tool_result_error", "error_code": value["errorCode"]]))
      }
    default:
      warnings.append(.other(message: "provider executed tool result for tool \(result.toolName) is not supported"))
      return nil
    }
  }

  private mutating func convertCodeExecutionResult(
    _ result: LanguageModelV4ToolResultPart, block: (String, JSONValue, Bool) -> JSONValue
  ) throws -> JSONValue? {
    let output = result.output
    switch output {
    case .errorText(let text, _):
      return codeExecutionError(errorInfo: (try? JSONValue(jsonString: text)) ?? [:], block: block)
    case .errorJSON(let value, _):
      let info = value.stringValue.flatMap { try? JSONValue(jsonString: $0) } ?? value
      return codeExecutionError(errorInfo: info, block: block)
    case .json(let value, _):
      guard let type = value["type"]?.stringValue else {
        warnings.append(
          .other(
            message:
              "provider executed tool result output value is not a valid code execution result for tool \(result.toolName)"
          ))
        return nil
      }
      let content = value["content"] ?? []
      switch type {
      case "code_execution_result":
        return block(
          "code_execution_tool_result",
          jsonObject([
            "type": .string(type), "stdout": value["stdout"], "stderr": value["stderr"],
            "return_code": value["return_code"], "content": content,
          ]), false)
      case "encrypted_code_execution_result":
        return block(
          "code_execution_tool_result",
          jsonObject([
            "type": .string(type), "encrypted_stdout": value["encrypted_stdout"], "stderr": value["stderr"],
            "return_code": value["return_code"], "content": content,
          ]), false)
      case "bash_code_execution_result":
        return block(
          "bash_code_execution_tool_result",
          jsonObject([
            "type": .string(type), "stdout": value["stdout"], "stderr": value["stderr"],
            "return_code": value["return_code"], "content": value["content"],
          ]), false)
      case "bash_code_execution_tool_result_error":
        return block(
          "bash_code_execution_tool_result",
          jsonObject(["type": .string(type), "error_code": value["error_code"]]), false)
      case "text_editor_code_execution_tool_result_error", "text_editor_code_execution_view_result",
        "text_editor_code_execution_create_result", "text_editor_code_execution_str_replace_result":
        return block("text_editor_code_execution_tool_result", value, false)
      default:
        throw TypeValidationError(
          value: value, cause: UnsupportedFunctionalityError(functionality: "code execution result type \(type)"))
      }
    default:
      unsupportedOutput(output, toolName: result.toolName)
      return nil
    }
  }

  private func codeExecutionError(errorInfo: JSONValue, block: (String, JSONValue, Bool) -> JSONValue) -> JSONValue {
    let code = JSONValue.string(errorInfo["errorCode"]?.stringValue ?? "unknown")
    if errorInfo["type"] == "code_execution_tool_result_error" {
      return block("code_execution_tool_result", ["type": "code_execution_tool_result_error", "error_code": code], false)
    }
    return block(
      "bash_code_execution_tool_result", ["type": "bash_code_execution_tool_result_error", "error_code": code], false)
  }
}
