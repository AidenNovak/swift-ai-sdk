import AISDKProviderUtils
import Foundation

private let supportedImageMediaTypes: Set<String> = [
  "image/gif", "image/jpeg", "image/jpg", "image/png", "image/webp",
]

private func resolveDeepSeekImageMediaType(_ part: LanguageModelV4FilePart) throws -> String {
  let mediaType = try resolveFullMediaType(part)
  guard supportedImageMediaTypes.contains(mediaType) else {
    throw UnsupportedFunctionalityError(
      functionality: "DeepSeek image media type \(mediaType)",
      message: "DeepSeek supports JPEG, PNG, GIF, and WebP image inputs.")
  }
  return mediaType
}

private func validateImageURL(_ url: String) throws {
  if url.count > 8192 {
    throw InvalidPromptError(prompt: url, message: "DeepSeek image URLs must not exceed 8192 characters.")
  }
}

private func dataURL(mediaType: String, data: SharedV4FileData) -> String {
  let normalized = mediaType == "image/jpg" ? "image/jpeg" : mediaType
  return "data:\(normalized);base64,\(data.base64String ?? "")"
}

private func isImagePart(_ part: LanguageModelV4FilePart) -> Bool {
  switch part.data {
  case .reference, .url, .data, .base64:
    getTopLevelMediaType(part.mediaType) == "image"
  case .text:
    false
  }
}

/// Converts a prompt to DeepSeek chat messages. Mirrors upstream `convertToDeepSeekChatMessages`.
///
/// Reasoning from earlier turns is only sent back for V4 models, which also
/// require `reasoning_content` on every assistant message.
func convertToDeepSeekChatMessages(
  prompt: LanguageModelV4Prompt,
  responseFormat: LanguageModelV4ResponseFormat?,
  modelId: String,
  providerOptionsName: String = "deepseek",
  supportsAssistantPrefixCompletion: Bool = false,
  supportsStructuredOutputs: Bool = false
) throws -> (messages: [JSONValue], warnings: [SharedV4Warning]) {
  let isV4 = isDeepSeekV4Model(modelId)
  var messages: [JSONValue] = []
  var warnings: [SharedV4Warning] = []

  if case .json(let schema, _, _)? = responseFormat {
    if let schema {
      if !supportsStructuredOutputs {
        messages.append([
          "role": "system",
          "content": .string("Return JSON that conforms to the following schema: \(schema.value.jsonString())"),
        ])
        warnings.append(
          .compatibility(
            feature: "responseFormat JSON schema", details: "JSON response schema is injected into the system message."))
      }
    } else {
      messages.append(["role": "system", "content": "Return JSON."])
    }
  }

  let lastUserMessageIndex = prompt.lastIndex { $0.role == .user } ?? -1

  for (index, message) in prompt.enumerated() {
    let options = try parseProviderOptions(
      provider: providerOptionsName, providerOptions: message.providerOptions, as: DeepSeekMessageOptions.self)
    if options?.prefix == true && message.role != .assistant {
      throw InvalidPromptError(
        prompt: String(describing: prompt),
        message: "DeepSeek assistant prefix completion requires `prefix: true` on an assistant message.")
    }

    switch message {
    case .system(let content, _):
      messages.append(jsonObject(["role": "system", "content": .string(content), "name": .optional(options?.name)]))

    case .user(let content, _):
      let hasImage = content.contains {
        if case .file(let file) = $0 { return isImagePart(file) }
        return false
      }
      if !hasImage {
        var text = ""
        for part in content {
          switch part {
          case .text(let textPart): text += textPart.text
          case .file: warnings.append(.unsupported(feature: "user message part type: file"))
          }
        }
        messages.append(jsonObject(["role": "user", "content": .string(text), "name": .optional(options?.name)]))
        continue
      }

      var parts: [JSONValue] = []
      for part in content {
        switch part {
        case .text(let textPart):
          parts.append(["type": "text", "text": .string(textPart.text)])
        case .file(let file) where getTopLevelMediaType(file.mediaType) == "image":
          let fileOptions = try parseProviderOptions(
            provider: providerOptionsName, providerOptions: file.providerOptions, as: DeepSeekFilePartOptions.self)
          switch file.data {
          case .reference(let reference):
            parts.append(["type": "file", "file_id": .string(try resolveProviderReference(reference, provider: "deepseek"))])
          case .url(let url, _):
            _ = try resolveDeepSeekImageMediaType(file)
            try validateImageURL(url.absoluteString)
            if fileOptions?.fileData == true {
              throw InvalidPromptError(
                prompt: url.absoluteString, message: "DeepSeek `fileData` image parts require inline data, not a URL.")
            }
            parts.append([
              "type": "image_url",
              "image_url": jsonObject(["url": .string(url.absoluteString), "detail": .optional(fileOptions?.imageDetail)]),
            ])
          case .data, .base64:
            let mediaType = try resolveDeepSeekImageMediaType(file)
            let url = dataURL(mediaType: mediaType, data: file.data)
            if fileOptions?.fileData == true {
              if fileOptions?.imageDetail != nil {
                throw InvalidPromptError(
                  prompt: String(describing: prompt), message: "DeepSeek `imageDetail` cannot be combined with `fileData`.")
              }
              parts.append(jsonObject(["type": "file", "file_data": .string(url), "filename": .optional(file.filename)]))
            } else {
              parts.append([
                "type": "image_url",
                "image_url": jsonObject(["url": .string(url), "detail": .optional(fileOptions?.imageDetail)]),
              ])
            }
          case .text:
            warnings.append(.unsupported(feature: "user message part type: file"))
          }
        case .file:
          warnings.append(.unsupported(feature: "user message part type: file"))
        }
      }
      messages.append(jsonObject(["role": "user", "content": .array(parts), "name": .optional(options?.name)]))

    case .assistant(let content, _):
      if options?.prefix == true {
        if index != prompt.count - 1 {
          throw InvalidPromptError(
            prompt: String(describing: prompt),
            message:
              "DeepSeek assistant prefix completion requires the prefixed assistant message to be the final message.")
        }
        if !supportsAssistantPrefixCompletion {
          throw UnsupportedFunctionalityError(
            functionality: "DeepSeek assistant prefix completion",
            message: "DeepSeek assistant prefix completion requires a beta base URL ending in `/beta`.")
        }
      }

      var text = ""
      var reasoning: String?
      var toolCalls: [JSONValue] = []
      for part in content {
        switch part {
        case .text(let textPart):
          text += textPart.text
        case .reasoning(let reasoningPart):
          if index <= lastUserMessageIndex && !isV4 { continue }
          reasoning = (reasoning ?? "") + reasoningPart.text
        case .toolCall(let call):
          toolCalls.append([
            "id": .string(call.toolCallId),
            "type": "function",
            "function": ["name": .string(call.toolName), "arguments": .string(call.input.jsonString())],
          ])
        default:
          break
        }
      }
      messages.append(
        jsonObject([
          "role": "assistant",
          "content": .string(text),
          "name": .optional(options?.name),
          "prefix": options?.prefix == true ? true : nil,
          "reasoning_content": .optional(reasoning ?? (isV4 ? "" : nil)),
          "tool_calls": toolCalls.isEmpty ? nil : .array(toolCalls),
        ]))

    case .tool(let content, _):
      if options?.name != nil {
        warnings.append(.unsupported(feature: "message name on tool messages"))
      }
      for case .toolResult(let result) in content {
        let contentValue: JSONValue
        switch result.output {
        case .text(let value, _), .errorText(let value, _):
          contentValue = .string(value)
        case .executionDenied(let reason, _):
          contentValue = .string(reason ?? "Tool call execution denied.")
        case .json(let value, _), .errorJSON(let value, _):
          contentValue = .string(value.jsonString())
        case .content(let parts):
          contentValue = try convertToolContent(parts, providerOptionsName: providerOptionsName, warnings: &warnings)
        }
        messages.append(["role": "tool", "tool_call_id": .string(result.toolCallId), "content": contentValue])
      }
    }
  }

  return (messages, warnings)
}

private func convertToolContent(
  _ parts: [LanguageModelV4ToolResultOutput.ContentPart], providerOptionsName: String,
  warnings: inout [SharedV4Warning]
) throws -> JSONValue {
  let hasImage = parts.contains {
    if case .file(let data, let mediaType, _, _) = $0 {
      return isImagePart(LanguageModelV4FilePart(data: data, mediaType: mediaType))
    }
    return false
  }
  guard hasImage else {
    return .string(JSONValue.array(parts.map(toolContentJSON)).jsonString())
  }

  var values: [JSONValue] = []
  for part in parts {
    switch part {
    case .text(let text, _):
      values.append(["type": "text", "text": .string(text)])
    case .file(let data, let mediaType, let filename, let options)
    where isImagePart(LanguageModelV4FilePart(data: data, mediaType: mediaType)):
      if case .reference(let reference) = data {
        values.append(["type": "file", "file_id": .string(try resolveProviderReference(reference, provider: "deepseek"))])
        continue
      }
      let filePart = LanguageModelV4FilePart(data: data, mediaType: mediaType, filename: filename, providerOptions: options)
      let fileOptions = try parseProviderOptions(
        provider: providerOptionsName, providerOptions: options, as: DeepSeekFilePartOptions.self)
      let resolvedMediaType = try resolveDeepSeekImageMediaType(filePart)
      let url: String
      if case .url(let fileURL, _) = data {
        url = fileURL.absoluteString
        try validateImageURL(url)
      } else {
        url = dataURL(mediaType: resolvedMediaType, data: data)
      }
      values.append([
        "type": "image_url",
        "image_url": jsonObject(["url": .string(url), "detail": .optional(fileOptions?.imageDetail)]),
      ])
    case .file:
      warnings.append(.unsupported(feature: "tool result content part type: file"))
    case .custom:
      warnings.append(.unsupported(feature: "tool result content part type: custom"))
    }
  }
  return .array(values)
}

private func toolContentJSON(_ part: LanguageModelV4ToolResultOutput.ContentPart) -> JSONValue {
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

/// Converts tools and tool choice to the DeepSeek format. Mirrors upstream `prepareTools`.
func prepareDeepSeekTools(
  tools: [LanguageModelV4Tool]?, toolChoice: LanguageModelV4ToolChoice?, supportsStrictToolCalls: Bool
) throws -> (tools: JSONValue?, toolChoice: JSONValue?, warnings: [SharedV4Warning]) {
  guard let tools, !tools.isEmpty else { return (nil, nil, []) }
  var warnings: [SharedV4Warning] = []

  let functionTools = tools.compactMap { tool -> LanguageModelV4FunctionTool? in
    if case .function(let function) = tool { return function }
    return nil
  }
  let hasStrictTool = functionTools.contains { $0.strict == true }
  if hasStrictTool && !supportsStrictToolCalls {
    throw UnsupportedFunctionalityError(
      functionality: "DeepSeek strict tool calls",
      message: "DeepSeek strict tool calls require a beta base URL ending in `/beta`.")
  }
  if hasStrictTool && functionTools.contains(where: { $0.strict != true }) {
    throw UnsupportedFunctionalityError(
      functionality: "mixed DeepSeek strict and non-strict tool calls",
      message: "DeepSeek strict mode requires every function tool in the request to set `strict: true`.")
  }

  var deepseekTools: [JSONValue] = []
  for tool in tools {
    switch tool {
    case .provider(let providerTool):
      warnings.append(.unsupported(feature: "provider-defined tool \(providerTool.id)"))
    case .function(let function):
      deepseekTools.append([
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
  return (.array(deepseekTools), choice, warnings)
}
