import Foundation

/// Options passed to a tool call repair function.
public struct ToolCallRepairOptions: Sendable {
  public var toolCall: LanguageModelV4ToolCall
  public var tools: ToolSet
  public var instructions: Instructions?
  public var messages: [ModelMessage]
  /// The `NoSuchToolError` or `InvalidToolInputError` that triggered repair.
  public var error: any Error

  /// The JSON Schema of a tool's input.
  public func inputSchema(toolName: String) -> JSONSchema? {
    tools[toolName]?.inputSchema.jsonSchema
  }
}

/// Repairs a tool call that failed to parse. Return `nil` to give up.
/// Mirrors upstream `ToolCallRepairFunction`.
public typealias ToolCallRepairFunction =
  @Sendable (ToolCallRepairOptions) async throws -> LanguageModelV4ToolCall?

/// Parses and validates a tool call, repairing it if possible. Invalid calls
/// are returned with `invalid == true` rather than thrown. Mirrors upstream `parseToolCall`.
func parseToolCall(
  _ toolCall: LanguageModelV4ToolCall,
  tools: ToolSet?,
  repairToolCall: ToolCallRepairFunction?,
  instructions: Instructions?,
  messages: [ModelMessage]
) async throws -> ToolCall {
  do {
    guard let tools else {
      if toolCall.providerExecuted == true && toolCall.dynamic == true {
        return try parseProviderExecutedDynamicToolCall(toolCall)
      }
      throw NoSuchToolError(toolName: toolCall.toolName)
    }

    do {
      return try doParseToolCall(toolCall, tools: tools)
    } catch let error where error is NoSuchToolError || error is InvalidToolInputError {
      guard let repairToolCall else { throw error }

      let repaired: LanguageModelV4ToolCall?
      do {
        try Task.checkCancellation()
        repaired = try await repairToolCall(
          ToolCallRepairOptions(
            toolCall: toolCall, tools: tools, instructions: instructions, messages: messages, error: error))
      } catch let repairError where !isCancellationError(repairError) {
        throw ToolCallRepairError(cause: repairError, originalError: error)
      }
      guard let repaired else { throw error }
      return try doParseToolCall(repaired, tools: tools)
    }
  } catch let error where !isCancellationError(error) {
    let input = (try? parseJSON(toolCall.input)) ?? .string(toolCall.input)
    let tool = tools?[toolCall.toolName]
    return ToolCall(
      toolCallId: toolCall.toolCallId,
      toolName: toolCall.toolName,
      input: input,
      providerExecuted: toolCall.providerExecuted,
      dynamic: true,
      invalid: true,
      error: error,
      title: tool?.title,
      providerMetadata: toolCall.providerMetadata,
      toolMetadata: tool?.metadata)
  }
}

private func parseProviderExecutedDynamicToolCall(_ toolCall: LanguageModelV4ToolCall) throws -> ToolCall {
  let input: JSONValue
  if toolCall.input.trimmingCharacters(in: .whitespaces).isEmpty {
    input = [:]
  } else {
    do {
      input = try parseJSON(toolCall.input)
    } catch {
      throw InvalidToolInputError(toolName: toolCall.toolName, toolInput: toolCall.input, cause: error)
    }
  }
  return ToolCall(
    toolCallId: toolCall.toolCallId, toolName: toolCall.toolName, input: input, providerExecuted: true,
    dynamic: true, providerMetadata: toolCall.providerMetadata)
}

private func doParseToolCall(_ toolCall: LanguageModelV4ToolCall, tools: ToolSet) throws -> ToolCall {
  guard let tool = tools[toolCall.toolName] else {
    if toolCall.providerExecuted == true && toolCall.dynamic == true {
      return try parseProviderExecutedDynamicToolCall(toolCall)
    }
    throw NoSuchToolError(toolName: toolCall.toolName, availableTools: tools.names)
  }

  let result: ParseResult<JSONValue> =
    toolCall.input.trimmingCharacters(in: .whitespaces).isEmpty
    ? safeValidateTypes(value: [:], schema: tool.inputSchema)
    : safeParseJSON(toolCall.input, schema: tool.inputSchema)

  guard case .success(let input, _) = result else {
    throw InvalidToolInputError(toolName: toolCall.toolName, toolInput: toolCall.input, cause: result.error)
  }

  return ToolCall(
    toolCallId: toolCall.toolCallId,
    toolName: toolCall.toolName,
    input: input,
    providerExecuted: toolCall.providerExecuted,
    dynamic: tool.isDynamic,
    title: tool.title,
    providerMetadata: toolCall.providerMetadata,
    toolMetadata: tool.metadata)
}

/// Executes a tool call. Returns `nil` when the tool is not executable.
/// Mirrors upstream `executeToolCall`.
func executeToolCall(
  _ toolCall: ToolCall,
  tools: ToolSet?,
  messages: [ModelMessage],
  toolsContext: [String: JSONValue]?,
  onPreliminaryToolResult: (@Sendable (ToolResult) -> Void)? = nil
) async throws -> ToolOutput? {
  guard let tool = tools?[toolCall.toolName], tool.isExecutable else { return nil }

  let options = ToolExecutionOptions(
    toolCallId: toolCall.toolCallId, messages: messages, context: toolsContext?[toolCall.toolName])

  do {
    let output: JSONValue
    if let executeStreaming = tool.executeStreaming {
      var last: JSONValue?
      for try await value in executeStreaming(toolCall.input, options) {
        if let previous = last {
          onPreliminaryToolResult?(
            ToolResult(
              toolCallId: toolCall.toolCallId, toolName: toolCall.toolName, input: toolCall.input, output: previous,
              dynamic: tool.isDynamic, preliminary: true))
        }
        last = value
      }
      output = last ?? .null
    } else {
      output = try await tool.execute!(toolCall.input, options)
    }
    return .result(
      ToolResult(
        toolCallId: toolCall.toolCallId, toolName: toolCall.toolName, input: toolCall.input, output: output,
        dynamic: tool.isDynamic, providerMetadata: toolCall.providerMetadata, toolMetadata: toolCall.toolMetadata))
  } catch let error where isCancellationError(error) {
    throw error
  } catch {
    return .error(
      ToolError(
        toolCallId: toolCall.toolCallId, toolName: toolCall.toolName, input: toolCall.input, error: error,
        dynamic: tool.isDynamic, providerMetadata: toolCall.providerMetadata, toolMetadata: toolCall.toolMetadata))
  }
}

/// Executes tool calls concurrently, preserving order.
func executeTools(
  _ toolCalls: [ToolCall],
  tools: ToolSet?,
  messages: [ModelMessage],
  toolsContext: [String: JSONValue]?,
  onPreliminaryToolResult: (@Sendable (ToolResult) -> Void)? = nil
) async throws -> [ToolOutput] {
  try await withThrowingTaskGroup(of: (Int, ToolOutput?).self) { group in
    for (index, call) in toolCalls.enumerated() {
      group.addTask {
        (
          index,
          try await executeToolCall(
            call, tools: tools, messages: messages, toolsContext: toolsContext,
            onPreliminaryToolResult: onPreliminaryToolResult)
        )
      }
    }
    var outputs = [ToolOutput?](repeating: nil, count: toolCalls.count)
    for try await (index, output) in group {
      outputs[index] = output
    }
    return outputs.compactMap { $0 }
  }
}

/// Creates the tool output sent to the model. Mirrors upstream `createToolModelOutput`.
func createToolModelOutput(
  toolCallId: String, input: JSONValue, output: JSONValue, tool: Tool?, errorMode: ToolOutputErrorMode
) async throws -> ToolResultOutput {
  switch errorMode {
  case .text:
    return .errorText(output.stringValue ?? output.jsonString())
  case .json:
    return .errorJSON(output)
  case .none:
    if let toModelOutput = tool?.toModelOutput {
      return try await toModelOutput(ToolModelOutputOptions(toolCallId: toolCallId, input: input, output: output))
    }
    if let text = output.stringValue {
      return .text(text)
    }
    return .json(output)
  }
}

enum ToolOutputErrorMode {
  case none, text, json
}

/// Converts step content to response messages. Mirrors upstream `toResponseMessages`.
func toResponseMessages(content: [ContentPart], tools: ToolSet?) async throws -> [ModelMessage] {
  var assistantContent: [AssistantContentPart] = []
  var toolCallOrder: [String: Int] = [:]

  for part in content {
    switch part {
    case .source:
      continue
    case .text(let text, let metadata):
      if !text.isEmpty {
        assistantContent.append(.text(TextPart(text: text, providerOptions: metadata)))
      }
    case .custom(let kind, let metadata):
      assistantContent.append(.custom(CustomPart(kind: kind, providerOptions: metadata)))
    case .reasoning(let reasoning):
      assistantContent.append(.reasoning(ReasoningPart(text: reasoning.text, providerOptions: reasoning.providerMetadata)))
    case .file(let file, let metadata):
      assistantContent.append(
        .file(FilePart(data: .base64(file.base64), mediaType: file.mediaType, providerOptions: metadata)))
    case .reasoningFile(let file, let metadata):
      assistantContent.append(
        .reasoningFile(ReasoningFilePart(data: .base64(file.base64), mediaType: file.mediaType, providerOptions: metadata)))
    case .toolCall(let call):
      if toolCallOrder[call.toolCallId] == nil {
        toolCallOrder[call.toolCallId] = toolCallOrder.count
      }
      let input: JSONValue = call.invalid && call.input.objectValue == nil ? [:] : call.input
      assistantContent.append(
        .toolCall(
          ToolCallPart(
            toolCallId: call.toolCallId, toolName: call.toolName, input: input,
            providerExecuted: call.providerExecuted, providerOptions: call.providerMetadata)))
    case .toolResult(let result):
      guard result.providerExecuted == true else { continue }
      let output = try await createToolModelOutput(
        toolCallId: result.toolCallId, input: result.input, output: result.output, tool: tools?[result.toolName],
        errorMode: .none)
      assistantContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: result.toolCallId, toolName: result.toolName, output: output,
            providerOptions: result.providerMetadata)))
    case .toolError(let error):
      guard error.providerExecuted == true else { continue }
      let output = try await createToolModelOutput(
        toolCallId: error.toolCallId, input: error.input, output: errorJSON(error.error),
        tool: tools?[error.toolName], errorMode: .json)
      assistantContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: error.toolCallId, toolName: error.toolName, output: output,
            providerOptions: error.providerMetadata)))
    case .toolApprovalRequest(let request):
      assistantContent.append(
        .toolApprovalRequest(
          ToolApprovalRequest(
            approvalId: request.approvalId, toolCallId: request.toolCall.toolCallId, reason: request.reason,
            isAutomatic: request.isAutomatic, signature: request.signature)))
    case .toolApprovalResponse:
      continue
    }
  }

  var messages: [ModelMessage] = []
  if !assistantContent.isEmpty {
    messages.append(.assistant(assistantContent))
  }

  var toolContent: [ToolContentPart] = []
  for part in content {
    switch part {
    case .toolApprovalResponse(let response):
      toolContent.append(
        .toolApprovalResponse(
          ToolApprovalResponse(
            approvalId: response.approvalId, approved: response.approved, reason: response.reason,
            providerExecuted: response.providerExecuted)))
      if !response.approved {
        toolContent.append(
          .toolResult(
            ToolResultPart(
              toolCallId: response.toolCall.toolCallId, toolName: response.toolCall.toolName,
              output: .executionDenied(reason: response.reason))))
      }
    case .toolResult(let result) where result.providerExecuted != true:
      let output = try await createToolModelOutput(
        toolCallId: result.toolCallId, input: result.input, output: result.output, tool: tools?[result.toolName],
        errorMode: .none)
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: result.toolCallId, toolName: result.toolName, output: output,
            providerOptions: result.providerMetadata)))
    case .toolError(let error) where error.providerExecuted != true:
      let output = try await createToolModelOutput(
        toolCallId: error.toolCallId, input: error.input, output: .string(getErrorMessage(error.error)),
        tool: tools?[error.toolName], errorMode: .text)
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: error.toolCallId, toolName: error.toolName, output: output,
            providerOptions: error.providerMetadata)))
    default:
      continue
    }
  }

  if !toolContent.isEmpty {
    messages.append(.tool(sortByToolCallOrder(toolContent, order: toolCallOrder)))
  }
  return messages
}

private func errorJSON(_ error: any Error) -> JSONValue {
  if let providerError = error as? ProviderToolError { return providerError.value }
  return .string(getErrorMessage(error))
}

private func sortByToolCallOrder(_ content: [ToolContentPart], order: [String: Int]) -> [ToolContentPart] {
  let results = content.enumerated().compactMap { index, part -> (part: ToolContentPart, id: String, index: Int)? in
    if case .toolResult(let result) = part { return (part, result.toolCallId, index) }
    return nil
  }
  let sorted = results.sorted { a, b in
    switch (order[a.id], order[b.id]) {
    case (nil, nil): a.index < b.index
    case (nil, _): false
    case (_, nil): true
    case let (lhs?, rhs?): lhs == rhs ? a.index < b.index : lhs < rhs
    }
  }
  var iterator = sorted.makeIterator()
  return content.map { part in
    if case .toolResult = part { return iterator.next()!.part }
    return part
  }
}
