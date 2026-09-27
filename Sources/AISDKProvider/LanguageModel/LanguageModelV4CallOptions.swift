/// Options for a language model call. Mirrors upstream `LanguageModelV4CallOptions`.
///
/// Upstream's `abortSignal` is replaced by structured `Task` cancellation.
public struct LanguageModelV4CallOptions: Sendable, Equatable {
  /// The standardized prompt. This is not the user-facing prompt.
  public var prompt: LanguageModelV4Prompt
  /// Maximum number of tokens to generate.
  public var maxOutputTokens: Int?
  /// Temperature setting. The range depends on the provider and model.
  public var temperature: Double?
  /// Stop sequences.
  public var stopSequences: [String]?
  /// Nucleus sampling.
  public var topP: Double?
  /// Only sample from the top K options for each subsequent token.
  public var topK: Int?
  /// Affects the likelihood of the model repeating information already in the prompt.
  public var presencePenalty: Double?
  /// Affects the likelihood of the model repeating the same words or phrases.
  public var frequencyPenalty: Double?
  /// Response format. Default is text.
  public var responseFormat: LanguageModelV4ResponseFormat?
  /// The seed for random sampling.
  public var seed: Int?
  /// The tools available to the model.
  public var tools: [LanguageModelV4Tool]?
  /// How the tool should be selected. Defaults to `.auto`.
  public var toolChoice: LanguageModelV4ToolChoice?
  /// Include raw chunks in the stream. Only applicable for streaming calls.
  public var includeRawChunks: Bool?
  /// Additional HTTP headers. Only applicable for HTTP-based providers.
  public var headers: [String: String]?
  /// Reasoning effort level. Defaults to `.providerDefault`.
  public var reasoning: LanguageModelV4ReasoningEffort?
  /// Provider-specific options.
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    prompt: LanguageModelV4Prompt,
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil,
    stopSequences: [String]? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    presencePenalty: Double? = nil,
    frequencyPenalty: Double? = nil,
    responseFormat: LanguageModelV4ResponseFormat? = nil,
    seed: Int? = nil,
    tools: [LanguageModelV4Tool]? = nil,
    toolChoice: LanguageModelV4ToolChoice? = nil,
    includeRawChunks: Bool? = nil,
    headers: [String: String]? = nil,
    reasoning: LanguageModelV4ReasoningEffort? = nil,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.prompt = prompt
    self.maxOutputTokens = maxOutputTokens
    self.temperature = temperature
    self.stopSequences = stopSequences
    self.topP = topP
    self.topK = topK
    self.presencePenalty = presencePenalty
    self.frequencyPenalty = frequencyPenalty
    self.responseFormat = responseFormat
    self.seed = seed
    self.tools = tools
    self.toolChoice = toolChoice
    self.includeRawChunks = includeRawChunks
    self.headers = headers
    self.reasoning = reasoning
    self.providerOptions = providerOptions
  }
}

/// Response format of a language model call.
public enum LanguageModelV4ResponseFormat: Sendable, Equatable {
  case text
  /// JSON output, optionally guided by a schema, a name and a description.
  case json(schema: JSONSchema? = nil, name: String? = nil, description: String? = nil)
}

/// Reasoning effort level.
public enum LanguageModelV4ReasoningEffort: String, Sendable, Hashable {
  case providerDefault = "provider-default"
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
}

/// A tool available to the model.
public enum LanguageModelV4Tool: Sendable, Equatable {
  case function(LanguageModelV4FunctionTool)
  case provider(LanguageModelV4ProviderTool)

  public var name: String {
    switch self {
    case .function(let tool): tool.name
    case .provider(let tool): tool.name
    }
  }
}

/// A tool with a name, description and input schema. Mirrors upstream `LanguageModelV4FunctionTool`.
public struct LanguageModelV4FunctionTool: Sendable, Equatable {
  /// Unique name used to identify the tool within the model.
  public var name: String
  /// Helps the model understand when to use the tool.
  public var description: String?
  /// Expected input. Should describe an object.
  public var inputSchema: JSONSchema
  /// Example inputs.
  public var inputExamples: [JSONObject]?
  /// Strict mode, for providers that support it.
  public var strict: Bool?
  public var providerOptions: SharedV4ProviderOptions?

  public init(
    name: String,
    description: String? = nil,
    inputSchema: JSONSchema,
    inputExamples: [JSONObject]? = nil,
    strict: Bool? = nil,
    providerOptions: SharedV4ProviderOptions? = nil
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.inputExamples = inputExamples
    self.strict = strict
    self.providerOptions = providerOptions
  }
}

/// A tool implemented by the provider. Mirrors upstream `LanguageModelV4ProviderTool`.
public struct LanguageModelV4ProviderTool: Sendable, Equatable {
  /// The tool ID, in the format `{provider}.{tool-name}`.
  public var id: String
  /// The name used in the tool set.
  public var name: String
  /// Arguments for configuring the tool.
  public var args: JSONObject

  public init(id: String, name: String, args: JSONObject = [:]) {
    self.id = id
    self.name = name
    self.args = args
  }
}

/// How the model selects a tool. Mirrors upstream `LanguageModelV4ToolChoice`.
public enum LanguageModelV4ToolChoice: Sendable, Hashable {
  /// Automatic selection; may select no tool.
  case auto
  /// No tool may be selected.
  case none
  /// One of the available tools must be selected.
  case required
  /// The named tool must be selected.
  case tool(toolName: String)
}
