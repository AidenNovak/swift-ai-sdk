import AISDKProviderUtils
import Foundation

/// Provider options for Anthropic models, passed as `providerOptions["anthropic"]`.
/// Mirrors upstream `AnthropicLanguageModelOptions`.
public struct AnthropicOptions: Codable, Sendable, Equatable {
  public struct Thinking: Codable, Sendable, Equatable {
    public struct BlockBinding: Codable, Sendable, Equatable {
      /// `error` or `drop_block`.
      public var prefixMismatchBehavior: String

      public init(prefixMismatchBehavior: String) {
        self.prefixMismatchBehavior = prefixMismatchBehavior
      }
    }

    /// `enabled`, `adaptive` or `disabled`. May be omitted when only `blockBinding` is set.
    public var type: String?
    /// Token budget for `enabled` thinking.
    public var budgetTokens: Int?
    /// `summarized`, `omitted` or `updates` for adaptive thinking.
    public var display: String?
    /// How signed thinking blocks from earlier turns are validated.
    public var blockBinding: BlockBinding?

    public init(type: String? = nil, budgetTokens: Int? = nil, display: String? = nil, blockBinding: BlockBinding? = nil) {
      self.type = type
      self.budgetTokens = budgetTokens
      self.display = display
      self.blockBinding = blockBinding
    }
  }

  public struct Metadata: Codable, Sendable, Equatable {
    public var userId: String?

    public init(userId: String? = nil) {
      self.userId = userId
    }
  }

  /// A remote MCP server the API connects to.
  public struct MCPServer: Codable, Sendable, Equatable {
    public struct ToolConfiguration: Codable, Sendable, Equatable {
      public var enabled: Bool?
      public var allowedTools: [String]?

      public init(enabled: Bool? = nil, allowedTools: [String]? = nil) {
        self.enabled = enabled
        self.allowedTools = allowedTools
      }
    }

    /// Always `url`.
    public var type: String
    public var name: String
    public var url: String
    public var authorizationToken: String?
    public var toolConfiguration: ToolConfiguration?

    public init(
      name: String, url: String, authorizationToken: String? = nil, toolConfiguration: ToolConfiguration? = nil
    ) {
      self.type = "url"
      self.name = name
      self.url = url
      self.authorizationToken = authorizationToken
      self.toolConfiguration = toolConfiguration
    }
  }

  /// A code execution container, reused across calls or with agent skills.
  public struct Container: Codable, Sendable, Equatable {
    public struct Skill: Codable, Sendable, Equatable {
      /// `anthropic` (built-in skills) or `custom` (uploaded skills).
      public var type: String
      public var skillId: String?
      /// For `custom` skills: the uploaded skill reference.
      public var providerReference: [String: String]?
      public var version: String?

      public init(type: String, skillId: String? = nil, providerReference: [String: String]? = nil, version: String? = nil) {
        self.type = type
        self.skillId = skillId
        self.providerReference = providerReference
        self.version = version
      }
    }

    public var id: String?
    public var skills: [Skill]?

    public init(id: String? = nil, skills: [Skill]? = nil) {
      self.id = id
      self.skills = skills
    }
  }

  public struct TaskBudget: Codable, Sendable, Equatable {
    /// Always `tokens`.
    public var type: String
    public var total: Int
    public var remaining: Int?

    public init(total: Int, remaining: Int? = nil) {
      self.type = "tokens"
      self.total = total
      self.remaining = remaining
    }
  }

  public struct Safeguard: Codable, Sendable, Equatable {
    /// Always `dangerous_tool_use`.
    public var type: String
    public var classifierContext: JSONObject?

    public init(classifierContext: JSONObject? = nil) {
      self.type = "dangerous_tool_use"
      self.classifierContext = classifierContext
    }
  }

  public struct Compaction: Codable, Sendable, Equatable {
    /// Always `summarize`.
    public var type: String
    public var instructions: String?

    public init(instructions: String? = nil) {
      self.type = "summarize"
      self.instructions = instructions
    }
  }

  public struct ContextManagement: Codable, Sendable, Equatable {
    /// Edits such as `{"type": "clear_tool_uses_20250919", "keep": {...}}`, with camelCase keys.
    public var edits: [JSONObject]

    public init(edits: [JSONObject]) {
      self.edits = edits
    }
  }

  /// Whether reasoning from earlier turns is sent back. Defaults to true.
  public var sendReasoning: Bool?
  /// `auto`, `outputFormat` or `jsonTool`.
  public var structuredOutputMode: String?
  public var thinking: Thinking?
  public var disableParallelToolUse: Bool?
  /// Top-level cache control, e.g. `{"type": "ephemeral"}`.
  public var cacheControl: JSONValue?
  public var metadata: Metadata?
  public var mcpServers: [MCPServer]?
  public var container: Container?
  /// Whether tool input is streamed eagerly. Defaults to true when streaming.
  public var toolStreaming: Bool?
  /// `low`, `medium`, `high`, `xhigh` or `max`.
  public var effort: String?
  public var taskBudget: TaskBudget?
  /// `fast` or `standard`.
  public var speed: String?
  /// `auto` or `standard_only`.
  public var serviceTier: String?
  /// `us` or `global`.
  public var inferenceGeo: String?
  /// `"default"` or an array of fallback model configurations.
  public var fallbacks: JSONValue?
  /// Additional `anthropic-beta` values.
  public var anthropicBeta: [String]?
  public var safeguards: [Safeguard]?
  public var compaction: Compaction?
  public var contextManagement: ContextManagement?

  public init(
    sendReasoning: Bool? = nil,
    structuredOutputMode: String? = nil,
    thinking: Thinking? = nil,
    disableParallelToolUse: Bool? = nil,
    cacheControl: JSONValue? = nil,
    metadata: Metadata? = nil,
    mcpServers: [MCPServer]? = nil,
    container: Container? = nil,
    toolStreaming: Bool? = nil,
    effort: String? = nil,
    taskBudget: TaskBudget? = nil,
    speed: String? = nil,
    serviceTier: String? = nil,
    inferenceGeo: String? = nil,
    fallbacks: JSONValue? = nil,
    anthropicBeta: [String]? = nil,
    safeguards: [Safeguard]? = nil,
    compaction: Compaction? = nil,
    contextManagement: ContextManagement? = nil
  ) {
    self.sendReasoning = sendReasoning
    self.structuredOutputMode = structuredOutputMode
    self.thinking = thinking
    self.disableParallelToolUse = disableParallelToolUse
    self.cacheControl = cacheControl
    self.metadata = metadata
    self.mcpServers = mcpServers
    self.container = container
    self.toolStreaming = toolStreaming
    self.effort = effort
    self.taskBudget = taskBudget
    self.speed = speed
    self.serviceTier = serviceTier
    self.inferenceGeo = inferenceGeo
    self.fallbacks = fallbacks
    self.anthropicBeta = anthropicBeta
    self.safeguards = safeguards
    self.compaction = compaction
    self.contextManagement = contextManagement
  }

  /// The options as a provider options value, e.g. `["anthropic": options.json]`.
  public var json: JSONValue { (try? JSONValue(encoding: self)) ?? [:] }
}

/// Per-file-part options. Mirrors upstream `anthropicFilePartProviderOptions`.
struct AnthropicFilePartOptions: Decodable, Sendable {
  struct Citations: Decodable, Sendable {
    var enabled: Bool
  }

  var containerUpload: Bool?
  var citations: Citations?
  var title: String?
  var context: String?
}

/// Per-system-message options. Mirrors upstream `anthropicSystemMessageProviderOptions`.
struct AnthropicSystemMessageOptions: Decodable, Sendable {
  struct ToolChange: Decodable, Sendable {
    /// `tool_addition` or `tool_removal`.
    var type: String
    var toolName: String
  }

  var clearAt: String?
  var effort: String?
  var toolChanges: [ToolChange]?
}

/// Reasoning metadata attached to reasoning parts. Mirrors upstream `AnthropicReasoningMetadata`.
struct AnthropicReasoningMetadata: Decodable, Sendable {
  var signature: String?
  var redactedData: String?
}

/// Parses the options under `anthropic` and, for custom provider names, the
/// provider's own key, which overrides them field by field.
func parseAnthropicOptions(providerOptions: SharedV4ProviderOptions?, providerOptionsName: String) throws -> (
  options: AnthropicOptions, usedCustomProviderKey: Bool
) {
  _ = try parseProviderOptions(provider: "anthropic", providerOptions: providerOptions, as: AnthropicOptions.self)
  var merged = providerOptions?["anthropic"] ?? [:]
  var usedCustomProviderKey = false
  if providerOptionsName != "anthropic",
    try parseProviderOptions(provider: providerOptionsName, providerOptions: providerOptions, as: AnthropicOptions.self)
      != nil
  {
    usedCustomProviderKey = true
    merged.merge(providerOptions?[providerOptionsName] ?? [:]) { _, custom in custom }
  }
  let options =
    try parseProviderOptions(provider: "anthropic", providerOptions: ["anthropic": merged], as: AnthropicOptions.self)
    ?? AnthropicOptions()
  return (options, usedCustomProviderKey)
}
