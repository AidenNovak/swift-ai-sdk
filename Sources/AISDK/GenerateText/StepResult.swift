import Foundation

/// Request metadata for a step. Mirrors upstream `LanguageModelRequestMetadata`.
public struct LanguageModelRequestMetadata: Sendable, Equatable {
  /// The request body sent to the provider.
  public var body: JSONValue?
  /// The messages sent to the model.
  public var messages: [ModelMessage]?

  public init(body: JSONValue? = nil, messages: [ModelMessage]? = nil) {
    self.body = body
    self.messages = messages
  }
}

/// Response metadata for a step. Mirrors upstream `LanguageModelResponseMetadata`
/// plus the response messages.
public struct LanguageModelResponseMetadata: Sendable, Equatable {
  public var id: String
  public var timestamp: Date
  public var modelId: String
  public var headers: [String: String]?
  public var body: JSONValue?
  /// The assistant and tool messages generated in the step.
  public var messages: [ModelMessage]

  public init(
    id: String, timestamp: Date, modelId: String, headers: [String: String]? = nil, body: JSONValue? = nil,
    messages: [ModelMessage] = []
  ) {
    self.id = id
    self.timestamp = timestamp
    self.modelId = modelId
    self.headers = headers
    self.body = body
    self.messages = messages
  }
}

/// The result of one generation step. Mirrors upstream `StepResult`.
public struct StepResult: Sendable {
  /// Zero-based step index.
  public var stepNumber: Int
  public var provider: String
  public var modelId: String
  public var content: [ContentPart]
  public var finishReason: FinishReason
  /// The raw finish reason from the provider.
  public var rawFinishReason: String?
  public var usage: LanguageModelUsage
  public var warnings: [Warning]
  public var request: LanguageModelRequestMetadata
  public var response: LanguageModelResponseMetadata
  public var providerMetadata: ProviderMetadata?

  public init(
    stepNumber: Int,
    provider: String,
    modelId: String,
    content: [ContentPart],
    finishReason: FinishReason,
    rawFinishReason: String?,
    usage: LanguageModelUsage,
    warnings: [Warning],
    request: LanguageModelRequestMetadata,
    response: LanguageModelResponseMetadata,
    providerMetadata: ProviderMetadata?
  ) {
    self.stepNumber = stepNumber
    self.provider = provider
    self.modelId = modelId
    self.content = content
    self.finishReason = finishReason
    self.rawFinishReason = rawFinishReason
    self.usage = usage
    self.warnings = warnings
    self.request = request
    self.response = response
    self.providerMetadata = providerMetadata
  }

  /// The generated text.
  public var text: String {
    content.reduce(into: "") { text, part in
      if case .text(let value, _) = part { text += value }
    }
  }

  /// The reasoning parts.
  public var reasoning: [ReasoningOutput] {
    content.compactMap {
      if case .reasoning(let reasoning) = $0 { return reasoning }
      return nil
    }
  }

  /// The reasoning text, or `nil` when there is no reasoning.
  public var reasoningText: String? {
    let reasoning = reasoning
    return reasoning.isEmpty ? nil : reasoning.map(\.text).joined()
  }

  /// Generated files.
  public var files: [GeneratedFile] {
    content.compactMap {
      if case .file(let file, _) = $0 { return file }
      return nil
    }
  }

  /// Sources used for generation.
  public var sources: [Source] {
    content.compactMap {
      if case .source(let source) = $0 { return source }
      return nil
    }
  }

  /// All tool calls.
  public var toolCalls: [ToolCall] {
    content.compactMap {
      if case .toolCall(let call) = $0 { return call }
      return nil
    }
  }

  /// Tool calls for tools defined at development time.
  public var staticToolCalls: [ToolCall] { toolCalls.filter { !$0.dynamic } }

  /// Tool calls for dynamic tools and invalid calls.
  public var dynamicToolCalls: [ToolCall] { toolCalls.filter(\.dynamic) }

  /// All tool results.
  public var toolResults: [ToolResult] {
    content.compactMap {
      if case .toolResult(let result) = $0 { return result }
      return nil
    }
  }

  public var staticToolResults: [ToolResult] { toolResults.filter { !$0.dynamic } }

  public var dynamicToolResults: [ToolResult] { toolResults.filter(\.dynamic) }

  /// Tool errors.
  public var toolErrors: [ToolError] {
    content.compactMap {
      if case .toolError(let error) = $0 { return error }
      return nil
    }
  }

  /// Tool approval requests awaiting a user decision.
  public var toolApprovalRequests: [ToolApprovalRequestOutput] {
    content.compactMap {
      if case .toolApprovalRequest(let request) = $0, request.isAutomatic != true { return request }
      return nil
    }
  }
}

/// Decides whether a multi-step generation stops. Mirrors upstream `StopCondition`.
public struct StopCondition: Sendable {
  public let isMet: @Sendable ([StepResult]) async -> Bool

  public init(_ isMet: @escaping @Sendable ([StepResult]) async -> Bool) {
    self.isMet = isMet
  }

  /// Stops after the given number of steps. Mirrors upstream `isStepCount`.
  public static func isStepCount(_ count: Int) -> StopCondition {
    StopCondition { $0.count == count }
  }

  /// Stops when the last step called one of the tools. Mirrors upstream `hasToolCall`.
  public static func hasToolCall(_ toolNames: String...) -> StopCondition {
    StopCondition { steps in
      steps.last?.toolCalls.contains { toolNames.contains($0.toolName) } ?? false
    }
  }

  /// Never stops; the loop ends when the model stops calling tools.
  /// Mirrors upstream `isLoopFinished`.
  public static func isLoopFinished() -> StopCondition {
    StopCondition { _ in false }
  }
}

/// Whether any stop condition is met. Mirrors upstream `isStopConditionMet`.
func isStopConditionMet(_ conditions: [StopCondition], steps: [StepResult]) async -> Bool {
  for condition in conditions where await condition.isMet(steps) {
    return true
  }
  return false
}
