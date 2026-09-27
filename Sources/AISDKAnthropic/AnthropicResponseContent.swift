import AISDKProviderUtils
import Foundation

/// Keeps the listed keys of an object, like a strict schema that strips unknown fields.
func pick(_ value: JSONValue?, _ keys: [String]) -> JSONValue? {
  guard let object = value?.objectValue else { return value }
  var result: JSONObject = [:]
  for key in keys {
    if let field = object[key] { result[key] = field }
  }
  return .object(result)
}

/// A document that citations can point to.
struct AnthropicCitationDocument {
  var title: String
  var filename: String?
  var mediaType: String
}

/// The fields of each citation type. Mirrors upstream `anthropicCitationSchema`.
func normalizeCitation(_ citation: JSONValue) -> JSONValue {
  let keys: [String] =
    switch citation["type"]?.stringValue {
    case "web_search_result_location": ["type", "cited_text", "url", "title", "encrypted_index"]
    case "page_location":
      ["type", "cited_text", "document_index", "document_title", "start_page_number", "end_page_number", "file_id"]
    case "char_location":
      ["type", "cited_text", "document_index", "document_title", "start_char_index", "end_char_index", "file_id"]
    case "content_block_location":
      ["type", "cited_text", "document_index", "document_title", "start_block_index", "end_block_index", "file_id"]
    case "search_result_location":
      ["type", "cited_text", "search_result_index", "source", "title", "start_block_index", "end_block_index"]
    default: Array((citation.objectValue ?? [:]).keys)
    }
  return pick(citation, keys) ?? citation
}

/// Creates a source for a citation. Mirrors upstream `createCitationSource`.
func createCitationSource(
  _ citation: JSONValue, documents: [AnthropicCitationDocument], generateId: IdGenerator
) -> LanguageModelV4Source? {
  switch citation["type"]?.stringValue {
  case "web_search_result_location":
    return .url(
      id: generateId(), url: citation["url"]?.stringValue ?? "", title: citation["title"]?.stringValue,
      providerMetadata: [
        "anthropic": jsonObject(["citedText": citation["cited_text"], "encryptedIndex": citation["encrypted_index"]])
          .objectValue ?? [:]
      ])
  case "page_location", "char_location":
    guard let index = citation["document_index"]?.intValue, documents.indices.contains(index) else { return nil }
    let document = documents[index]
    let isPage = citation["type"] == "page_location"
    let metadata =
      isPage
      ? jsonObject([
        "citedText": citation["cited_text"], "startPageNumber": citation["start_page_number"],
        "endPageNumber": citation["end_page_number"],
      ])
      : jsonObject([
        "citedText": citation["cited_text"], "startCharIndex": citation["start_char_index"],
        "endCharIndex": citation["end_char_index"],
      ])
    return .document(
      id: generateId(), mediaType: document.mediaType,
      title: citation["document_title"]?.stringValue ?? document.title, filename: document.filename,
      providerMetadata: ["anthropic": metadata.objectValue ?? [:]])
  default:
    return nil
  }
}

/// `{type, toolId?}` for a tool call's caller. Mirrors upstream `getAnthropicCallerInfo`.
func anthropicCallerInfo(_ caller: JSONValue?) -> JSONValue? {
  guard let caller, let type = caller["type"] else { return nil }
  return jsonObject(["type": type, "toolId": caller["tool_id"]])
}

func anthropicCallerMetadata(_ caller: JSONValue?) -> SharedV4ProviderMetadata? {
  anthropicCallerInfo(caller).map { ["anthropic": ["caller": $0]] }
}

/// `{action: member, ...input}` for a toolset member call. Mirrors upstream `toToolsetMemberInput`.
func toolsetMemberInput(memberName: String, input: JSONValue?) -> JSONValue {
  var object = input?.objectValue ?? [:]
  object["action"] = .string(memberName)
  return .object(object)
}

/// Converts server tool results and MCP blocks, shared by responses and streams.
struct AnthropicContentConverter {
  let toolNameMapping: ToolNameMapping
  let generateId: IdGenerator
  var citationDocuments: [AnthropicCitationDocument]
  var mcpToolCalls: [String: LanguageModelV4ToolCall] = [:]
  var serverToolCalls: [String: String] = [:]

  init(toolNameMapping: ToolNameMapping, generateId: @escaping IdGenerator, citationDocuments: [AnthropicCitationDocument]) {
    self.toolNameMapping = toolNameMapping
    self.generateId = generateId
    self.citationDocuments = citationDocuments
  }

  private func custom(_ providerToolName: String) -> String {
    toolNameMapping.toCustomToolName(providerToolName)
  }

  private func result(
    _ block: JSONValue, toolName: String, result: JSONValue, isError: Bool? = nil, withCaller: Bool = false
  ) -> LanguageModelV4Content {
    .toolResult(
      LanguageModelV4ToolResult(
        toolCallId: block["tool_use_id"]?.stringValue ?? "", toolName: toolName, result: result, isError: isError,
        providerMetadata: withCaller ? anthropicCallerMetadata(block["caller"]) : nil))
  }

  /// The content for a result or MCP block, or `nil` for other block types.
  mutating func convert(_ block: JSONValue) -> [LanguageModelV4Content]? {
    let content = block["content"]
    let contentType = content?["type"]?.stringValue
    switch block["type"]?.stringValue {
    case "mcp_tool_use":
      let call = LanguageModelV4ToolCall(
        toolCallId: block["id"]?.stringValue ?? "", toolName: block["name"]?.stringValue ?? "",
        input: (block["input"] ?? .null).jsonString(), providerExecuted: true, dynamic: true,
        providerMetadata: [
          "anthropic": jsonObject(["type": "mcp-tool-use", "serverName": block["server_name"]]).objectValue ?? [:]
        ])
      mcpToolCalls[call.toolCallId] = call
      return [.toolCall(call)]

    case "mcp_tool_result":
      let call = mcpToolCalls[block["tool_use_id"]?.stringValue ?? ""]
      return [
        .toolResult(
          LanguageModelV4ToolResult(
            toolCallId: block["tool_use_id"]?.stringValue ?? "", toolName: call?.toolName ?? "",
            result: normalizeMCPContent(content), isError: block["is_error"]?.boolValue, dynamic: true,
            providerMetadata: call?.providerMetadata))
      ]

    case "web_fetch_tool_result":
      if contentType == "web_fetch_result" {
        let document = content?["content"]
        let source = document?["source"]
        citationDocuments.append(
          AnthropicCitationDocument(
            title: document?["title"]?.stringValue ?? content?["url"]?.stringValue ?? "",
            mediaType: source?["media_type"]?.stringValue ?? ""))
        return [
          result(
            block, toolName: custom("web_fetch"),
            result: jsonObject([
              "type": "web_fetch_result", "url": content?["url"], "retrievedAt": content?["retrieved_at"] ?? .null,
              "content": jsonObject([
                "type": document?["type"], "title": document?["title"] ?? .null,
                "citations": pick(document?["citations"], ["enabled"]),
                "source": jsonObject([
                  "type": source?["type"], "mediaType": source?["media_type"], "data": source?["data"],
                ]),
              ]),
            ]),
            withCaller: true)
        ]
      }
      if contentType == "web_fetch_tool_result_error" {
        return [
          result(
            block, toolName: custom("web_fetch"),
            result: ["type": "web_fetch_tool_result_error", "errorCode": content?["error_code"] ?? .null],
            isError: true, withCaller: true)
        ]
      }
      return []

    case "web_search_tool_result":
      if let results = content?.arrayValue {
        var parts = [
          result(
            block, toolName: custom("web_search"),
            result: .array(
              results.map { item in
                jsonObject([
                  "url": item["url"], "title": item["title"].flatMap { $0.isNull ? nil : $0 },
                  "pageAge": item["page_age"] ?? .null, "encryptedContent": item["encrypted_content"],
                  "type": item["type"],
                ])
              }),
            withCaller: true)
        ]
        for item in results {
          parts.append(
            .source(
              .url(
                id: generateId(), url: item["url"]?.stringValue ?? "", title: item["title"]?.stringValue,
                providerMetadata: ["anthropic": ["pageAge": item["page_age"] ?? .null]])))
        }
        return parts
      }
      return [
        result(
          block, toolName: custom("web_search"),
          result: ["type": "web_search_tool_result_error", "errorCode": content?["error_code"] ?? .null],
          isError: true, withCaller: true)
      ]

    case "code_execution_tool_result":
      switch contentType {
      case "code_execution_result":
        return [
          result(
            block, toolName: custom("code_execution"),
            result: jsonObject([
              "type": content?["type"], "stdout": content?["stdout"], "stderr": content?["stderr"],
              "return_code": content?["return_code"], "content": outputFiles(content?["content"]),
            ]))
        ]
      case "encrypted_code_execution_result":
        return [
          result(
            block, toolName: custom("code_execution"),
            result: jsonObject([
              "type": content?["type"], "encrypted_stdout": content?["encrypted_stdout"], "stderr": content?["stderr"],
              "return_code": content?["return_code"], "content": outputFiles(content?["content"]),
            ]))
        ]
      case "code_execution_tool_result_error":
        return [
          result(
            block, toolName: custom("code_execution"),
            result: ["type": "code_execution_tool_result_error", "errorCode": content?["error_code"] ?? .null],
            isError: true)
        ]
      default:
        return []
      }

    case "bash_code_execution_tool_result", "text_editor_code_execution_tool_result":
      return [result(block, toolName: custom("code_execution"), result: normalizeCodeExecutionContent(content))]

    case "tool_search_tool_result":
      var providerToolName = serverToolCalls[block["tool_use_id"]?.stringValue ?? ""]
      if providerToolName == nil {
        providerToolName =
          custom("tool_search_tool_bm25") != "tool_search_tool_bm25" ? "tool_search_tool_bm25" : "tool_search_tool_regex"
      }
      let toolName = custom(providerToolName ?? "tool_search_tool_regex")
      if contentType == "tool_search_tool_search_result" {
        let references = (content?["tool_references"]?.arrayValue ?? []).map { reference -> JSONValue in
          jsonObject(["type": reference["type"], "toolName": reference["tool_name"]])
        }
        return [result(block, toolName: toolName, result: .array(references))]
      }
      return [
        result(
          block, toolName: toolName,
          result: ["type": "tool_search_tool_result_error", "errorCode": content?["error_code"] ?? .null],
          isError: true)
      ]

    case "advisor_tool_result":
      let toolName = custom("advisor")
      let stopReason = content?["stop_reason"].flatMap { $0.isNull ? nil : $0 }
      switch contentType {
      case "advisor_result":
        return [
          result(
            block, toolName: toolName,
            result: jsonObject(["type": "advisor_result", "text": content?["text"], "stopReason": stopReason]))
        ]
      case "advisor_redacted_result":
        return [
          result(
            block, toolName: toolName,
            result: jsonObject([
              "type": "advisor_redacted_result", "encryptedContent": content?["encrypted_content"],
              "stopReason": stopReason,
            ]))
        ]
      default:
        return [
          result(
            block, toolName: toolName,
            result: ["type": "advisor_tool_result_error", "errorCode": content?["error_code"] ?? .null], isError: true)
        ]
      }

    default:
      return nil
    }
  }
}

private func outputFiles(_ value: JSONValue?) -> JSONValue {
  .array((value?.arrayValue ?? []).map { pick($0, ["type", "file_id"]) ?? $0 })
}

private func normalizeMCPContent(_ content: JSONValue?) -> JSONValue {
  guard let items = content?.arrayValue else { return content ?? .null }
  return .array(items.map { $0.stringValue != nil ? $0 : (pick($0, ["type", "text", "citations"]) ?? $0) })
}

/// The fields of each bash / text editor result type. Mirrors the upstream response schema.
private func normalizeCodeExecutionContent(_ content: JSONValue?) -> JSONValue {
  switch content?["type"]?.stringValue {
  case "bash_code_execution_result":
    return jsonObject([
      "type": content?["type"], "content": outputFiles(content?["content"]), "stdout": content?["stdout"],
      "stderr": content?["stderr"], "return_code": content?["return_code"],
    ])
  case "bash_code_execution_tool_result_error", "text_editor_code_execution_tool_result_error":
    return pick(content, ["type", "error_code"]) ?? .null
  case "text_editor_code_execution_view_result":
    return pick(content, ["type", "content", "file_type", "num_lines", "start_line", "total_lines"]) ?? .null
  case "text_editor_code_execution_create_result":
    return pick(content, ["type", "is_file_update"]) ?? .null
  case "text_editor_code_execution_str_replace_result":
    return pick(content, ["type", "lines", "new_lines", "new_start", "old_lines", "old_start"]) ?? .null
  default:
    return content ?? .null
  }
}

// MARK: - Metadata

/// Usage with the nested fields the upstream schema keeps.
func normalizeRawUsage(_ usage: JSONObject) -> JSONObject {
  var result = usage
  if let details = usage["output_tokens_details"], !details.isNull {
    result["output_tokens_details"] = pick(details, ["thinking_tokens"])
  }
  if let iterations = usage["iterations"]?.arrayValue {
    result["iterations"] = .array(
      iterations.map {
        pick(
          $0,
          ["type", "model", "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"])
          ?? $0
      })
  }
  return result
}

func anthropicIterationsMetadata(_ iterations: JSONValue?) -> JSONValue {
  guard let items = iterations?.arrayValue else { return .null }
  return .array(
    items.map { item in
      let cacheCreation = item["cache_creation_input_tokens"].flatMap { ($0.intValue ?? 0) > 0 ? $0 : nil }
      let cacheRead = item["cache_read_input_tokens"].flatMap { ($0.intValue ?? 0) > 0 ? $0 : nil }
      return jsonObject([
        "type": item["type"], "model": item["model"].flatMap { $0.isNull ? nil : $0 },
        "inputTokens": item["input_tokens"], "outputTokens": item["output_tokens"],
        "cacheCreationInputTokens": cacheCreation, "cacheReadInputTokens": cacheRead,
      ])
    })
}

func anthropicContainerMetadata(_ container: JSONValue?, includeSkills: Bool = true) -> JSONValue {
  guard let container, !container.isNull else { return .null }
  let skills: JSONValue =
    includeSkills
    ? (container["skills"]?.arrayValue.map { skills in
      .array(
        skills.map { skill in
          jsonObject(["type": skill["type"], "skillId": skill["skill_id"], "version": skill["version"]])
        })
    } ?? .null) : .null
  return jsonObject(["expiresAt": container["expires_at"], "id": container["id"], "skills": skills])
}

func anthropicContextManagementMetadata(_ contextManagement: JSONValue?) -> JSONValue? {
  guard let contextManagement, !contextManagement.isNull else { return nil }
  let edits = (contextManagement["applied_edits"]?.arrayValue ?? []).compactMap { edit -> JSONValue? in
    switch edit["type"]?.stringValue {
    case "clear_tool_uses_20250919":
      jsonObject([
        "type": edit["type"], "clearedToolUses": edit["cleared_tool_uses"],
        "clearedInputTokens": edit["cleared_input_tokens"],
      ])
    case "clear_thinking_20251015":
      jsonObject([
        "type": edit["type"], "clearedThinkingTurns": edit["cleared_thinking_turns"],
        "clearedInputTokens": edit["cleared_input_tokens"],
      ])
    case "compact_20260112":
      ["type": "compact_20260112"]
    default:
      nil
    }
  }
  return ["appliedEdits": .array(edits)]
}

func anthropicStopDetailsMetadata(_ stopDetails: JSONValue?) -> JSONValue? {
  guard let stopDetails, !stopDetails.isNull else { return nil }
  func present(_ key: String) -> JSONValue? { stopDetails[key].flatMap { $0.isNull ? nil : $0 } }
  return jsonObject([
    "type": stopDetails["type"], "category": present("category"), "explanation": present("explanation"),
    "recommendedModel": present("recommended_model"),
  ])
}

func normalizeInputTransformations(_ value: JSONValue?) -> JSONValue? {
  guard let items = value?.arrayValue else { return nil }
  return .array(items.map { pick($0, ["type", "path", "reason"]) ?? $0 })
}

func normalizeSafeguardResults(_ value: JSONValue?) -> JSONValue? {
  guard let items = value?.arrayValue else { return nil }
  return .array(
    items.map { item in
      let status = item["status"]
      let toolUses = status?["tool_uses"].map { toolUses -> JSONValue in
        guard let object = toolUses.objectValue else { return toolUses }
        return .object(object.mapValues { pick($0, ["type", "outcome", "explanation"]) ?? $0 })
      }
      return jsonObject(["type": item["type"], "status": jsonObject(["type": status?["type"], "tool_uses": toolUses])])
    })
}
