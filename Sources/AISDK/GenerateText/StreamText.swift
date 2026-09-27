import Foundation

private let defaultStreamGenerateId: IdGenerator = {
  try! createIdGenerator(prefix: "aitxt", size: 24)
}()

/// The result of `streamText`. Mirrors upstream `StreamTextResult`.
///
/// Generation starts immediately. Every access to `fullStream` or `textStream`
/// returns a new stream that replays all parts from the beginning, so the
/// result can be consumed several times. The async properties resolve when
/// the stream has finished.
///
/// Cancelling a task that iterates one of the streams cancels the generation,
/// as does calling `cancel()`.
public final class StreamTextResult<OutputValue: Sendable, Partial: Sendable & Equatable, Element: Sendable>:
  StreamTextRecorder, @unchecked Sendable
{
  private let lock = NSLock()
  private var parts: [TextStreamPart] = []
  private var isFinished = false
  private var subscribers: [UUID: AsyncThrowingStream<TextStreamPart, any Error>.Continuation] = [:]
  private var completionWaiters: [CheckedContinuation<Void, Never>] = []
  private var recordedSteps: [StepResult] = []
  private var recordedInitialResponseMessages: [ModelMessage] = []
  private var recordedError: (any Error)?
  private var recordedOutput: OutputValue?
  private var outputError: (any Error)?
  private var generationTask: Task<Void, Never>?
  let outputSpecification: Output<OutputValue, Partial, Element>

  init(output: Output<OutputValue, Partial, Element>) {
    self.outputSpecification = output
  }

  // MARK: Streams

  /// Every part of the generation, including steps, tool calls and results.
  /// Errors are delivered as `.error` parts rather than thrown.
  public var fullStream: AsyncThrowingStream<TextStreamPart, any Error> {
    let (stream, continuation) = AsyncThrowingStream<TextStreamPart, any Error>.makeStream()
    let id = UUID()
    continuation.onTermination = { [weak self] termination in
      guard let self else { return }
      let wasRunning = self.lock.withLock { () -> Bool in
        self.subscribers.removeValue(forKey: id)
        return !self.isFinished
      }
      if case .cancelled = termination, wasRunning {
        self.cancel()
      }
    }
    // `finish()` runs `onTermination` synchronously, which takes the lock,
    // so it must be called after the lock is released.
    let alreadyFinished = lock.withLock { () -> Bool in
      for part in parts { continuation.yield(part) }
      if !isFinished { subscribers[id] = continuation }
      return isFinished
    }
    if alreadyFinished { continuation.finish() }
    return stream
  }

  /// Only the generated text deltas.
  public var textStream: AsyncThrowingStream<String, any Error> {
    let parts = fullStream
    let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    let task = Task {
      do {
        for try await part in parts {
          if case .textDelta(_, let text, _) = part { continuation.yield(text) }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }

  /// Partial outputs parsed from the text of the current step, emitted
  /// whenever they change. Mirrors upstream `partialOutputStream`.
  public var partialOutputStream: AsyncThrowingStream<Partial, any Error> {
    let parts = fullStream
    let output = outputSpecification
    let (stream, continuation) = AsyncThrowingStream<Partial, any Error>.makeStream()
    let task = Task {
      var text = ""
      var last: Partial?
      do {
        for try await part in parts {
          switch part {
          case .startStep:
            text = ""
          case .textDelta(_, let delta, _):
            text += delta
            if let partial = output.parsePartialOutput(text), partial != last {
              last = partial
              continuation.yield(partial)
            }
          default:
            break
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }

  /// Array elements as soon as they are complete. Empty for non-array
  /// outputs. Mirrors upstream `elementStream`.
  public var elementStream: AsyncThrowingStream<Element, any Error> {
    let partials = partialOutputStream
    let elements = outputSpecification.elements
    let (stream, continuation) = AsyncThrowingStream<Element, any Error>.makeStream()
    let task = Task {
      var published = 0
      do {
        for try await partial in partials {
          guard let values = elements?(partial) else { continue }
          while published < values.count {
            continuation.yield(values[published])
            published += 1
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }

  /// The parsed output of the final step.
  ///
  /// - Throws: `NoOutputGeneratedError` when nothing was generated, or the
  ///   parse error (e.g. `NoObjectGeneratedError`).
  public var output: OutputValue {
    get async throws {
      _ = try await steps
      let (output, error) = lock.withLock { (recordedOutput, outputError) }
      if let output { return output }
      throw error ?? NoOutputGeneratedError()
    }
  }

  /// Cancels the generation. The stream ends with an `.abort` part.
  public func cancel() {
    lock.withLock { generationTask }?.cancel()
  }

  /// Waits until the stream has finished. Mirrors upstream `consumeStream`.
  public func consumeStream() async {
    await waitForCompletion()
  }

  // MARK: Results

  /// All steps. Throws `NoOutputGeneratedError` when no step completed.
  public var steps: [StepResult] {
    get async throws {
      await waitForCompletion()
      let (steps, error) = lock.withLock { (recordedSteps, recordedError) }
      guard !steps.isEmpty else { throw NoOutputGeneratedError(cause: error) }
      return steps
    }
  }

  /// The last step.
  public var finalStep: StepResult {
    get async throws { try await steps.last! }
  }

  public var text: String { get async throws { try await finalStep.text } }
  public var content: [ContentPart] { get async throws { try await steps.flatMap(\.content) } }
  public var reasoning: [ReasoningOutput] { get async throws { try await finalStep.reasoning } }
  public var reasoningText: String? { get async throws { try await finalStep.reasoningText } }
  public var files: [GeneratedFile] { get async throws { try await steps.flatMap(\.files) } }
  public var sources: [Source] { get async throws { try await steps.flatMap(\.sources) } }
  public var toolCalls: [ToolCall] { get async throws { try await steps.flatMap(\.toolCalls) } }
  public var staticToolCalls: [ToolCall] { get async throws { try await steps.flatMap(\.staticToolCalls) } }
  public var dynamicToolCalls: [ToolCall] { get async throws { try await steps.flatMap(\.dynamicToolCalls) } }
  public var toolResults: [ToolResult] { get async throws { try await steps.flatMap(\.toolResults) } }
  public var staticToolResults: [ToolResult] { get async throws { try await steps.flatMap(\.staticToolResults) } }
  public var dynamicToolResults: [ToolResult] { get async throws { try await steps.flatMap(\.dynamicToolResults) } }
  public var finishReason: FinishReason { get async throws { try await finalStep.finishReason } }
  public var rawFinishReason: String? { get async throws { try await finalStep.rawFinishReason } }
  /// Usage of the last step.
  public var usage: LanguageModelUsage { get async throws { try await finalStep.usage } }
  /// Usage summed over all steps.
  public var totalUsage: LanguageModelUsage {
    get async throws { try await steps.reduce(LanguageModelUsage()) { $0 + $1.usage } }
  }
  public var warnings: [Warning] { get async throws { try await steps.flatMap(\.warnings) } }
  public var providerMetadata: ProviderMetadata? { get async throws { try await finalStep.providerMetadata } }
  public var request: LanguageModelRequestMetadata { get async throws { try await finalStep.request } }
  public var response: LanguageModelResponseMetadata { get async throws { try await finalStep.response } }

  /// Messages generated by the call, ready to append to the conversation.
  public var responseMessages: [ModelMessage] {
    get async throws {
      let steps = try await steps
      return lock.withLock { recordedInitialResponseMessages } + steps.flatMap(\.response.messages)
    }
  }

  // MARK: Internal plumbing

  func setTask(_ task: Task<Void, Never>) {
    lock.withLock { generationTask = task }
  }

  func broadcast(_ part: TextStreamPart) {
    let continuations = lock.withLock { () -> [AsyncThrowingStream<TextStreamPart, any Error>.Continuation] in
      parts.append(part)
      return Array(subscribers.values)
    }
    for continuation in continuations { continuation.yield(part) }
  }

  func appendStep(_ step: StepResult) {
    lock.withLock { recordedSteps.append(step) }
  }

  func setInitialResponseMessages(_ messages: [ModelMessage]) {
    lock.withLock { recordedInitialResponseMessages = messages }
  }

  func recordError(_ error: any Error) {
    lock.withLock { recordedError = error }
  }

  func recordOutput(_ output: OutputValue?, error: (any Error)?) {
    lock.withLock {
      recordedOutput = output
      outputError = error
    }
  }

  func finish() {
    let (continuations, waiters) = lock.withLock {
      isFinished = true
      let continuations = Array(subscribers.values)
      let waiters = completionWaiters
      subscribers.removeAll()
      completionWaiters.removeAll()
      return (continuations, waiters)
    }
    for continuation in continuations { continuation.finish() }
    for waiter in waiters { waiter.resume() }
  }

  private func waitForCompletion() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let finished = lock.withLock { () -> Bool in
        if isFinished { return true }
        completionWaiters.append(continuation)
        return false
      }
      if finished { continuation.resume() }
    }
  }
}

/// Streams text and tool calls from a language model. Mirrors upstream `streamText`.
///
/// Takes the same options as `generateText`, plus stream-specific callbacks
/// and transforms. Returns immediately; generation runs in the background.
public func streamText<Value, Partial, Element>(
  model: LanguageModel,
  instructions: Instructions? = nil,
  prompt: Prompt,
  allowSystemInMessages: Bool = false,
  tools: ToolSet? = nil,
  toolChoice: ToolChoice? = nil,
  activeTools: [String]? = nil,
  toolOrder: [String]? = nil,
  output: Output<Value, Partial, Element>,
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  topP: Double? = nil,
  topK: Int? = nil,
  presencePenalty: Double? = nil,
  frequencyPenalty: Double? = nil,
  stopSequences: [String]? = nil,
  seed: Int? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil,
  stopWhen: [StopCondition] = [.isStepCount(1)],
  prepareStep: PrepareStepFunction? = nil,
  repairToolCall: ToolCallRepairFunction? = nil,
  toolApproval: ToolApprovalConfiguration? = nil,
  toolsContext: [String: JSONValue]? = nil,
  download: DownloadFunction? = nil,
  include: IncludeOptions = IncludeOptions(),
  includeRawChunks: Bool = false,
  transform: [StreamTextTransform] = [],
  generateId: IdGenerator? = nil,
  currentDate: @escaping @Sendable () -> Date = Date.init,
  onChunk: (@Sendable (TextStreamPart) async -> Void)? = nil,
  onError: (@Sendable (any Error) async -> Void)? = nil,
  onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
  onFinish: (@Sendable (GenerateTextResult<Value>) async -> Void)? = nil,
  onAbort: (@Sendable ([StepResult]) async -> Void)? = nil
) -> StreamTextResult<Value, Partial, Element> {
  let result = StreamTextResult(output: output)
  let (raw, rawContinuation) = AsyncThrowingStream<TextStreamPart, any Error>.makeStream()
  let transformed = transform.reduce(raw) { stream, transform in transform(stream) }

  let run = StreamTextRun(
    model: model, instructions: instructions, prompt: prompt, allowSystemInMessages: allowSystemInMessages,
    tools: tools, toolChoice: toolChoice, activeTools: activeTools, toolOrder: toolOrder,
    settings: CallSettings(
      maxOutputTokens: maxOutputTokens, temperature: temperature, topP: topP, topK: topK,
      presencePenalty: presencePenalty, frequencyPenalty: frequencyPenalty, stopSequences: stopSequences, seed: seed,
      reasoning: reasoning, maxRetries: maxRetries, headers: headers),
    providerOptions: providerOptions, stopWhen: stopWhen, prepareStep: prepareStep, repairToolCall: repairToolCall,
    toolApproval: toolApproval, toolsContext: toolsContext, download: download, include: include,
    includeRawChunks: includeRawChunks, generateId: generateId ?? defaultStreamGenerateId, currentDate: currentDate,
    onStepFinish: onStepFinish,
    responseFormat: output.name == "text" ? nil : output.responseFormat,
    onFinish: { steps, totalUsage, initialResponseMessages in
      let lastStep = steps[steps.count - 1]
      var parsed: Value?
      var parseError: (any Error)?
      if shouldParseOutput(lastStep) {
        do {
          parsed = try output.parseCompleteOutput(lastStep.text, context: OutputContext(lastStep))
        } catch {
          parseError = error
        }
      }
      result.recordOutput(parsed, error: parseError)
      await onFinish?(
        GenerateTextResult(
          steps: steps, totalUsage: totalUsage, initialResponseMessages: initialResponseMessages, output: parsed))
    },
    onAbort: onAbort,
    emit: { rawContinuation.yield($0) }, result: result)

  // The pump is not a child of the generation task, so cancelling generation
  // still delivers the trailing `.abort` part to subscribers.
  let pump = Task {
    do {
      for try await part in transformed {
        if part.isChunk { await onChunk?(part) }
        if case .error(let error) = part { await onError?(error) }
        result.broadcast(part)
      }
    } catch {
      result.broadcast(.error(error))
    }
  }
  let task = Task {
    await run.run()
    rawContinuation.finish()
    await pump.value
    result.finish()
  }
  result.setTask(task)
  return result
}

/// Streams text and tool calls from a language model. Mirrors upstream
/// `streamText` without an `output` setting.
public func streamText(
  model: LanguageModel,
  instructions: Instructions? = nil,
  prompt: Prompt,
  allowSystemInMessages: Bool = false,
  tools: ToolSet? = nil,
  toolChoice: ToolChoice? = nil,
  activeTools: [String]? = nil,
  toolOrder: [String]? = nil,
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  topP: Double? = nil,
  topK: Int? = nil,
  presencePenalty: Double? = nil,
  frequencyPenalty: Double? = nil,
  stopSequences: [String]? = nil,
  seed: Int? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil,
  stopWhen: [StopCondition] = [.isStepCount(1)],
  prepareStep: PrepareStepFunction? = nil,
  repairToolCall: ToolCallRepairFunction? = nil,
  toolApproval: ToolApprovalConfiguration? = nil,
  toolsContext: [String: JSONValue]? = nil,
  download: DownloadFunction? = nil,
  include: IncludeOptions = IncludeOptions(),
  includeRawChunks: Bool = false,
  transform: [StreamTextTransform] = [],
  generateId: IdGenerator? = nil,
  currentDate: @escaping @Sendable () -> Date = Date.init,
  onChunk: (@Sendable (TextStreamPart) async -> Void)? = nil,
  onError: (@Sendable (any Error) async -> Void)? = nil,
  onStepFinish: (@Sendable (StepResult) async -> Void)? = nil,
  onFinish: (@Sendable (GenerateTextResult<String>) async -> Void)? = nil,
  onAbort: (@Sendable ([StepResult]) async -> Void)? = nil
) -> StreamTextResult<String, String, NoElement> {
  streamText(
    model: model, instructions: instructions, prompt: prompt, allowSystemInMessages: allowSystemInMessages,
    tools: tools, toolChoice: toolChoice, activeTools: activeTools, toolOrder: toolOrder, output: .text(),
    maxOutputTokens: maxOutputTokens, temperature: temperature, topP: topP, topK: topK,
    presencePenalty: presencePenalty, frequencyPenalty: frequencyPenalty, stopSequences: stopSequences, seed: seed,
    reasoning: reasoning, maxRetries: maxRetries, headers: headers, providerOptions: providerOptions,
    stopWhen: stopWhen, prepareStep: prepareStep, repairToolCall: repairToolCall, toolApproval: toolApproval,
    toolsContext: toolsContext, download: download, include: include, includeRawChunks: includeRawChunks,
    transform: transform, generateId: generateId, currentDate: currentDate, onChunk: onChunk, onError: onError,
    onStepFinish: onStepFinish, onFinish: onFinish, onAbort: onAbort)
}

/// One `streamText` invocation.
private struct StreamTextRun: Sendable {
  let model: LanguageModel
  let instructions: Instructions?
  let prompt: Prompt
  let allowSystemInMessages: Bool
  let tools: ToolSet?
  let toolChoice: ToolChoice?
  let activeTools: [String]?
  let toolOrder: [String]?
  let settings: CallSettings
  let providerOptions: ProviderOptions?
  let stopWhen: [StopCondition]
  let prepareStep: PrepareStepFunction?
  let repairToolCall: ToolCallRepairFunction?
  let toolApproval: ToolApprovalConfiguration?
  let toolsContext: [String: JSONValue]?
  let download: DownloadFunction?
  let include: IncludeOptions
  let includeRawChunks: Bool
  let generateId: IdGenerator
  let currentDate: @Sendable () -> Date
  let onStepFinish: (@Sendable (StepResult) async -> Void)?
  let responseFormat: LanguageModelV4ResponseFormat?
  let onFinish: @Sendable ([StepResult], LanguageModelUsage, [ModelMessage]) async -> Void
  let onAbort: (@Sendable ([StepResult]) async -> Void)?
  let emit: @Sendable (TextStreamPart) -> Void
  let result: any StreamTextRecorder

  func run() async {
    emit(.start)
    var steps: [StepResult] = []
    do {
      let callSettings = try settings.validated()
      let retry = prepareRetries(maxRetries: callSettings.maxRetries)
      let initialPrompt = try standardizePrompt(
        instructions: instructions, prompt: prompt, allowSystemInMessages: allowSystemInMessages)
      let initialMessages = initialPrompt.messages
      var toolsContext = toolsContext

      let initialResponseMessages = try await processInitialApprovals(messages: initialMessages)
      result.setInitialResponseMessages(initialResponseMessages)

      var instructionsForNextStep = initialPrompt.instructions
      var messagesForNextStep = initialMessages + initialResponseMessages

      while true {
        if !steps.isEmpty { try Task.checkCancellation() }

        let prepared = try await prepareStep?(
          PrepareStepOptions(
            steps: steps, stepNumber: steps.count, model: model, instructions: instructionsForNextStep,
            initialInstructions: initialPrompt.instructions, messages: messagesForNextStep,
            initialMessages: initialMessages,
            responseMessages: initialResponseMessages + steps.flatMap(\.response.messages),
            toolsContext: toolsContext))

        let stepModel = prepared?.model ?? model
        let stepInstructions = prepared?.instructions ?? instructionsForNextStep
        toolsContext = prepared?.toolsContext ?? toolsContext
        let stepTools = tools?.filtered(to: prepared?.activeTools ?? activeTools)
        let stepMessages = prepared?.messages ?? messagesForNextStep

        let promptMessages = try await convertToLanguageModelPrompt(
          prompt: StandardizedPrompt(instructions: stepInstructions, messages: stepMessages),
          supportedUrls: try await stepModel.supportedUrls, download: download)

        var callOptions = (prepared?.apply(to: callSettings) ?? callSettings).callOptions(prompt: promptMessages)
        callOptions.tools = prepareTools(stepTools, toolOrder: prepared?.toolOrder ?? toolOrder)
        callOptions.toolChoice = (prepared?.toolChoice ?? toolChoice ?? .auto).languageModelToolChoice
        callOptions.providerOptions = mergeProviderOptions(providerOptions, prepared?.providerOptions)
        callOptions.includeRawChunks = includeRawChunks
        callOptions.responseFormat = responseFormat
        let stepCallOptions = callOptions

        let modelStream = try await retry { try await stepModel.doStream(stepCallOptions) }
        let outcome = try await runStep(
          stepNumber: steps.count, stepModel: stepModel, modelStream: modelStream, stepTools: stepTools,
          stepInstructions: stepInstructions, stepMessages: stepMessages, toolsContext: toolsContext)

        steps.append(outcome.step)
        result.appendStep(outcome.step)
        instructionsForNextStep = stepInstructions
        messagesForNextStep = stepMessages + outcome.step.response.messages
        await onStepFinish?(outcome.step)

        let allToolCallsResolved = outcome.clientToolOutputCount + outcome.deniedCount == outcome.clientToolCallCount
        let hasPendingWork = outcome.clientToolCallCount > 0 || outcome.hasPendingDeferredResults
        guard allToolCallsResolved, hasPendingWork, !(await isStopConditionMet(stopWhen, steps: steps)) else {
          break
        }
      }

      let totalUsage = steps.reduce(LanguageModelUsage()) { $0 + $1.usage }
      let lastStep = steps[steps.count - 1]
      emit(.finish(finishReason: lastStep.finishReason, rawFinishReason: lastStep.rawFinishReason, totalUsage: totalUsage))
      await onFinish(steps, totalUsage, initialResponseMessages)
    } catch let error where isCancellationError(error) || Task.isCancelled {
      emit(.abort(reason: nil))
      await onAbort?(steps)
    } catch {
      result.recordError(error)
      emit(.error(error))
    }
  }

  /// Executes tool calls approved or denied in the incoming messages.
  private func processInitialApprovals(messages: [ModelMessage]) async throws -> [ModelMessage] {
    let approvals = try collectToolApprovals(messages: messages)
    let approved = approvals.approved.filter { $0.toolCall.providerExecuted != true }
    let denied = approvals.denied.filter { $0.existingToolResult == nil }
    guard !approved.isEmpty || !denied.isEmpty else { return [] }

    var toolContent: [ToolContentPart] = []
    for output in try await executeTools(
      approved.map(\.toolCall), tools: tools, messages: messages, toolsContext: toolsContext)
    {
      switch output {
      case .result(let toolResult):
        emit(.toolResult(toolResult))
        toolContent.append(
          .toolResult(
            ToolResultPart(
              toolCallId: toolResult.toolCallId, toolName: toolResult.toolName,
              output: try await createToolModelOutput(
                toolCallId: toolResult.toolCallId, input: toolResult.input, output: toolResult.output,
                tool: tools?[toolResult.toolName], errorMode: .none))))
      case .error(let toolError):
        emit(.toolError(toolError))
        toolContent.append(
          .toolResult(
            ToolResultPart(
              toolCallId: toolError.toolCallId, toolName: toolError.toolName,
              output: .errorText(getErrorMessage(toolError.error)))))
      }
    }
    for approval in denied {
      emit(.toolOutputDenied(toolCallId: approval.toolCall.toolCallId, toolName: approval.toolCall.toolName))
      toolContent.append(
        .toolResult(
          ToolResultPart(
            toolCallId: approval.toolCall.toolCallId, toolName: approval.toolCall.toolName,
            output: .executionDenied(reason: approval.approvalResponse.reason))))
    }
    return [.tool(toolContent)]
  }

  private struct StepOutcome {
    var step: StepResult
    var clientToolCallCount: Int
    var clientToolOutputCount: Int
    var deniedCount: Int
    var hasPendingDeferredResults: Bool
  }

  private func runStep(
    stepNumber: Int,
    stepModel: LanguageModel,
    modelStream: LanguageModelV4StreamResult,
    stepTools: ToolSet?,
    stepInstructions: Instructions?,
    stepMessages: [ModelMessage],
    toolsContext: [String: JSONValue]?
  ) async throws -> StepOutcome {
    var recorder = ContentRecorder()
    var warnings: [Warning] = []
    var didStartStep = false
    var responseId: String?
    var responseTimestamp: Date?
    var responseModelId: String?
    var usage = LanguageModelV4Usage()
    var finishReason = LanguageModelV4FinishReason(unified: .other)
    var providerMetadata: ProviderMetadata?
    var stepToolCalls: [ToolCall] = []
    var toolCallsToExecute: [ToolCall] = []
    var clientToolOutputCount = 0
    var deniedCount = 0
    var pendingDeferred = Set<String>()
    var toolInputNames: [String: String] = [:]

    let request = LanguageModelRequestMetadata(
      body: include.requestBody ? modelStream.request?.body : nil,
      messages: include.requestMessages ? stepMessages : nil)

    func startStepIfNeeded() {
      guard !didStartStep else { return }
      didStartStep = true
      emit(.startStep(request: request, warnings: warnings))
    }

    func record(_ part: TextStreamPart, _ content: ContentPart? = nil) {
      emit(part)
      if let content { recorder.content.append(content) }
    }

    func executionOptions(_ toolCallId: String, _ toolName: String) -> ToolExecutionOptions {
      ToolExecutionOptions(toolCallId: toolCallId, messages: stepMessages, context: toolsContext?[toolName])
    }

    for try await part in modelStream.stream {
      if case .streamStart(let streamWarnings) = part {
        warnings = streamWarnings
        startStepIfNeeded()
        continue
      }
      startStepIfNeeded()

      switch part {
      case .streamStart:
        break
      case .responseMetadata(let metadata):
        responseId = metadata.id ?? responseId
        responseTimestamp = metadata.timestamp ?? responseTimestamp
        responseModelId = metadata.modelId ?? responseModelId
      case .textStart(let id, let metadata):
        recorder.startText(id: id, providerMetadata: metadata)
        emit(.textStart(id: id, providerMetadata: metadata))
      case .textDelta(let id, let delta, let metadata):
        if !delta.isEmpty || metadata != nil {
          recorder.appendText(id: id, delta: delta, providerMetadata: metadata)
          emit(.textDelta(id: id, text: delta, providerMetadata: metadata))
        }
      case .textEnd(let id, let metadata):
        recorder.endText(id: id, providerMetadata: metadata)
        emit(.textEnd(id: id, providerMetadata: metadata))
      case .reasoningStart(let id, let metadata):
        recorder.startReasoning(id: id, providerMetadata: metadata)
        emit(.reasoningStart(id: id, providerMetadata: metadata))
      case .reasoningDelta(let id, let delta, let metadata):
        recorder.appendReasoning(id: id, delta: delta, providerMetadata: metadata)
        emit(.reasoningDelta(id: id, text: delta, providerMetadata: metadata))
      case .reasoningEnd(let id, let metadata):
        recorder.endReasoning(id: id, providerMetadata: metadata)
        emit(.reasoningEnd(id: id, providerMetadata: metadata))
      case .toolInputStart(let start):
        let tool = stepTools?[start.toolName]
        toolInputNames[start.id] = start.toolName
        emit(
          .toolInputStart(
            ToolInputStart(
              id: start.id, toolName: start.toolName, providerMetadata: start.providerMetadata,
              toolMetadata: tool?.metadata, providerExecuted: start.providerExecuted,
              dynamic: start.dynamic ?? (tool?.isDynamic == true ? true : nil), title: start.title ?? tool?.title)))
        await tool?.onInputStart?(executionOptions(start.id, start.toolName))
      case .toolInputDelta(let id, let delta, let metadata):
        emit(.toolInputDelta(id: id, delta: delta, providerMetadata: metadata))
        if let name = toolInputNames[id] {
          await stepTools?[name]?.onInputDelta?(delta, executionOptions(id, name))
        }
      case .toolInputEnd(let id, let metadata):
        emit(.toolInputEnd(id: id, providerMetadata: metadata))
      case .toolCall(let rawCall):
        let call = try await parseToolCall(
          rawCall, tools: stepTools, repairToolCall: repairToolCall, instructions: stepInstructions,
          messages: stepMessages)
        stepToolCalls.append(call)
        record(.toolCall(call), .toolCall(call))

        if call.invalid {
          if call.dynamic && call.providerExecuted != true {
            let toolError = ToolError(
              toolCallId: call.toolCallId, toolName: call.toolName, input: call.input,
              error: call.error ?? NoOutputGeneratedError(), dynamic: true)
            record(.toolError(toolError), .toolError(toolError))
            clientToolOutputCount += 1
          }
          continue
        }
        guard let tool = stepTools?[call.toolName] else { continue }
        await tool.onInputAvailable?(call.input, executionOptions(call.toolCallId, call.toolName))

        if call.providerExecuted == true, tool.providerToolInfo?.supportsDeferredResults == true {
          pendingDeferred.insert(call.toolCallId)
        }

        let status = try await resolveToolApproval(
          toolCall: call, tools: stepTools, configuration: toolApproval, messages: stepMessages,
          toolsContext: toolsContext)
        let shouldExecute = tool.isExecutable && call.providerExecuted != true
        switch status {
        case .notApplicable:
          if shouldExecute { toolCallsToExecute.append(call) }
        case .userApproval(let reason):
          let request = ToolApprovalRequestOutput(approvalId: generateId(), toolCall: call, reason: reason)
          record(.toolApprovalRequest(request), .toolApprovalRequest(request))
        case .denied(let reason):
          let approvalId = generateId()
          let request = ToolApprovalRequestOutput(approvalId: approvalId, toolCall: call, isAutomatic: true)
          let response = ToolApprovalResponseOutput(
            approvalId: approvalId, toolCall: call, approved: false, reason: reason,
            providerExecuted: call.providerExecuted)
          record(.toolApprovalRequest(request), .toolApprovalRequest(request))
          record(.toolApprovalResponse(response), .toolApprovalResponse(response))
          emit(.toolOutputDenied(toolCallId: call.toolCallId, toolName: call.toolName))
          if call.providerExecuted != true { deniedCount += 1 }
        case .approved(let reason):
          let approvalId = generateId()
          let request = ToolApprovalRequestOutput(approvalId: approvalId, toolCall: call, isAutomatic: true)
          let response = ToolApprovalResponseOutput(
            approvalId: approvalId, toolCall: call, approved: true, reason: reason,
            providerExecuted: call.providerExecuted)
          record(.toolApprovalRequest(request), .toolApprovalRequest(request))
          record(.toolApprovalResponse(response), .toolApprovalResponse(response))
          if shouldExecute { toolCallsToExecute.append(call) }
        }
      case .toolResult(let providerResult):
        pendingDeferred.remove(providerResult.toolCallId)
        let call = stepToolCalls.first { $0.toolCallId == providerResult.toolCallId }
        let dynamic = providerResult.dynamic ?? call?.dynamic ?? false
        if providerResult.isError == true {
          let toolError = ToolError(
            toolCallId: providerResult.toolCallId, toolName: providerResult.toolName, input: call?.input ?? .null,
            error: ProviderToolError(value: providerResult.result), providerExecuted: true, dynamic: dynamic,
            providerMetadata: providerResult.providerMetadata)
          record(.toolError(toolError), .toolError(toolError))
        } else {
          let toolResult = ToolResult(
            toolCallId: providerResult.toolCallId, toolName: providerResult.toolName, input: call?.input ?? .null,
            output: providerResult.result, providerExecuted: true, dynamic: dynamic,
            preliminary: providerResult.preliminary ?? false, providerMetadata: providerResult.providerMetadata)
          record(.toolResult(toolResult), toolResult.preliminary ? nil : .toolResult(toolResult))
        }
      case .toolApprovalRequest(let providerRequest):
        if let call = stepToolCalls.first(where: { $0.toolCallId == providerRequest.toolCallId }) {
          let request = ToolApprovalRequestOutput(approvalId: providerRequest.approvalId, toolCall: call)
          record(.toolApprovalRequest(request), .toolApprovalRequest(request))
        }
      case .custom(let custom):
        record(
          .custom(kind: custom.kind, providerMetadata: custom.providerMetadata),
          .custom(kind: custom.kind, providerMetadata: custom.providerMetadata))
      case .source(let source):
        record(.source(source), .source(source))
      case .file(let file):
        let generated = GeneratedFile(data: file.data.generatedBytes(), mediaType: file.mediaType)
        record(
          .file(generated, providerMetadata: file.providerMetadata),
          .file(generated, providerMetadata: file.providerMetadata))
      case .reasoningFile(let file):
        let generated = GeneratedFile(data: file.data.generatedBytes(), mediaType: file.mediaType)
        record(
          .reasoningFile(generated, providerMetadata: file.providerMetadata),
          .reasoningFile(generated, providerMetadata: file.providerMetadata))
      case .raw(let value):
        if includeRawChunks { emit(.raw(value)) }
      case .finish(let finishUsage, let reason, let metadata):
        usage = finishUsage
        finishReason = reason
        providerMetadata = metadata
      case .error(let error):
        emit(.error(error))
      }
    }
    // Stream iteration ends silently on cancellation instead of throwing.
    try Task.checkCancellation()
    startStepIfNeeded()

    let clientToolCallCount = stepToolCalls.filter { $0.providerExecuted != true }.count
    if isToolExecutionAllowed(finishReason.unified) && !toolCallsToExecute.isEmpty {
      let emit = emit
      try await withThrowingTaskGroup(of: ToolOutput?.self) { group in
        for call in toolCallsToExecute {
          group.addTask {
            try await executeToolCall(
              call, tools: stepTools, messages: stepMessages, toolsContext: toolsContext,
              onPreliminaryToolResult: { emit(.toolResult($0)) })
          }
        }
        for try await output in group {
          switch output {
          case .result(let toolResult):
            record(.toolResult(toolResult), .toolResult(toolResult))
            clientToolOutputCount += 1
          case .error(let toolError):
            record(.toolError(toolError), .toolError(toolError))
            clientToolOutputCount += 1
          case nil:
            break
          }
        }
      }
    }

    let response = LanguageModelResponseMetadata(
      id: responseId ?? generateId(),
      timestamp: responseTimestamp ?? currentDate(),
      modelId: responseModelId ?? stepModel.modelId,
      headers: modelStream.responseHeaders)
    let stepUsage = LanguageModelUsage(usage)
    emit(
      .finishStep(
        response: response, usage: stepUsage, finishReason: finishReason.unified, rawFinishReason: finishReason.raw,
        providerMetadata: providerMetadata))

    var stepResponse = response
    stepResponse.messages = try await toResponseMessages(content: recorder.content, tools: tools)
    let step = StepResult(
      stepNumber: stepNumber, provider: stepModel.provider, modelId: stepModel.modelId, content: recorder.content,
      finishReason: finishReason.unified, rawFinishReason: finishReason.raw, usage: stepUsage, warnings: warnings,
      request: request, response: stepResponse, providerMetadata: providerMetadata)

    return StepOutcome(
      step: step, clientToolCallCount: clientToolCallCount, clientToolOutputCount: clientToolOutputCount,
      deniedCount: deniedCount, hasPendingDeferredResults: !pendingDeferred.isEmpty)
  }
}

/// Accumulates streamed parts into step content, merging text and reasoning
/// deltas into their blocks.
private struct ContentRecorder {
  var content: [ContentPart] = []
  private var activeText: [String: Int] = [:]
  private var activeReasoning: [String: Int] = [:]

  mutating func startText(id: String, providerMetadata: ProviderMetadata?) {
    activeText[id] = content.count
    content.append(.text("", providerMetadata: providerMetadata))
  }

  mutating func appendText(id: String, delta: String, providerMetadata: ProviderMetadata?) {
    if activeText[id] == nil { startText(id: id, providerMetadata: nil) }
    guard let index = activeText[id], case .text(let text, let metadata) = content[index] else { return }
    content[index] = .text(text + delta, providerMetadata: providerMetadata ?? metadata)
  }

  mutating func endText(id: String, providerMetadata: ProviderMetadata?) {
    if let index = activeText[id], case .text(let text, let metadata) = content[index] {
      content[index] = .text(text, providerMetadata: providerMetadata ?? metadata)
    }
    activeText.removeValue(forKey: id)
  }

  mutating func startReasoning(id: String, providerMetadata: ProviderMetadata?) {
    activeReasoning[id] = content.count
    content.append(.reasoning(ReasoningOutput(text: "", providerMetadata: providerMetadata)))
  }

  mutating func appendReasoning(id: String, delta: String, providerMetadata: ProviderMetadata?) {
    if activeReasoning[id] == nil { startReasoning(id: id, providerMetadata: nil) }
    guard let index = activeReasoning[id], case .reasoning(var reasoning) = content[index] else { return }
    reasoning.text += delta
    reasoning.providerMetadata = providerMetadata ?? reasoning.providerMetadata
    content[index] = .reasoning(reasoning)
  }

  mutating func endReasoning(id: String, providerMetadata: ProviderMetadata?) {
    if let index = activeReasoning[id], case .reasoning(var reasoning) = content[index] {
      reasoning.providerMetadata = providerMetadata ?? reasoning.providerMetadata
      content[index] = .reasoning(reasoning)
    }
    activeReasoning.removeValue(forKey: id)
  }
}

/// What a running `streamText` call records into its result.
protocol StreamTextRecorder: AnyObject, Sendable {
  func appendStep(_ step: StepResult)
  func setInitialResponseMessages(_ messages: [ModelMessage])
  func recordError(_ error: any Error)
}
