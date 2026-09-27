import Foundation

private struct UIValidationFailure: Error, CustomStringConvertible {
  let description: String
}

/// Validates UI messages received from a client, e.g. before
/// `convertToModelMessages`. Mirrors upstream `validateUIMessages`.
///
/// Checks the structure (including per-state tool part requirements), the
/// metadata and data parts against the given schemas, and tool inputs against
/// the tools' input schemas. Terminal static tool parts whose tool is not in
/// `tools` become dynamic tool parts.
///
/// Upstream also validates tool outputs against Standard Schema output
/// schemas; Swift tools only carry an output JSON Schema, so outputs are not
/// validated.
///
/// - Throws: `InvalidArgumentError` or `TypeValidationError`.
public func validateUIMessages(
  _ messages: JSONValue?,
  metadataSchema: Schema<JSONValue>? = nil,
  dataSchemas: [String: Schema<JSONValue>]? = nil,
  tools: ToolSet? = nil
) throws -> [UIMessage] {
  try validateUIMessagesInternal(
    messages, metadataSchema: metadataSchema, dataSchemas: dataSchemas, tools: tools,
    convertMissingTerminalToolsToDynamic: false)
}

/// Validates UI messages. See `validateUIMessages(_:metadataSchema:dataSchemas:tools:)`.
public func validateUIMessages(
  _ messages: [UIMessage],
  metadataSchema: Schema<JSONValue>? = nil,
  dataSchemas: [String: Schema<JSONValue>]? = nil,
  tools: ToolSet? = nil
) throws -> [UIMessage] {
  try validateUIMessages(
    .array(messages.map(\.json)), metadataSchema: metadataSchema, dataSchemas: dataSchemas, tools: tools)
}

/// Validates UI messages without throwing. Mirrors upstream `safeValidateUIMessages`.
public func safeValidateUIMessages(
  _ messages: JSONValue?,
  metadataSchema: Schema<JSONValue>? = nil,
  dataSchemas: [String: Schema<JSONValue>]? = nil,
  tools: ToolSet? = nil
) -> Result<[UIMessage], any Error> {
  Result {
    try validateUIMessages(messages, metadataSchema: metadataSchema, dataSchemas: dataSchemas, tools: tools)
  }
}

/// Validates UI messages for an agent: terminal tool parts of tools the agent
/// does not have become dynamic tool parts. Mirrors upstream `validateUIMessagesForAgent`.
public func validateUIMessagesForAgent(
  _ messages: [UIMessage],
  metadataSchema: Schema<JSONValue>? = nil,
  dataSchemas: [String: Schema<JSONValue>]? = nil,
  tools: ToolSet? = nil
) throws -> [UIMessage] {
  try validateUIMessagesInternal(
    .array(messages.map(\.json)), metadataSchema: metadataSchema, dataSchemas: dataSchemas, tools: tools,
    convertMissingTerminalToolsToDynamic: true)
}

private func validateUIMessagesInternal(
  _ messagesJSON: JSONValue?,
  metadataSchema: Schema<JSONValue>?,
  dataSchemas: [String: Schema<JSONValue>]?,
  tools: ToolSet?,
  convertMissingTerminalToolsToDynamic: Bool
) throws -> [UIMessage] {
  guard let messagesJSON, !messagesJSON.isNull else {
    throw InvalidArgumentError(argument: "messages", message: "messages parameter must be provided")
  }

  var messages: [UIMessage]
  do {
    messages = try decodeUIMessagesStructure(messagesJSON)
  } catch {
    throw TypeValidationError(value: messagesJSON, cause: error)
  }

  if let metadataSchema {
    for index in messages.indices {
      messages[index].metadata = try validateTypes(
        value: messages[index].metadata ?? .null, schema: metadataSchema,
        context: TypeValidationContext(field: "messages[\(index)].metadata", entityId: messages[index].id))
    }
  }

  let shouldValidateToolParts = tools != nil || convertMissingTerminalToolsToDynamic
  guard dataSchemas != nil || shouldValidateToolParts else { return messages }

  for messageIndex in messages.indices {
    for partIndex in messages[messageIndex].parts.indices {
      switch messages[messageIndex].parts[partIndex] {
      case .data(var part) where dataSchemas != nil:
        let context = TypeValidationContext(
          field: "messages[\(messageIndex)].parts[\(partIndex)].data", entityName: part.name, entityId: part.id)
        guard let schema = dataSchemas?[part.name] else {
          throw TypeValidationError(
            value: part.data, cause: UIValidationFailure(description: "No data schema found for data part \(part.name)"),
            context: context)
        }
        part.data = try validateTypes(value: part.data, schema: schema, context: context)
        messages[messageIndex].parts[partIndex] = .data(part)

      case .tool(let part) where shouldValidateToolParts && !part.isDynamic:
        if let converted = try validateStaticToolPart(
          part, tool: tools?[part.toolName], field: "messages[\(messageIndex)].parts[\(partIndex)]")
        {
          messages[messageIndex].parts[partIndex] = .tool(converted)
        }

      default:
        break
      }
    }
  }
  return messages
}

private func decodeUIMessagesStructure(_ json: JSONValue) throws -> [UIMessage] {
  guard let array = json.arrayValue else {
    throw MessageDecodingError(message: "Expected an array of messages.")
  }
  guard !array.isEmpty else {
    throw MessageDecodingError(message: "Messages array must not be empty")
  }
  return try array.enumerated().map { index, element in
    let path = "messages[\(index)]"
    var message = try UIMessage(json: element, path: path)
    if message.role != .assistant && message.parts.isEmpty {
      throw MessageDecodingError(message: "Message must contain at least one part at \(path).parts.")
    }
    for partIndex in message.parts.indices {
      if case .tool(let part) = message.parts[partIndex] {
        message.parts[partIndex] = .tool(try part.validatedStructure(path: "\(path).parts[\(partIndex)]"))
      }
    }
    return message
  }
}

/// Validates a static tool part's input; returns a replacement part when it
/// must become a dynamic tool part.
private func validateStaticToolPart(_ part: ToolUIPart, tool: Tool?, field: String) throws -> ToolUIPart? {
  let isTerminal = part.state == .outputAvailable || part.state == .outputError || part.state == .outputDenied
  var dynamicPart: ToolUIPart {
    var copy = part
    copy.isDynamic = true
    return copy
  }

  guard let tool else {
    if isTerminal { return dynamicPart }
    throw TypeValidationError(
      value: part.input,
      cause: UIValidationFailure(description: "No tool schema found for tool part \(part.toolName)"),
      context: TypeValidationContext(field: "\(field).input", entityName: part.toolName, entityId: part.toolCallId))
  }

  let context = TypeValidationContext(field: "\(field).input", entityName: part.toolName, entityId: part.toolCallId)
  let inputSchemaInput = part.approval?.inputSchemaInput
  guard part.state != .inputStreaming, part.state != .outputError || inputSchemaInput != nil || part.input != nil
  else { return nil }

  var inputError: (any Error)?
  switch safeValidateTypes(value: inputSchemaInput ?? part.input ?? .null, schema: tool.inputSchema, context: context) {
  case .failure(let error, _):
    inputError = error
  case .success(let value, _):
    if inputSchemaInput != nil && value != (part.input ?? .null) {
      inputError = TypeValidationError(
        value: part.input,
        cause: UIValidationFailure(
          description: "Tool input does not match the output reconstructed from inputSchemaInput."),
        context: context)
    }
  }

  guard let inputError else { return nil }
  let hasEmptyInput = part.input?.objectValue?.isEmpty == true
  if part.state == .outputError || (part.state == .outputAvailable && hasEmptyInput) {
    return dynamicPart
  }
  throw inputError
}
