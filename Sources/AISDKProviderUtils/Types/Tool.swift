import Foundation

/// Options passed to a tool's `execute` function. Mirrors upstream `ToolExecutionOptions`.
///
/// Upstream's `abortSignal` is replaced by task cancellation.
public struct ToolExecutionOptions: Sendable {
  /// The ID of the tool call.
  public var toolCallId: String
  /// The messages sent to the model in the step that produced the tool call.
  public var messages: [ModelMessage]
  /// The tool context supplied through `toolsContext`.
  public var context: JSONValue?

  public init(toolCallId: String, messages: [ModelMessage], context: JSONValue? = nil) {
    self.toolCallId = toolCallId
    self.messages = messages
    self.context = context
  }
}

/// Options passed to `Tool.toModelOutput`.
public struct ToolModelOutputOptions: Sendable {
  public var toolCallId: String
  public var input: JSONValue
  public var output: JSONValue

  public init(toolCallId: String, input: JSONValue, output: JSONValue) {
    self.toolCallId = toolCallId
    self.input = input
    self.output = output
  }
}

/// A tool the model can call. Mirrors upstream `Tool`.
///
/// Tools are type-erased to JSON so they can live in one `ToolSet`. Use
/// `tool(description:inputSchema:execute:)` to define a typed tool.
public struct Tool: Sendable {
  /// The kind of tool. Mirrors the upstream `type` discriminator.
  public enum Kind: Sendable, Equatable {
    /// A tool defined in code and executed by the SDK.
    case function
    /// A tool whose types are only known at runtime, e.g. an MCP tool.
    case dynamic
    /// A tool whose schema the provider defines. Executed by the provider when
    /// `isProviderExecuted` is true, otherwise by the SDK.
    case provider(id: String, args: JSONObject, isProviderExecuted: Bool, supportsDeferredResults: Bool = false)
  }

  public typealias Execute = @Sendable (JSONValue, ToolExecutionOptions) async throws -> JSONValue
  public typealias ExecuteStreaming =
    @Sendable (JSONValue, ToolExecutionOptions) -> AsyncThrowingStream<JSONValue, any Error>
  public typealias NeedsApproval = @Sendable (JSONValue, ToolExecutionOptions) async throws -> Bool

  public var kind: Kind
  /// Helps the model decide when to use the tool.
  public var description: String?
  public var title: String?
  /// Validates model-generated input and describes it to the model.
  public var inputSchema: Schema<JSONValue>
  /// Describes the output, for tools without `execute`.
  public var outputSchema: JSONSchema?
  public var strict: Bool?
  public var inputExamples: [JSONObject]?
  /// Sent to the provider with the tool definition.
  public var providerOptions: ProviderOptions?
  /// Metadata about the tool (e.g. its source), propagated to tool calls but
  /// not sent to the model.
  public var metadata: JSONObject?
  /// Whether a call to this tool needs user approval before it runs.
  public var needsApproval: NeedsApproval?
  /// Runs the tool. When `nil`, tool calls are returned to the caller instead.
  public var execute: Execute?
  /// Runs the tool, yielding preliminary outputs. The last element is the final output.
  public var executeStreaming: ExecuteStreaming?
  public var onInputStart: (@Sendable (ToolExecutionOptions) async -> Void)?
  public var onInputDelta: (@Sendable (String, ToolExecutionOptions) async -> Void)?
  public var onInputAvailable: (@Sendable (JSONValue, ToolExecutionOptions) async -> Void)?
  /// Maps the tool output to what is sent to the model. Defaults to text for
  /// string outputs and JSON otherwise.
  public var toModelOutput: (@Sendable (ToolModelOutputOptions) async throws -> ToolResultOutput)?

  public init(
    kind: Kind = .function,
    description: String? = nil,
    title: String? = nil,
    inputSchema: Schema<JSONValue>,
    outputSchema: JSONSchema? = nil,
    strict: Bool? = nil,
    inputExamples: [JSONObject]? = nil,
    providerOptions: ProviderOptions? = nil,
    metadata: JSONObject? = nil,
    needsApproval: NeedsApproval? = nil,
    execute: Execute? = nil,
    executeStreaming: ExecuteStreaming? = nil,
    onInputStart: (@Sendable (ToolExecutionOptions) async -> Void)? = nil,
    onInputDelta: (@Sendable (String, ToolExecutionOptions) async -> Void)? = nil,
    onInputAvailable: (@Sendable (JSONValue, ToolExecutionOptions) async -> Void)? = nil,
    toModelOutput: (@Sendable (ToolModelOutputOptions) async throws -> ToolResultOutput)? = nil
  ) {
    self.kind = kind
    self.description = description
    self.title = title
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.strict = strict
    self.inputExamples = inputExamples
    self.providerOptions = providerOptions
    self.metadata = metadata
    self.needsApproval = needsApproval
    self.execute = execute
    self.executeStreaming = executeStreaming
    self.onInputStart = onInputStart
    self.onInputDelta = onInputDelta
    self.onInputAvailable = onInputAvailable
    self.toModelOutput = toModelOutput
  }

  /// Whether the SDK can execute the tool.
  public var isExecutable: Bool { execute != nil || executeStreaming != nil }

  public var isDynamic: Bool { kind == .dynamic }

  public var providerToolInfo: (id: String, args: JSONObject, isProviderExecuted: Bool, supportsDeferredResults: Bool)? {
    if case .provider(let id, let args, let isProviderExecuted, let supportsDeferredResults) = kind {
      return (id, args, isProviderExecuted, supportsDeferredResults)
    }
    return nil
  }
}

// MARK: - Factories

/// Defines a typed tool. Mirrors upstream `tool()`.
///
/// Input is validated and decoded with `inputSchema`; the output is encoded to JSON.
public func tool<Input: Sendable, Output: Encodable & Sendable>(
  description: String? = nil,
  title: String? = nil,
  inputSchema: Schema<Input>,
  strict: Bool? = nil,
  inputExamples: [JSONObject]? = nil,
  providerOptions: ProviderOptions? = nil,
  needsApproval: Bool = false,
  execute: @escaping @Sendable (Input, ToolExecutionOptions) async throws -> Output
) -> Tool {
  Tool(
    kind: .function,
    description: description,
    title: title,
    inputSchema: erase(inputSchema),
    strict: strict,
    inputExamples: inputExamples,
    providerOptions: providerOptions,
    needsApproval: needsApproval ? { @Sendable _, _ in true } : nil,
    execute: { input, options in
      let typedInput = try inputSchema.validate(input)
      return try JSONValue(encoding: try await execute(typedInput, options))
    })
}

/// Defines a typed tool without an `execute` function. Calls to it are returned
/// to the caller, e.g. for client-side or human-in-the-loop tools.
public func tool<Input: Sendable>(
  description: String? = nil,
  title: String? = nil,
  inputSchema: Schema<Input>,
  outputSchema: JSONSchema? = nil,
  strict: Bool? = nil,
  providerOptions: ProviderOptions? = nil
) -> Tool {
  Tool(
    kind: .function,
    description: description,
    title: title,
    inputSchema: erase(inputSchema),
    outputSchema: outputSchema,
    strict: strict,
    providerOptions: providerOptions)
}

/// Defines a typed tool that streams preliminary outputs. The last yielded
/// value is the final output.
public func streamingTool<Input: Sendable, Output: Encodable & Sendable>(
  description: String? = nil,
  inputSchema: Schema<Input>,
  execute: @escaping @Sendable (Input, ToolExecutionOptions) -> AsyncThrowingStream<Output, any Error>
) -> Tool {
  Tool(
    kind: .function,
    description: description,
    inputSchema: erase(inputSchema),
    executeStreaming: { input, options in
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            let typedInput = try inputSchema.validate(input)
            for try await output in execute(typedInput, options) {
              continuation.yield(try JSONValue(encoding: output))
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
      }
    })
}

/// Defines a tool whose input and output types are only known at runtime.
/// Mirrors upstream `dynamicTool()`.
public func dynamicTool(
  description: String? = nil,
  title: String? = nil,
  inputSchema: JSONSchema,
  metadata: JSONObject? = nil,
  execute: Tool.Execute? = nil
) -> Tool {
  Tool(
    kind: .dynamic,
    description: description,
    title: title,
    inputSchema: jsonSchema(inputSchema),
    metadata: metadata,
    execute: execute)
}

/// Defines a provider tool. Mirrors upstream provider tool factories.
public func providerTool(
  id: String,
  args: JSONObject = [:],
  inputSchema: JSONSchema = ["type": "object"],
  isProviderExecuted: Bool,
  supportsDeferredResults: Bool = false,
  execute: Tool.Execute? = nil
) -> Tool {
  Tool(
    kind: .provider(
      id: id, args: args, isProviderExecuted: isProviderExecuted, supportsDeferredResults: supportsDeferredResults),
    inputSchema: jsonSchema(inputSchema),
    execute: execute)
}

private func erase<Input>(_ schema: Schema<Input>) -> Schema<JSONValue> {
  Schema(jsonSchema: schema.jsonSchema) { value in
    _ = try schema.validate(value)
    return value
  }
}

// MARK: - ToolSet

/// Named tools, in declaration order. Mirrors upstream `ToolSet`.
///
/// Order matters because tools are sent to the model in this order.
public struct ToolSet: Sendable, ExpressibleByDictionaryLiteral, Sequence {
  public private(set) var names: [String] = []
  private var storage: [String: Tool] = [:]

  public init() {}

  public init(dictionaryLiteral elements: (String, Tool)...) {
    for (name, tool) in elements {
      self[name] = tool
    }
  }

  public init(_ elements: [(String, Tool)]) {
    for (name, tool) in elements {
      self[name] = tool
    }
  }

  public subscript(name: String) -> Tool? {
    get { storage[name] }
    set {
      if let newValue {
        if storage[name] == nil { names.append(name) }
        storage[name] = newValue
      } else if storage.removeValue(forKey: name) != nil {
        names.removeAll { $0 == name }
      }
    }
  }

  public var isEmpty: Bool { names.isEmpty }
  public var count: Int { names.count }

  public func makeIterator() -> AnyIterator<(name: String, tool: Tool)> {
    var index = 0
    return AnyIterator {
      guard index < names.count else { return nil }
      defer { index += 1 }
      return (names[index], storage[names[index]]!)
    }
  }

  /// A tool set restricted to the given names, in the original order.
  public func filtered(to activeTools: [String]?) -> ToolSet {
    guard let activeTools else { return self }
    return ToolSet(filter { activeTools.contains($0.name) }.map { ($0.name, $0.tool) })
  }

  /// Merges two tool sets; tools in `other` replace tools with the same name.
  public func merging(_ other: ToolSet) -> ToolSet {
    var merged = self
    for (name, tool) in other {
      merged[name] = tool
    }
    return merged
  }
}
