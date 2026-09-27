import Foundation

/// An approval decision for a tool call. Mirrors upstream `ToolApprovalStatus`.
public enum ToolApprovalStatus: Sendable, Equatable {
  /// The tool does not need approval.
  case notApplicable
  /// Approved automatically.
  case approved(reason: String? = nil)
  /// Denied automatically.
  case denied(reason: String? = nil)
  /// The user must decide; generation stops with an approval request.
  case userApproval(reason: String? = nil)
}

/// Options passed to a tool approval function.
public struct ToolApprovalOptions: Sendable {
  public var toolCall: ToolCall
  public var tools: ToolSet?
  public var messages: [ModelMessage]
  public var toolsContext: [String: JSONValue]?
}

/// Decides tool approvals for a generation call. Mirrors upstream
/// `ToolApprovalConfiguration`.
public enum ToolApprovalConfiguration: Sendable {
  /// One function for every tool call.
  case generic(@Sendable (ToolApprovalOptions) async throws -> ToolApprovalStatus)
  /// Per-tool functions keyed by tool name. Tools without an entry fall back
  /// to their `needsApproval` setting.
  case perTool([String: @Sendable (JSONValue, ToolApprovalOptions) async throws -> ToolApprovalStatus])

  /// Requires user approval for the named tools.
  public static func requireApproval(for toolNames: String...) -> ToolApprovalConfiguration {
    .perTool(
      Dictionary(uniqueKeysWithValues: toolNames.map { name in (name, { @Sendable _, _ in .userApproval() }) }))
  }
}

/// Resolves the approval status of a tool call. Mirrors upstream `resolveToolApproval`.
func resolveToolApproval(
  toolCall: ToolCall,
  tools: ToolSet?,
  configuration: ToolApprovalConfiguration?,
  messages: [ModelMessage],
  toolsContext: [String: JSONValue]?
) async throws -> ToolApprovalStatus {
  let options = ToolApprovalOptions(toolCall: toolCall, tools: tools, messages: messages, toolsContext: toolsContext)
  switch configuration {
  case .generic(let decide):
    return try await decide(options)
  case .perTool(let functions):
    if let decide = functions[toolCall.toolName] {
      return try await decide(toolCall.input, options)
    }
  case nil:
    break
  }

  guard let needsApproval = tools?[toolCall.toolName]?.needsApproval else {
    return .notApplicable
  }
  let needs = try await needsApproval(
    toolCall.input,
    ToolExecutionOptions(
      toolCallId: toolCall.toolCallId, messages: messages, context: toolsContext?[toolCall.toolName]))
  return needs ? .userApproval() : .notApplicable
}

/// A tool approval collected from the last tool message. Mirrors upstream `CollectedToolApprovals`.
struct CollectedToolApproval: Sendable {
  var approvalRequest: ToolApprovalRequest
  var approvalResponse: ToolApprovalResponse
  var toolCall: ToolCall
  var existingToolResult: ToolResultPart?
}

/// Collects approval responses in the last tool message. Mirrors upstream `collectToolApprovals`.
func collectToolApprovals(messages: [ModelMessage]) throws -> (
  approved: [CollectedToolApproval], denied: [CollectedToolApproval]
) {
  guard case .tool(let lastMessage)? = messages.last else { return ([], []) }

  var toolCalls: [String: ToolCall] = [:]
  var approvalRequests: [String: ToolApprovalRequest] = [:]
  for case .assistant(let message) in messages {
    for part in message.content {
      switch part {
      case .toolCall(let call):
        toolCalls[call.toolCallId] = ToolCall(
          toolCallId: call.toolCallId, toolName: call.toolName, input: call.input,
          providerExecuted: call.providerExecuted, providerMetadata: call.providerOptions)
      case .toolApprovalRequest(let request):
        approvalRequests[request.approvalId] = request
      default:
        break
      }
    }
  }

  var toolResults: [String: ToolResultPart] = [:]
  for case .toolResult(let result) in lastMessage.content {
    toolResults[result.toolCallId] = result
  }

  var approved: [CollectedToolApproval] = []
  var denied: [CollectedToolApproval] = []
  for case .toolApprovalResponse(let response) in lastMessage.content {
    guard let request = approvalRequests[response.approvalId] else {
      throw InvalidToolApprovalError(approvalId: response.approvalId)
    }
    let existing = toolResults[request.toolCallId]
    if let existing {
      let isDenied = if case .executionDenied = existing.output { true } else { false }
      if response.approved || !isDenied { continue }
    }
    guard let toolCall = toolCalls[request.toolCallId] else {
      throw ToolCallNotFoundForApprovalError(toolCallId: request.toolCallId, approvalId: request.approvalId)
    }
    let approval = CollectedToolApproval(
      approvalRequest: request, approvalResponse: response, toolCall: toolCall, existingToolResult: existing)
    if response.approved {
      approved.append(approval)
    } else {
      denied.append(approval)
    }
  }
  return (approved, denied)
}
