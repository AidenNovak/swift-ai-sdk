import AISDKProviderUtils
import Foundation

/// Extra fields from `providerOptions["openaiCompatible"]`, merged into the
/// message or part verbatim. Mirrors upstream `getOpenAIMetadata`.
private func openAICompatibleMetadata(_ providerOptions: SharedV4ProviderOptions?) -> [String: JSONValue] {
  providerOptions?["openaiCompatible"] ?? [:]
}

private func withMetadata(_ value: JSONValue, _ providerOptions: SharedV4ProviderOptions?) -> JSONValue {
  guard case .object(var object) = value else { return value }
  object.merge(openAICompatibleMetadata(providerOptions)) { _, new in new }
  return .object(object)
}

private func audioFormat(_ mediaType: String) -> String? {
  switch mediaType {
  case "audio/wav": "wav"
  case "audio/mp3", "audio/mpeg": "mp3"
  default: nil
  }
}

private func convertUserFilePart(_ part: LanguageModelV4FilePart) throws -> JSONValue {
  switch part.data {
  case .reference:
    throw UnsupportedFunctionalityError(functionality: "file parts with provider references")
  case .text:
    throw UnsupportedFunctionalityError(functionality: "text file parts")
  case .url, .data, .base64:
    break
  }

  func dataURL() throws -> String {
    if case .url(let url, _) = part.data { return url.absoluteString }
    return "data:\(try resolveFullMediaType(part));base64,\(part.data.base64String ?? "")"
  }

  switch getTopLevelMediaType(part.mediaType) {
  case "image":
    return ["type": "image_url", "image_url": ["url": .string(try dataURL())]]
  case "video":
    return ["type": "video_url", "video_url": ["url": .string(try dataURL())]]
  case "audio":
    if case .url = part.data {
      throw UnsupportedFunctionalityError(functionality: "audio file parts with URLs")
    }
    let mediaType = try resolveFullMediaType(part)
    guard let format = audioFormat(mediaType) else {
      throw UnsupportedFunctionalityError(functionality: "audio media type \(mediaType)")
    }
    return ["type": "input_audio", "input_audio": ["data": .string(part.data.base64String ?? ""), "format": .string(format)]]
  case "application":
    if case .url = part.data {
      throw UnsupportedFunctionalityError(functionality: "PDF file parts with URLs")
    }
    let mediaType = try resolveFullMediaType(part)
    guard mediaType == "application/pdf" else {
      throw UnsupportedFunctionalityError(functionality: "file part media type \(mediaType)")
    }
    return [
      "type": "file",
      "file": [
        "filename": .string(part.filename ?? "document.pdf"),
        "file_data": .string("data:application/pdf;base64,\(part.data.base64String ?? "")"),
      ],
    ]
  case "text":
    let text: String
    if case .url(let url, _) = part.data {
      text = url.absoluteString
    } else {
      text = part.data.base64String.flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    return ["type": "text", "text": .string(text)]
  default:
    throw UnsupportedFunctionalityError(functionality: "file part media type \(part.mediaType)")
  }
}

/// Converts a prompt to OpenAI chat messages. Mirrors upstream
/// `convertToOpenAICompatibleChatMessages`.
///
/// - Parameter providerOptionsKey: where tool calls look up a Gemini `thoughtSignature`.
func convertToOpenAICompatibleChatMessages(
  _ prompt: LanguageModelV4Prompt, providerOptionsKey: String = "google"
) throws -> [JSONValue] {
  var messages: [JSONValue] = []
  for message in prompt {
    switch message {
    case .system(let content, let options):
      messages.append(withMetadata(["role": "system", "content": .string(content)], options))

    case .user(let content, let options):
      if content.count == 1, case .text(let part) = content[0] {
        messages.append(withMetadata(["role": "user", "content": .string(part.text)], part.providerOptions))
        continue
      }
      let parts = try content.map { part -> JSONValue in
        switch part {
        case .text(let text):
          withMetadata(["type": "text", "text": .string(text.text)], text.providerOptions)
        case .file(let file):
          withMetadata(try convertUserFilePart(file), file.providerOptions)
        }
      }
      messages.append(withMetadata(["role": "user", "content": .array(parts)], options))

    case .assistant(let content, let options):
      var text = ""
      var reasoning = ""
      var toolCalls: [JSONValue] = []
      for part in content {
        switch part {
        case .text(let textPart):
          text += textPart.text
        case .reasoning(let reasoningPart):
          reasoning += reasoningPart.text
        case .toolCall(let call):
          let thoughtSignature =
            call.providerOptions?[providerOptionsKey]?["thoughtSignature"]
            ?? call.providerOptions?["google"]?["thoughtSignature"]
          var toolCall = withMetadata(
            [
              "id": .string(call.toolCallId),
              "type": "function",
              "function": ["name": .string(call.toolName), "arguments": .string(call.input.jsonString())],
            ], call.providerOptions
          ).objectValue ?? [:]
          if let thoughtSignature {
            let signature = thoughtSignature.stringValue ?? thoughtSignature.jsonString()
            toolCall["extra_content"] = ["google": ["thought_signature": .string(signature)]]
          }
          toolCalls.append(.object(toolCall))
        case .file, .custom, .reasoningFile, .toolResult:
          break
        }
      }
      messages.append(
        withMetadata(
          jsonObject([
            "role": "assistant",
            "content": toolCalls.isEmpty ? .string(text) : (text.isEmpty ? .null : .string(text)),
            "reasoning_content": reasoning.isEmpty ? nil : .string(reasoning),
            "tool_calls": toolCalls.isEmpty ? nil : .array(toolCalls),
          ]), options))

    case .tool(let content, _):
      for case .toolResult(let result) in content {
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
        messages.append(
          withMetadata(
            ["role": "tool", "tool_call_id": .string(result.toolCallId), "content": .string(contentValue)],
            result.providerOptions))
      }
    }
  }
  return messages
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

/// Converts tools and tool choice to the OpenAI chat format. Mirrors upstream `prepareTools`.
func prepareOpenAICompatibleTools(
  tools: [LanguageModelV4Tool]?, toolChoice: LanguageModelV4ToolChoice?
) -> (tools: JSONValue?, toolChoice: JSONValue?, warnings: [SharedV4Warning]) {
  guard let tools, !tools.isEmpty else { return (nil, nil, []) }
  var warnings: [SharedV4Warning] = []
  var functionTools: [JSONValue] = []
  for tool in tools {
    switch tool {
    case .provider(let providerTool):
      warnings.append(.unsupported(feature: "provider-defined tool \(providerTool.id)"))
    case .function(let function):
      functionTools.append([
        "type": "function",
        "function": jsonObject([
          "name": .string(function.name),
          "description": .optional(function.description),
          "parameters": function.inputSchema.value,
          "strict": .optional(function.strict),
        ]),
      ])
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
  return (.array(functionTools), choice, warnings)
}
