import Foundation

/// Repairs model text that failed to parse or validate. Return `nil` to give
/// up. Mirrors upstream `RepairTextFunction`.
public typealias RepairTextFunction = @Sendable (_ text: String, _ error: NoObjectGeneratedError) async throws -> String?

/// The result of `generateObject`. Mirrors upstream `GenerateObjectResult`.
public struct GenerateObjectResult<Object: Sendable>: Sendable {
  /// The generated object, validated against the schema.
  public let object: Object
  public let reasoningText: String?
  public let finishReason: FinishReason
  public let usage: LanguageModelUsage
  public let warnings: [Warning]
  public let request: LanguageModelRequestMetadata
  public let response: LanguageModelResponseMetadata
  public let providerMetadata: ProviderMetadata?
}

/// Generates a structured value for an `Output`. Mirrors upstream
/// `generateObject`, which upstream now implements as `generateText` with an
/// `output` setting.
public func generateObject<Value, Partial, Element>(
  model: LanguageModel,
  output: Output<Value, Partial, Element>,
  instructions: Instructions? = nil,
  prompt: Prompt,
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  topP: Double? = nil,
  topK: Int? = nil,
  seed: Int? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil,
  repairText: RepairTextFunction? = nil
) async throws -> GenerateObjectResult<Value> {
  let rawOutput = Output<String, String, NoElement>(
    name: output.name, responseFormat: output.responseFormat, parseComplete: { text, _ in text }, parsePartial: { $0 })
  let result = try await generateText(
    model: model, instructions: instructions, prompt: prompt, output: rawOutput, maxOutputTokens: maxOutputTokens,
    temperature: temperature, topP: topP, topK: topK, seed: seed, reasoning: reasoning, maxRetries: maxRetries,
    headers: headers, providerOptions: providerOptions)

  let step = result.finalStep
  let context = OutputContext(step)
  let object: Value
  do {
    object = try output.parseCompleteOutput(step.text, context: context)
  } catch let error as NoObjectGeneratedError {
    guard let repairText, let repaired = try await repairText(step.text, error) else { throw error }
    object = try output.parseCompleteOutput(repaired, context: context)
  }

  return GenerateObjectResult(
    object: object, reasoningText: step.reasoningText, finishReason: step.finishReason, usage: result.totalUsage,
    warnings: result.warnings, request: step.request, response: step.response, providerMetadata: step.providerMetadata)
}

/// Generates an object matching a schema. Mirrors upstream
/// `generateObject({ schema })`.
public func generateObject<Object: Sendable>(
  model: LanguageModel,
  schema: Schema<Object>,
  schemaName: String? = nil,
  schemaDescription: String? = nil,
  instructions: Instructions? = nil,
  prompt: Prompt,
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  maxRetries: Int = 2,
  providerOptions: ProviderOptions? = nil,
  repairText: RepairTextFunction? = nil
) async throws -> GenerateObjectResult<Object> {
  try await generateObject(
    model: model, output: .object(schema: schema, name: schemaName, description: schemaDescription),
    instructions: instructions, prompt: prompt, maxOutputTokens: maxOutputTokens, temperature: temperature,
    reasoning: reasoning, maxRetries: maxRetries, providerOptions: providerOptions, repairText: repairText)
}

/// The result of `streamObject`. Mirrors upstream `StreamObjectResult`.
public final class StreamObjectResult<Object: Sendable, Partial: Sendable & Equatable, Element: Sendable>: Sendable {
  let base: StreamTextResult<Object, Partial, Element>

  init(base: StreamTextResult<Object, Partial, Element>) {
    self.base = base
  }

  /// Partial objects, emitted whenever they change.
  public var partialObjectStream: AsyncThrowingStream<Partial, any Error> { base.partialOutputStream }
  /// Complete array elements, for array outputs.
  public var elementStream: AsyncThrowingStream<Element, any Error> { base.elementStream }
  /// The raw JSON text deltas.
  public var textStream: AsyncThrowingStream<String, any Error> { base.textStream }
  /// Every stream part, including errors.
  public var fullStream: AsyncThrowingStream<TextStreamPart, any Error> { base.fullStream }

  /// The final object, validated against the schema.
  public var object: Object { get async throws { try await base.output } }
  public var finishReason: FinishReason { get async throws { try await base.finishReason } }
  public var usage: LanguageModelUsage { get async throws { try await base.totalUsage } }
  public var warnings: [Warning] { get async throws { try await base.warnings } }
  public var request: LanguageModelRequestMetadata { get async throws { try await base.request } }
  public var response: LanguageModelResponseMetadata { get async throws { try await base.response } }
  public var providerMetadata: ProviderMetadata? { get async throws { try await base.providerMetadata } }

  public func cancel() { base.cancel() }
}

/// Streams a structured value for an `Output`. Mirrors upstream `streamObject`.
public func streamObject<Value, Partial, Element>(
  model: LanguageModel,
  output: Output<Value, Partial, Element>,
  instructions: Instructions? = nil,
  prompt: Prompt,
  maxOutputTokens: Int? = nil,
  temperature: Double? = nil,
  topP: Double? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  maxRetries: Int = 2,
  headers: [String: String]? = nil,
  providerOptions: ProviderOptions? = nil,
  onError: (@Sendable (any Error) async -> Void)? = nil
) -> StreamObjectResult<Value, Partial, Element> {
  StreamObjectResult(
    base: streamText(
      model: model, instructions: instructions, prompt: prompt, output: output, maxOutputTokens: maxOutputTokens,
      temperature: temperature, topP: topP, reasoning: reasoning, maxRetries: maxRetries, headers: headers,
      providerOptions: providerOptions, onError: onError))
}

/// Streams an object matching a schema. Mirrors upstream `streamObject({ schema })`.
public func streamObject<Object: Sendable>(
  model: LanguageModel,
  schema: Schema<Object>,
  schemaName: String? = nil,
  schemaDescription: String? = nil,
  instructions: Instructions? = nil,
  prompt: Prompt,
  maxOutputTokens: Int? = nil,
  reasoning: LanguageModelV4ReasoningEffort? = nil,
  providerOptions: ProviderOptions? = nil
) -> StreamObjectResult<Object, JSONValue, NoElement> {
  streamObject(
    model: model, output: .object(schema: schema, name: schemaName, description: schemaDescription),
    instructions: instructions, prompt: prompt, maxOutputTokens: maxOutputTokens, reasoning: reasoning,
    providerOptions: providerOptions)
}
