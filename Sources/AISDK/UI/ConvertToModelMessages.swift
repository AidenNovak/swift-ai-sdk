import Foundation

/// The model content a data UI part converts to.
public enum DataUIPartConversion: Sendable {
  case text(TextPart)
  case file(FilePart)
}

/// Converts UI messages (e.g. from `useChat` or `Chat`) to model messages for
/// `generateText` / `streamText`. Mirrors upstream `convertToModelMessages`.
///
/// - Parameters:
///   - tools: Tools whose `toModelOutput` converts tool outputs.
///   - ignoreIncompleteToolCalls: Drops tool invocations without a final result.
///   - convertDataPart: Converts data parts; data parts are dropped otherwise.
public func convertToModelMessages(
  _ messages: [UIMessage],
  tools: ToolSet? = nil,
  ignoreIncompleteToolCalls: Bool = false,
  convertDataPart: (@Sendable (DataUIPart) -> DataUIPartConversion?)? = nil
) async throws -> [ModelMessage] {
  var messages = messages
  if ignoreIncompleteToolCalls {
    messages = messages.map { message in
      var message = message
      message.parts = message.parts.filter { part in
        guard let tool = part.toolPart else { return true }
        return tool.state == .approvalResponded || (tool.state == .outputAvailable && tool.preliminary != true)
          || tool.state == .outputError || tool.state == .outputDenied
      }
      return message
    }
  }

  var modelMessages: [ModelMessage] = []
  for message in messages {
    switch message.role {
    case .system:
      var text = ""
      var providerOptions: ProviderOptions = [:]
      for case .text(let part) in message.parts {
        text += part.text
        providerOptions.merge(part.providerMetadata ?? [:]) { _, new in new }
      }
      modelMessages.append(
        .system(SystemModelMessage(content: text, providerOptions: providerOptions.isEmpty ? nil : providerOptions)))

    case .user:
      var content: [UserContentPart] = []
      for part in message.parts {
        switch part {
        case .text(let text):
          content.append(.text(TextPart(text: text.text, providerOptions: text.providerMetadata)))
        case .file(let file):
          content.append(.file(try filePart(file, message: message)))
        case .data(let data):
          switch convertDataPart?(data) {
          case .text(let text): content.append(.text(text))
          case .file(let file): content.append(.file(file))
          case nil: break
          }
        default:
          break
        }
      }
      modelMessages.append(.user(UserModelMessage(content: content)))

    case .assistant:
      var block: [UIMessagePart] = []
      for part in message.parts {
        if case .stepStart = part {
          modelMessages += try await convertAssistantBlock(block, message: message, tools: tools, convertDataPart: convertDataPart)
          block = []
        } else if isAssistantBlockPart(part) {
          block.append(part)
        }
      }
      modelMessages += try await convertAssistantBlock(block, message: message, tools: tools, convertDataPart: convertDataPart)
    }
  }
  return modelMessages
}

private func isAssistantBlockPart(_ part: UIMessagePart) -> Bool {
  switch part {
  case .custom, .text, .reasoning, .reasoningFile, .file, .tool, .data: true
  case .sourceURL, .sourceDocument, .stepStart: false
  }
}

private func fileURL(_ string: String, message: UIMessage) throws -> URL {
  guard let url = URL(string: string), url.scheme != nil else {
    throw MessageConversionError(originalMessage: message, message: "Invalid URL: \(string)")
  }
  return url
}

private func filePart(_ file: FileUIPart, message: UIMessage) throws -> FilePart {
  let data: SharedV4FileData =
    if let reference = file.providerReference { .reference(reference) } else {
      .url(try fileURL(file.url, message: message))
    }
  return FilePart(data: data, mediaType: file.mediaType, filename: file.filename, providerOptions: file.providerMetadata)
}

/// Converts the parts of one step to an assistant message and, for tool
/// results and approvals, a tool message.
private func convertAssistantBlock(
  _ block: [UIMessagePart],
  message: UIMessage,
  tools: ToolSet?,
  convertDataPart: (@Sendable (DataUIPart) -> DataUIPartConversion?)?
) async throws -> [ModelMessage] {
  guard !block.isEmpty else { return [] }
  var result: [ModelMessage] = []
  var content: [AssistantContentPart] = []

  for part in block {
    switch part {
    case .text(let text):
      content.append(.text(TextPart(text: text.text, providerOptions: text.providerMetadata)))
    case .custom(let custom):
      content.append(.custom(CustomPart(kind: custom.kind, providerOptions: custom.providerMetadata)))
    case .file(let file):
      content.append(.file(try filePart(file, message: message)))
    case .reasoningFile(let file):
      content.append(
        .reasoningFile(
          ReasoningFilePart(
            data: .url(try fileURL(file.url, message: message)), mediaType: file.mediaType,
            providerOptions: file.providerMetadata)))
    case .reasoning(let reasoning):
      content.append(.reasoning(ReasoningPart(text: reasoning.text, providerOptions: reasoning.providerMetadata)))
    case .tool(let tool):
      guard tool.state != .inputStreaming else { continue }
      let callMetadata = tool.callProviderMetadata ?? (tool.state == .outputError ? tool.resultProviderMetadata : nil)
      content.append(
        .toolCall(
          ToolCallPart(
            toolCallId: tool.toolCallId, toolName: tool.toolName,
            input: (tool.state == .outputError ? (tool.input ?? tool.rawInput) : tool.input) ?? .null,
            providerExecuted: tool.providerExecuted, providerOptions: callMetadata)))

      if let approval = tool.approval {
        content.append(
          .toolApprovalRequest(
            ToolApprovalRequest(
              approvalId: approval.id, toolCallId: tool.toolCallId, reason: approval.requestReason,
              isAutomatic: approval.isAutomatic, signature: approval.signature)))
      }

      if tool.providerExecuted == true && (tool.state == .outputAvailable || tool.state == .outputError) {
        let isError = tool.state == .outputError
        content.append(
          .toolResult(
            ToolResultPart(
              toolCallId: tool.toolCallId, toolName: tool.toolName,
              output: try await createToolModelOutput(
                toolCallId: tool.toolCallId, input: tool.input ?? .null,
                output: isError ? .string(tool.errorText ?? "") : (tool.output ?? .null), tool: tools?[tool.toolName],
                errorMode: isError ? .json : .none),
              providerOptions: tool.resultProviderMetadata ?? tool.callProviderMetadata)))
      }
    case .data(let data):
      switch convertDataPart?(data) {
      case .text(let text): content.append(.text(text))
      case .file(let file): content.append(.file(file))
      case nil: break
      }
    case .sourceURL, .sourceDocument, .stepStart:
      break
    }
  }

  if !content.isEmpty {
    result.append(.assistant(AssistantModelMessage(content: content)))
  }

  let toolParts = block.compactMap(\.toolPart).filter { $0.providerExecuted != true || $0.approval?.approved != nil }
  var toolContent: [ToolContentPart] = []
  for tool in toolParts {
    if let approval = tool.approval, let approved = approval.approved {
      toolContent.append(
        .toolApprovalResponse(
          ToolApprovalResponse(
            approvalId: approval.id, approved: approved, reason: approval.reason,
            providerExecuted: tool.providerExecuted)))
    }

    if tool.state == .approvalResponded && tool.approval?.approved == false {
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: tool.toolCallId, toolName: tool.toolName,
            output: .executionDenied(reason: tool.approval?.reason), providerOptions: tool.callProviderMetadata)))
    }

    if tool.providerExecuted == true { continue }

    switch tool.state {
    case .outputDenied:
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: tool.toolCallId, toolName: tool.toolName,
            output: .errorText(tool.approval?.reason ?? "Tool call execution denied."),
            providerOptions: tool.callProviderMetadata)))
    case .outputError, .outputAvailable:
      let isError = tool.state == .outputError
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: tool.toolCallId, toolName: tool.toolName,
            output: try await createToolModelOutput(
              toolCallId: tool.toolCallId, input: tool.input ?? .null,
              output: isError ? .string(tool.errorText ?? "") : (tool.output ?? .null), tool: tools?[tool.toolName],
              errorMode: isError ? .text : .none),
            providerOptions: tool.callProviderMetadata)))
    case .inputStreaming, .inputAvailable, .approvalRequested, .approvalResponded:
      break
    }
  }

  if !toolContent.isEmpty {
    result.append(.tool(ToolModelMessage(content: toolContent)))
  }
  return result
}
