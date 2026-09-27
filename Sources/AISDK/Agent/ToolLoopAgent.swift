import Foundation

/// An agent: a reusable configuration of model, instructions and tools that
/// can generate or stream. Mirrors upstream `Agent`.
public protocol Agent: Sendable {
  associatedtype OutputValue: Sendable
  associatedtype OutputPartial: Sendable & Equatable
  associatedtype OutputElement: Sendable

  var id: String? { get }
  var tools: ToolSet { get }

  /// Runs the agent to completion.
  func generate(prompt: Prompt, options: JSONValue?) async throws -> GenerateTextResult<OutputValue>

  /// Streams the agent run.
  func stream(prompt: Prompt, options: JSONValue?) async throws
    -> StreamTextResult<OutputValue, OutputPartial, OutputElement>
}

/// The arguments of one agent call, as seen and returned by `prepareCall`.
/// Mirrors upstream's prepared call arguments.
public struct AgentCall: Sendable {
  public var model: LanguageModel
  public var instructions: Instructions?
  public var prompt: Prompt
  public var tools: ToolSet?
  public var toolChoice: ToolChoice?
  public var activeTools: [String]?
  public var stopWhen: [StopCondition]
  public var providerOptions: ProviderOptions?
  public var toolsContext: [String: JSONValue]?
  public var maxOutputTokens: Int?
  public var temperature: Double?
  public var topP: Double?
  public var reasoning: LanguageModelV4ReasoningEffort?
  public var headers: [String: String]?
  /// Validated call options passed to `generate(prompt:options:)`.
  public var options: JSONValue?
}

/// A multi-step tool-calling agent. Mirrors upstream `ToolLoopAgent`.
///
/// Calls the model in a loop, executing tools between steps, until the model
/// stops calling tools or a stop condition is met (20 steps by default).
///
/// ```swift
/// let agent = ToolLoopAgent(
///   model: deepseek("deepseek-flash"),
///   instructions: "You are a travel assistant.",
///   tools: ["weather": weatherTool])
/// let result = try await agent.generate(prompt: "Weather in Hangzhou?")
/// ```
public struct ToolLoopAgent<Value: Sendable, Partial: Sendable & Equatable, Element: Sendable>: Agent {
  public typealias OutputValue = Value
  public typealias OutputPartial = Partial
  public typealias OutputElement = Element

  public let id: String?
  public let model: LanguageModel
  public let instructions: Instructions?
  public let tools: ToolSet
  public let toolChoice: ToolChoice?
  public let activeTools: [String]?
  public let output: Output<Value, Partial, Element>
  public let stopWhen: [StopCondition]
  public let prepareStep: PrepareStepFunction?
  /// Adjusts the arguments of each call, e.g. based on `options`.
  public let prepareCall: (@Sendable (AgentCall) async throws -> AgentCall)?
  /// Validates the `options` passed to `generate` / `stream`.
  public let callOptionsSchema: Schema<JSONValue>?
  public let repairToolCall: ToolCallRepairFunction?
  public let toolApproval: ToolApprovalConfiguration?
  public let toolsContext: [String: JSONValue]?
  public let maxOutputTokens: Int?
  public let temperature: Double?
  public let topP: Double?
  public let reasoning: LanguageModelV4ReasoningEffort?
  public let maxRetries: Int
  public let headers: [String: String]?
  public let providerOptions: ProviderOptions?
  public let onStepFinish: (@Sendable (StepResult) async -> Void)?
  public let onFinish: (@Sendable (GenerateTextResult<Value>) async -> Void)?

  public init(
    id: String? = nil,
    model: LanguageModel,
    instructions: Instructions? = nil,
    tools: ToolSet = [:],
    toolChoice: ToolChoice? = nil,
    activeTools: [String]? = nil,
    output: Output<Value, Partial, Element>,
    stopWhen: [StopCondition] = [.isStepCount(20)],
    prepareStep: PrepareStepFunction? = nil,
    prepareCall: (@Sendable (AgentCall) async throws -> AgentCall)? = nil,
    callOptionsSchema: Schema<JSONValue>? = nil,
    repairToolCall: ToolCallRepairFunction? = nil,
    toolApproval: ToolApprovalConfiguration? = nil,
    toolsContext: [String: JSONValue]? = nil,
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    reasoning: LanguageModelV4ReasoningEffort? = nil,
    maxRetries: Int = 2,
    headers: [String: String]? = nil,
    providerOptions: ProviderOptions? = nil,
    onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
    onFinish: (@Sendable (GenerateTextResult<Value>) async -> Void)? = nil
  ) {
    self.id = id
    self.model = model
    self.instructions = instructions
    self.tools = tools
    self.toolChoice = toolChoice
    self.activeTools = activeTools
    self.output = output
    self.stopWhen = stopWhen
    self.prepareStep = prepareStep
    self.prepareCall = prepareCall
    self.callOptionsSchema = callOptionsSchema
    self.repairToolCall = repairToolCall
    self.toolApproval = toolApproval
    self.toolsContext = toolsContext
    self.maxOutputTokens = maxOutputTokens
    self.temperature = temperature
    self.topP = topP
    self.reasoning = reasoning
    self.maxRetries = maxRetries
    self.headers = headers
    self.providerOptions = providerOptions
    self.onStepFinish = onStepFinish
    self.onFinish = onFinish
  }

  private func preparedCall(prompt: Prompt, options: JSONValue?) async throws -> AgentCall {
    var validatedOptions = options
    if let callOptionsSchema, let options {
      validatedOptions = try validateTypes(
        value: options, schema: callOptionsSchema, context: TypeValidationContext(field: "options"))
    }
    let call = AgentCall(
      model: model, instructions: instructions, prompt: prompt, tools: tools.isEmpty ? nil : tools,
      toolChoice: toolChoice, activeTools: activeTools, stopWhen: stopWhen, providerOptions: providerOptions,
      toolsContext: toolsContext, maxOutputTokens: maxOutputTokens, temperature: temperature, topP: topP,
      reasoning: reasoning, headers: headers, options: validatedOptions)
    return try await prepareCall?(call) ?? call
  }

  private func agentHeaders(_ headers: [String: String]?) -> [String: String] {
    withUserAgentSuffix(headers, "ai-sdk-agent/tool-loop")
  }

  /// Runs the agent to completion. Mirrors upstream `ToolLoopAgent.generate`.
  ///
  /// Call-level callbacks run after the agent-level ones.
  public func generate(
    prompt: Prompt,
    options: JSONValue? = nil,
    onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
    onFinish: (@Sendable (GenerateTextResult<Value>) async -> Void)? = nil
  ) async throws -> GenerateTextResult<Value> {
    let call = try await preparedCall(prompt: prompt, options: options)
    let agentStepFinish = self.onStepFinish
    let agentFinish = self.onFinish
    return try await generateText(
      model: call.model, instructions: call.instructions, prompt: call.prompt, tools: call.tools,
      toolChoice: call.toolChoice, activeTools: call.activeTools, output: output,
      maxOutputTokens: call.maxOutputTokens, temperature: call.temperature, topP: call.topP,
      reasoning: call.reasoning, maxRetries: maxRetries, headers: agentHeaders(call.headers),
      providerOptions: call.providerOptions, stopWhen: call.stopWhen, prepareStep: prepareStep,
      repairToolCall: repairToolCall, toolApproval: toolApproval, toolsContext: call.toolsContext,
      onStepFinish: { step in
        await agentStepFinish?(step)
        await onStepFinish?(step)
      },
      onFinish: { result in
        await agentFinish?(result)
        await onFinish?(result)
      })
  }

  public func generate(prompt: Prompt, options: JSONValue?) async throws -> GenerateTextResult<Value> {
    try await generate(prompt: prompt, options: options, onStepFinish: nil, onFinish: nil)
  }

  /// Streams the agent run. Mirrors upstream `ToolLoopAgent.stream`.
  public func stream(
    prompt: Prompt,
    options: JSONValue? = nil,
    transform: [StreamTextTransform] = [],
    onChunk: (@Sendable (TextStreamPart) async -> Void)? = nil,
    onError: (@Sendable (any Error) async -> Void)? = nil,
    onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
    onFinish: (@Sendable (GenerateTextResult<Value>) async -> Void)? = nil
  ) async throws -> StreamTextResult<Value, Partial, Element> {
    let call = try await preparedCall(prompt: prompt, options: options)
    let agentStepFinish = self.onStepFinish
    let agentFinish = self.onFinish
    return streamText(
      model: call.model, instructions: call.instructions, prompt: call.prompt, tools: call.tools,
      toolChoice: call.toolChoice, activeTools: call.activeTools, output: output,
      maxOutputTokens: call.maxOutputTokens, temperature: call.temperature, topP: call.topP,
      reasoning: call.reasoning, maxRetries: maxRetries, headers: agentHeaders(call.headers),
      providerOptions: call.providerOptions, stopWhen: call.stopWhen, prepareStep: prepareStep,
      repairToolCall: repairToolCall, toolApproval: toolApproval, toolsContext: call.toolsContext,
      transform: transform, onChunk: onChunk, onError: onError,
      onStepFinish: { step in
        await agentStepFinish?(step)
        await onStepFinish?(step)
      },
      onFinish: { result in
        await agentFinish?(result)
        await onFinish?(result)
      })
  }

  public func stream(prompt: Prompt, options: JSONValue?) async throws -> StreamTextResult<Value, Partial, Element> {
    try await stream(prompt: prompt, options: options, transform: [])
  }
}

extension ToolLoopAgent where Value == String, Partial == String, Element == NoElement {
  /// Creates a text agent.
  public init(
    id: String? = nil,
    model: LanguageModel,
    instructions: Instructions? = nil,
    tools: ToolSet = [:],
    toolChoice: ToolChoice? = nil,
    activeTools: [String]? = nil,
    stopWhen: [StopCondition] = [.isStepCount(20)],
    prepareStep: PrepareStepFunction? = nil,
    prepareCall: (@Sendable (AgentCall) async throws -> AgentCall)? = nil,
    callOptionsSchema: Schema<JSONValue>? = nil,
    repairToolCall: ToolCallRepairFunction? = nil,
    toolApproval: ToolApprovalConfiguration? = nil,
    toolsContext: [String: JSONValue]? = nil,
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    reasoning: LanguageModelV4ReasoningEffort? = nil,
    maxRetries: Int = 2,
    headers: [String: String]? = nil,
    providerOptions: ProviderOptions? = nil,
    onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
    onFinish: (@Sendable (GenerateTextResult<String>) async -> Void)? = nil
  ) {
    self.init(
      id: id, model: model, instructions: instructions, tools: tools, toolChoice: toolChoice,
      activeTools: activeTools, output: .text(), stopWhen: stopWhen, prepareStep: prepareStep,
      prepareCall: prepareCall, callOptionsSchema: callOptionsSchema, repairToolCall: repairToolCall,
      toolApproval: toolApproval, toolsContext: toolsContext, maxOutputTokens: maxOutputTokens,
      temperature: temperature, topP: topP, reasoning: reasoning, maxRetries: maxRetries, headers: headers,
      providerOptions: providerOptions, onStepFinish: onStepFinish, onFinish: onFinish)
  }
}
