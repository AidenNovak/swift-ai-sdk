import AISDKProviderUtils
import Foundation

/// Tool call arguments must be a JSON object; anything else is sent as `{}`.
private func serializeToolCallArguments(_ input: JSONValue) -> String {
  if case .object = input { return input.jsonString() }
  return "{}"
}

private func promptCacheBreakpoint(_ providerOptions: SharedV4ProviderOptions?) -> JSONValue? {
  providerOptions?["openai"]?["promptCacheBreakpoint"]
}

private func textContent(_ text: String, breakpoint: JSONValue?) -> JSONValue {
  guard let breakpoint else { return .string(text) }
  return [["type": "text", "text": .string(text), "prompt_cache_breakpoint": breakpoint]]
}

private func withBreakpoint(_ part: JSONObject, _ breakpoint: JSONValue?) -> JSONValue {
  var part = part
  if let breakpoint { part["prompt_cache_breakpoint"] = breakpoint }
  return .object(part)
}

private func convertFilePart(_ part: LanguageModelV4FilePart, index: Int) throws -> JSONObject {
  switch part.data {
  case .reference(let reference):
    return ["type": "file", "file": ["file_id": .string(try resolveProviderReference(reference, provider: "openai"))]]
  case .text:
    throw UnsupportedFunctionalityError(functionality: "text file parts")
  case .url, .data, .base64:
    break
  }

  switch getTopLevelMediaType(part.mediaType) {
  case "image":
    let url: String
    if case .url(let fileURL, _) = part.data {
      url = fileURL.absoluteString
    } else {
      url = "data:\(try resolveFullMediaType(part));base64,\(part.data.base64String ?? "")"
    }
    return [
      "type": "image_url",
      "image_url": jsonObject(["url": .string(url), "detail": part.providerOptions?["openai"]?["imageDetail"]]),
    ]
  case "audio":
    if case .url = part.data {
      throw UnsupportedFunctionalityError(functionality: "audio file parts with URLs")
    }
    let mediaType = try resolveFullMediaType(part)
    let format: String =
      switch mediaType {
      case "audio/wav": "wav"
      case "audio/mp3", "audio/mpeg": "mp3"
      default: throw UnsupportedFunctionalityError(functionality: "audio content parts with media type \(mediaType)")
      }
    return ["type": "input_audio", "input_audio": ["data": .string(part.data.base64String ?? ""), "format": .string(format)]]
  default:
    let mediaType = try resolveFullMediaType(part)
    guard mediaType == "application/pdf" else {
      throw UnsupportedFunctionalityError(functionality: "file part media type \(mediaType)")
    }
    if case .url = part.data {
      throw UnsupportedFunctionalityError(functionality: "PDF file parts with URLs")
    }
    return [
      "type": "file",
      "file": [
        "filename": .string(part.filename ?? "part-\(index).pdf"),
        "file_data": .string("data:application/pdf;base64,\(part.data.base64String ?? "")"),
      ],
    ]
  }
}

/// Converts a prompt to OpenAI chat messages. Mirrors upstream `convertToOpenAIChatMessages`.
func convertToOpenAIChatMessages(
  _ prompt: LanguageModelV4Prompt, systemMessageMode: OpenAILanguageModelCapabilities.SystemMessageMode = .system
) throws -> (messages: [JSONValue], warnings: [SharedV4Warning]) {
  var messages: [JSONValue] = []
  var warnings: [SharedV4Warning] = []

  for message in prompt {
    switch message {
    case .system(let content, let options):
      switch systemMessageMode {
      case .system, .developer:
        messages.append([
          "role": .string(systemMessageMode.rawValue),
          "content": textContent(content, breakpoint: promptCacheBreakpoint(options)),
        ])
      case .remove:
        warnings.append(.other(message: "system messages are removed for this model"))
      }

    case .user(let content, _):
      if content.count == 1, case .text(let part) = content[0], promptCacheBreakpoint(part.providerOptions) == nil {
        messages.append(["role": "user", "content": .string(part.text)])
        continue
      }
      let parts = try content.enumerated().map { index, part -> JSONValue in
        switch part {
        case .text(let text):
          withBreakpoint(["type": "text", "text": .string(text.text)], promptCacheBreakpoint(text.providerOptions))
        case .file(let file):
          withBreakpoint(try convertFilePart(file, index: index), promptCacheBreakpoint(file.providerOptions))
        }
      }
      messages.append(["role": "user", "content": .array(parts)])

    case .assistant(let content, _):
      var text = ""
      var textParts: [JSONValue] = []
      var hasBreakpoint = false
      var toolCalls: [JSONValue] = []
      for part in content {
        switch part {
        case .text(let textPart):
          let breakpoint = promptCacheBreakpoint(textPart.providerOptions)
          text += textPart.text
          textParts.append(withBreakpoint(["type": "text", "text": .string(textPart.text)], breakpoint))
          hasBreakpoint = hasBreakpoint || breakpoint != nil
        case .toolCall(let call):
          toolCalls.append([
            "id": .string(call.toolCallId),
            "type": "function",
            "function": ["name": .string(call.toolName), "arguments": .string(serializeToolCallArguments(call.input))],
          ])
        case .file, .custom, .reasoning, .reasoningFile, .toolResult:
          break
        }
      }
      let contentValue: JSONValue =
        hasBreakpoint ? .array(textParts) : toolCalls.isEmpty ? .string(text) : (text.isEmpty ? .null : .string(text))
      messages.append(
        jsonObject([
          "role": "assistant", "content": contentValue, "tool_calls": toolCalls.isEmpty ? nil : .array(toolCalls),
        ]))

    case .tool(let content, _):
      for case .toolResult(let result) in content {
        let outputBreakpoint: JSONValue? =
          switch result.output {
          case .content(let parts):
            parts.lazy.compactMap { part -> JSONValue? in
              switch part {
              case .text(_, let options), .custom(let options): promptCacheBreakpoint(options)
              case .file(_, _, _, let options): promptCacheBreakpoint(options)
              }
            }.first
          case .text(_, let options), .json(_, let options), .executionDenied(_, let options),
            .errorText(_, let options), .errorJSON(_, let options):
            promptCacheBreakpoint(options)
          }
        let breakpoint = outputBreakpoint ?? promptCacheBreakpoint(result.providerOptions)

        let contentValue: String
        switch result.output {
        case .text(let value, _), .errorText(let value, _):
          contentValue = value
        case .executionDenied(let reason, _):
          contentValue = reason ?? "Tool call execution denied."
        case .json(let value, _), .errorJSON(let value, _):
          contentValue = value.jsonString()
        case .content(let parts):
          contentValue = JSONValue.array(parts.map(toolResultContentJSON)).jsonString()
        }
        messages.append([
          "role": "tool", "tool_call_id": .string(result.toolCallId),
          "content": textContent(contentValue, breakpoint: breakpoint),
        ])
      }
    }
  }
  return (messages, warnings)
}

private func toolResultContentJSON(_ part: LanguageModelV4ToolResultOutput.ContentPart) -> JSONValue {
  switch part {
  case .text(let text, _):
    ["type": "text", "text": .string(text)]
  case .file(let data, let mediaType, let filename, _):
    jsonObject([
      "type": "file", "mediaType": .string(mediaType), "filename": .optional(filename),
      "data": .optional(data.base64String),
    ])
  case .custom:
    ["type": "custom"]
  }
}

/// Converts function tools for the chat API. Mirrors upstream `prepareChatTools`.
func prepareOpenAIChatTools(
  tools: [LanguageModelV4Tool]?, toolChoice: LanguageModelV4ToolChoice?
) throws -> (tools: JSONValue?, toolChoice: JSONValue?, warnings: [SharedV4Warning]) {
  guard let tools, !tools.isEmpty else { return (nil, nil, []) }
  var warnings: [SharedV4Warning] = []
  var openaiTools: [JSONValue] = []
  for tool in tools {
    switch tool {
    case .function(let function):
      let normalized = try normalizeOpenAIJsonSchema(function.inputSchema)
      warnings += normalized.warnings
      openaiTools.append([
        "type": "function",
        "function": jsonObject([
          "name": .string(function.name),
          "description": .optional(function.description),
          "parameters": normalized.schema.value,
          "strict": .optional(function.strict),
        ]),
      ])
    case .provider:
      warnings.append(.unsupported(feature: "tool type: provider"))
    }
  }

  let choice: JSONValue? =
    switch toolChoice {
    case nil: nil
    case .some(.auto): "auto"
    case .some(.none): "none"
    case .some(.required): "required"
    case .some(.tool(let name)): ["type": "function", "function": ["name": .string(name)]]
    }
  return (.array(openaiTools), choice, warnings)
}
