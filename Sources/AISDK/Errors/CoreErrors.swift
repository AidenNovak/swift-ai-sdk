import Foundation

/// The model called a tool that is not in the tool set. Mirrors upstream `NoSuchToolError`.
public struct NoSuchToolError: AISDKError {
  public let name = "AI_NoSuchToolError"
  public let message: String
  public let toolName: String
  public let availableTools: [String]?

  public init(toolName: String, availableTools: [String]? = nil, message: String? = nil) {
    self.toolName = toolName
    self.availableTools = availableTools
    let availability =
      availableTools.map { "Available tools: \($0.joined(separator: ", "))." } ?? "No tools are available."
    self.message = message ?? "Model tried to call unavailable tool '\(toolName)'. \(availability)"
  }
}

/// The model generated tool input that does not match the tool's schema.
/// Mirrors upstream `InvalidToolInputError`.
public struct InvalidToolInputError: AISDKError {
  public let name = "AI_InvalidToolInputError"
  public let message: String
  public let toolName: String
  public let toolInput: String
  public let cause: (any Error)?

  public init(toolName: String, toolInput: String, cause: (any Error)?, message: String? = nil) {
    self.toolName = toolName
    self.toolInput = toolInput
    self.cause = cause
    self.message = message ?? "Invalid input for tool \(toolName): \(getErrorMessage(cause))"
  }
}

/// Repairing a tool call failed. Mirrors upstream `ToolCallRepairError`.
public struct ToolCallRepairError: AISDKError {
  public let name = "AI_ToolCallRepairError"
  public let message: String
  public let cause: (any Error)?
  public let originalError: any Error

  public init(cause: (any Error)?, originalError: any Error, message: String? = nil) {
    self.cause = cause
    self.originalError = originalError
    self.message = message ?? "Error repairing tool call: \(getErrorMessage(cause))"
  }
}

/// The model ignored a required tool choice. Mirrors upstream `ToolChoiceViolationError`.
public struct ToolChoiceViolationError: AISDKError {
  public let name = "AI_ToolChoiceViolationError"
  public let message: String
  public let toolChoice: LanguageModelV4ToolChoice
  public let finishReason: FinishReason
  public let provider: String
  public let modelId: String
  public let content: [LanguageModelV4Content]

  public init(
    toolChoice: LanguageModelV4ToolChoice,
    finishReason: FinishReason,
    provider: String,
    modelId: String,
    content: [LanguageModelV4Content],
    message: String? = nil
  ) {
    self.toolChoice = toolChoice
    self.finishReason = finishReason
    self.provider = provider
    self.modelId = modelId
    self.content = content
    if let message {
      self.message = message
    } else if case .tool(let toolName) = toolChoice {
      self.message = "Model response did not contain a call to the required tool '\(toolName)'."
    } else {
      self.message = "Model response did not contain a tool call even though tool choice was required."
    }
  }
}

/// No output was generated, e.g. because the model call failed or the output
/// could not be parsed. Mirrors upstream `NoOutputGeneratedError`.
public struct NoOutputGeneratedError: AISDKError {
  public let name = "AI_NoOutputGeneratedError"
  public let message: String
  public let cause: (any Error)?

  public init(message: String = "No output generated.", cause: (any Error)? = nil) {
    self.message = message
    self.cause = cause
  }
}

/// The prompt contains tool calls without results. Mirrors upstream `MissingToolResultsError`.
public struct MissingToolResultsError: AISDKError {
  public let name = "AI_MissingToolResultsError"
  public let message: String
  public let toolCallIds: [String]

  public init(toolCallIds: [String]) {
    self.toolCallIds = toolCallIds
    let plural = toolCallIds.count > 1
    self.message =
      "Tool result\(plural ? "s are" : " is") missing for tool call\(plural ? "s" : "") \(toolCallIds.joined(separator: ", "))."
  }
}

/// A tool approval response references an unknown approval request.
/// Mirrors upstream `InvalidToolApprovalError`.
public struct InvalidToolApprovalError: AISDKError {
  public let name = "AI_InvalidToolApprovalError"
  public let message: String
  public let approvalId: String

  public init(approvalId: String) {
    self.approvalId = approvalId
    self.message =
      "Tool approval response references unknown approvalId: \"\(approvalId)\". No matching tool-approval-request found in message history."
  }
}

/// A tool approval request references an unknown tool call.
/// Mirrors upstream `ToolCallNotFoundForApprovalError`.
public struct ToolCallNotFoundForApprovalError: AISDKError {
  public let name = "AI_ToolCallNotFoundForApprovalError"
  public let message: String
  public let toolCallId: String
  public let approvalId: String

  public init(toolCallId: String, approvalId: String) {
    self.toolCallId = toolCallId
    self.approvalId = approvalId
    self.message = "Tool call \"\(toolCallId)\" not found for approval request \"\(approvalId)\"."
  }
}

/// Retrying a model call failed. Mirrors upstream `RetryError`.
public struct RetryError: AISDKError {
  public let name = "AI_RetryError"
  public let message: String
  public let reason: RetryErrorReason
  public let errors: [any Error]

  public init(message: String, reason: RetryErrorReason, errors: [any Error]) {
    self.message = message
    self.reason = reason
    self.errors = errors
  }

  /// The error of the last attempt.
  public var lastError: (any Error)? { errors.last }
}

/// A message contains data that cannot be converted. Mirrors upstream `InvalidDataContentError`.
public struct InvalidDataContentError: AISDKError {
  public let name = "AI_InvalidDataContentError"
  public let message: String
  public let content: String
  public let cause: (any Error)?

  public init(content: String, cause: (any Error)? = nil, message: String? = nil) {
    self.content = content
    self.cause = cause
    self.message = message ?? "Invalid data content. Expected a base64 string, Data, or URL."
  }
}

