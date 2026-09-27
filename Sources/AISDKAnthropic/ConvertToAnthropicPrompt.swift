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

/// Converts a prompt to the Anthropic Messages format. Mirrors the core of
/// upstream `convertToAnthropicPrompt`.
func convertToAnthropicPrompt(
  prompt: LanguageModelV4Prompt,
  sendReasoning: Bool,
  warnings: inout [SharedV4Warning],
  validator: CacheControlValidator
) throws -> (prompt: AnthropicPrompt, betas: Set<String>) {
  var betas = Set<String>()
  var system: [JSONValue]?
  var messages: [JSONValue] = []
  let blocks = groupIntoBlocks(prompt)

  for (blockIndex, block) in blocks.enumerated() {
    let isLastBlock = blockIndex == blocks.count - 1
    switch block {
    case .system(let systemMessages):
      let content = systemMessages.compactMap { message -> JSONValue? in
        guard case .system(let text, let options) = message else { return nil }
        return jsonObject([
          "type": "text", "text": .string(text),
          "cache_control": validator.cacheControl(options, type: "system message"),
        ])
      }
      if system == nil {
        system = content
      } else {
        betas.insert("mid-conversation-system-2026-04-07")
        messages.append(["role": "system", "content": .array(content)])
      }

    case .user(let userMessages):
      var content: [JSONValue] = []
      for message in userMessages {
        switch message {
        case .user(let parts, let messageOptions):
          for (index, part) in parts.enumerated() {
            let isLastPart = index == parts.count - 1
            switch part {
            case .text(let textPart):
              let cacheControl =
                validator.cacheControl(textPart.providerOptions, type: "user message part")
                ?? (isLastPart ? validator.cacheControl(messageOptions, type: "user message") : nil)
              content.append(jsonObject(["type": "text", "text": .string(textPart.text), "cache_control": cacheControl]))
            case .file(let file):
              let cacheControl =
                validator.cacheControl(file.providerOptions, type: "user message part")
                ?? (isLastPart ? validator.cacheControl(messageOptions, type: "user message") : nil)
              content.append(try convertFilePart(file, cacheControl: cacheControl, betas: &betas))
            }
          }
        case .tool(let parts, let messageOptions):
          for (index, part) in parts.enumerated() {
            guard case .toolResult(let result) = part else { continue }
            let isLastPart = index == parts.count - 1
            let cacheControl =
              validator.cacheControl(result.providerOptions, type: "tool result part")
              ?? (isLastPart ? validator.cacheControl(messageOptions, type: "tool result message") : nil)
            let (value, isError) = convertToolResultOutput(result.output, warnings: &warnings, betas: &betas)
            content.append(
              jsonObject([
                "type": "tool_result", "tool_use_id": .string(result.toolCallId), "content": value,
                "is_error": isError ? true : nil, "cache_control": cacheControl,
              ]))
          }
        default:
          break
        }
      }
      messages.append(["role": "user", "content": .array(content)])

    case .assistant(let assistantMessages):
      var content: [JSONValue] = []
      for (messageIndex, message) in assistantMessages.enumerated() {
        guard case .assistant(let parts, let messageOptions) = message else { continue }
        let isLastMessage = messageIndex == assistantMessages.count - 1
        for (partIndex, part) in parts.enumerated() {
          let isLastPart = partIndex == parts.count - 1
          func cacheControl(_ options: SharedV4ProviderOptions?) -> JSONValue? {
            validator.cacheControl(options, type: "assistant message part")
              ?? (isLastPart ? validator.cacheControl(messageOptions, type: "assistant message") : nil)
          }
          switch part {
          case .text(let textPart):
            let trim = isLastBlock && isLastMessage && isLastPart
            content.append(
              jsonObject([
                "type": "text",
                "text": .string(trim ? textPart.text.trimmingCharacters(in: .whitespacesAndNewlines) : textPart.text),
                "citations": textPart.providerOptions?["anthropic"]?["citations"],
                "cache_control": cacheControl(textPart.providerOptions),
              ]))
          case .reasoning(let reasoning):
            guard sendReasoning else {
              warnings.append(.other(message: "sending reasoning content is disabled for this model"))
              continue
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
            if call.providerExecuted == true {
              warnings.append(.other(message: "provider executed tool call for tool \(call.toolName) is not supported"))
              continue
            }
            content.append(
              jsonObject([
                "type": "tool_use", "id": .string(call.toolCallId), "name": .string(call.toolName),
                "input": call.input, "cache_control": cacheControl(call.providerOptions),
              ]))
          case .file(let file):
            content.append(try convertFilePart(file, cacheControl: cacheControl(file.providerOptions), betas: &betas))
          case .toolResult, .reasoningFile, .custom:
            continue
          }
        }
      }
      messages.append(["role": "assistant", "content": .array(content)])
    }
  }

  return (AnthropicPrompt(system: system, messages: messages), betas)
}

private func convertFilePart(_ part: LanguageModelV4FilePart, cacheControl: JSONValue?, betas: inout Set<String>)
  throws -> JSONValue
{
  let options = try parseProviderOptions(
    provider: "anthropic", providerOptions: part.providerOptions, as: AnthropicFilePartOptions.self)
  let citations: JSONValue? = options?.citations?.enabled == true ? ["enabled": true] : nil
  let topLevel = getTopLevelMediaType(part.mediaType)

  switch part.data {
  case .reference(let reference):
    betas.insert("files-api-2025-04-14")
    let fileId = try resolveProviderReference(reference, provider: "anthropic")
    return jsonObject([
      "type": topLevel == "image" ? "image" : "document",
      "source": ["type": "file", "file_id": .string(fileId)],
      "cache_control": cacheControl,
    ])
  case .text(let text):
    return jsonObject([
      "type": "document",
      "source": ["type": "text", "media_type": "text/plain", "data": .string(text)],
      "title": .optional(options?.title ?? part.filename), "context": .optional(options?.context),
      "citations": citations, "cache_control": cacheControl,
    ])
  case .url(let url, _):
    if topLevel == "image" {
      return jsonObject([
        "type": "image", "source": ["type": "url", "url": .string(url.absoluteString)], "cache_control": cacheControl,
      ])
    }
    if part.mediaType == "application/pdf" {
      betas.insert("pdfs-2024-09-25")
    } else if part.mediaType != "text/plain" {
      throw UnsupportedFunctionalityError(functionality: "media type: \(part.mediaType)")
    }
    return jsonObject([
      "type": "document", "source": ["type": "url", "url": .string(url.absoluteString)],
      "title": .optional(options?.title ?? part.filename), "context": .optional(options?.context),
      "citations": citations, "cache_control": cacheControl,
    ])
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
    let mediaType = topLevel == "application" ? try resolveFullMediaType(part) : part.mediaType
    if mediaType == "application/pdf" {
      betas.insert("pdfs-2024-09-25")
      return jsonObject([
        "type": "document",
        "source": ["type": "base64", "media_type": "application/pdf", "data": .string(part.data.base64String ?? "")],
        "title": .optional(options?.title ?? part.filename), "context": .optional(options?.context),
        "citations": citations, "cache_control": cacheControl,
      ])
    }
    if mediaType == "text/plain" {
      return jsonObject([
        "type": "document",
        "source": ["type": "text", "media_type": "text/plain", "data": .string(textFromBytes(part.data))],
        "title": .optional(options?.title ?? part.filename), "context": .optional(options?.context),
        "citations": citations, "cache_control": cacheControl,
      ])
    }
    throw UnsupportedFunctionalityError(functionality: "media type: \(part.mediaType)")
  }
}

private func convertToolResultOutput(
  _ output: LanguageModelV4ToolResultOutput, warnings: inout [SharedV4Warning], betas: inout Set<String>
) -> (JSONValue, Bool) {
  switch output {
  case .text(let value, _): return (.string(value), false)
  case .errorText(let value, _): return (.string(value), true)
  case .executionDenied(let reason, _): return (.string(reason ?? "Tool call execution denied."), false)
  case .json(let value, _): return (.string(value.jsonString()), false)
  case .errorJSON(let value, _): return (.string(value.jsonString()), true)
  case .content(let parts):
    var values: [JSONValue] = []
    for part in parts {
      switch part {
      case .text(let text, _):
        values.append(["type": "text", "text": .string(text)])
      case .file(let data, let mediaType, _, _):
        let topLevel = getTopLevelMediaType(mediaType)
        switch data {
        case .url(let url, _):
          values.append([
            "type": topLevel == "image" ? "image" : "document",
            "source": ["type": "url", "url": .string(url.absoluteString)],
          ])
        case .data, .base64:
          let filePart = LanguageModelV4FilePart(data: data, mediaType: mediaType)
          let fullType = (try? resolveFullMediaType(filePart)) ?? mediaType
          if topLevel == "image" {
            values.append([
              "type": "image",
              "source": ["type": "base64", "media_type": .string(fullType), "data": .string(data.base64String ?? "")],
            ])
          } else if fullType == "application/pdf" {
            betas.insert("pdfs-2024-09-25")
            values.append([
              "type": "document",
              "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64String ?? "")],
            ])
          } else {
            warnings.append(.other(message: "unsupported tool content part type: file with media type: \(mediaType)"))
          }
        case .reference, .text:
          warnings.append(.other(message: "unsupported tool content part type: file"))
        }
      case .custom:
        warnings.append(.other(message: "unsupported custom tool content part"))
      }
    }
    return (.array(values), false)
  }
}
