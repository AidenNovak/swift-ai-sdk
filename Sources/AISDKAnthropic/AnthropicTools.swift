import AISDKProviderUtils
import Foundation

/// Approximate user location for web search.
public struct AnthropicUserLocation: Sendable, Equatable {
  public var city: String?
  public var region: String?
  public var country: String?
  public var timezone: String?

  public init(city: String? = nil, region: String? = nil, country: String? = nil, timezone: String? = nil) {
    self.city = city
    self.region = region
    self.country = country
    self.timezone = timezone
  }

  var json: JSONValue {
    jsonObject([
      "type": "approximate", "city": .optional(city), "region": .optional(region), "country": .optional(country),
      "timezone": .optional(timezone),
    ])
  }
}

/// Anthropic's provider-defined tools. Mirrors upstream `anthropic.tools`.
///
/// Server tools (web search, web fetch, code execution, tool search, advisor)
/// run on Anthropic's side; their calls and results arrive as provider-executed
/// tool parts. Client tools (bash, text editor, computer, memory) use
/// Anthropic's trained schemas but run in your app through `execute`; the
/// model calls them by their API names, so register them under those names
/// (`bash`, `str_replace_editor` / `str_replace_based_edit_tool`, `computer`,
/// `memory`).
///
/// ```swift
/// let result = try await generateText(
///   model: anthropic("claude-sonnet-5"), prompt: "What's new in Swift?",
///   tools: ["web_search": AnthropicTools.webSearch_20250305(maxUses: 3)])
/// ```
public enum AnthropicTools {
  private static func tool(
    _ id: String, args: [String: JSONValue?] = [:], inputSchema: JSONSchema, outputSchema: JSONSchema? = nil,
    isProviderExecuted: Bool, supportsDeferredResults: Bool = false, execute: Tool.Execute? = nil,
    needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    var tool = providerTool(
      id: "anthropic.\(id)", args: args.compactMapValues { $0 }, inputSchema: inputSchema,
      isProviderExecuted: isProviderExecuted, supportsDeferredResults: supportsDeferredResults, execute: execute)
    tool.outputSchema = outputSchema
    tool.needsApproval = needsApproval
    return tool
  }

  private static func strings(_ values: [String]?) -> JSONValue? {
    values.map { .array($0.map(JSONValue.string)) }
  }

  private static func object(_ properties: JSONObject, required: [String] = []) -> JSONSchema {
    var schema: JSONObject = ["type": "object", "properties": .object(properties)]
    if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
    return JSONSchema(.object(schema))
  }

  private static let string: JSONValue = ["type": "string"]
  private static let number: JSONValue = ["type": "number"]
  private static let integer: JSONValue = ["type": "integer"]
  private static let boolean: JSONValue = ["type": "boolean"]
  private static func integers(_ count: Int? = nil) -> JSONValue {
    var schema: JSONObject = ["type": "array", "items": ["type": "integer"]]
    if let count {
      schema["minItems"] = .number(Double(count))
      schema["maxItems"] = .number(Double(count))
    }
    return .object(schema)
  }
  private static func enumeration(_ values: [String]) -> JSONValue {
    ["type": "string", "enum": .array(values.map(JSONValue.string))]
  }

  // MARK: Web search

  private static func webSearch(
    _ version: String, maxUses: Int?, allowedDomains: [String]?, blockedDomains: [String]?,
    userLocation: AnthropicUserLocation?, responseInclusion: String? = nil
  ) -> Tool {
    tool(
      version,
      args: [
        "maxUses": maxUses.map { .number(Double($0)) }, "allowedDomains": strings(allowedDomains),
        "blockedDomains": strings(blockedDomains), "userLocation": userLocation?.json,
        "responseInclusion": responseInclusion.map(JSONValue.string),
      ],
      inputSchema: object(["query": string], required: ["query"]), isProviderExecuted: true,
      supportsDeferredResults: true)
  }

  /// Web search, executed by Anthropic. Results arrive as tool results and URL sources.
  public static func webSearch_20250305(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
    userLocation: AnthropicUserLocation? = nil
  ) -> Tool {
    webSearch(
      "web_search_20250305", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      userLocation: userLocation)
  }

  /// Web search with dynamic filtering (requires the code execution web tools beta).
  public static func webSearch_20260209(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
    userLocation: AnthropicUserLocation? = nil
  ) -> Tool {
    webSearch(
      "web_search_20260209", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      userLocation: userLocation)
  }

  /// Web search with dynamic filtering and `responseInclusion` (`full` or `excluded`).
  public static func webSearch_20260318(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
    userLocation: AnthropicUserLocation? = nil, responseInclusion: String? = nil
  ) -> Tool {
    webSearch(
      "web_search_20260318", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      userLocation: userLocation, responseInclusion: responseInclusion)
  }

  // MARK: Web fetch

  private static func webFetch(
    _ version: String, maxUses: Int?, allowedDomains: [String]?, blockedDomains: [String]?, citations: Bool?,
    maxContentTokens: Int?, useCache: Bool? = nil, responseInclusion: String? = nil
  ) -> Tool {
    tool(
      version,
      args: [
        "maxUses": maxUses.map { .number(Double($0)) }, "allowedDomains": strings(allowedDomains),
        "blockedDomains": strings(blockedDomains), "citations": citations.map { ["enabled": .bool($0)] },
        "maxContentTokens": maxContentTokens.map { .number(Double($0)) }, "useCache": useCache.map(JSONValue.bool),
        "responseInclusion": responseInclusion.map(JSONValue.string),
      ],
      inputSchema: object(["url": string], required: ["url"]), isProviderExecuted: true, supportsDeferredResults: true)
  }

  /// Fetches web pages and PDFs, executed by Anthropic.
  public static func webFetch_20250910(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil, citations: Bool? = nil,
    maxContentTokens: Int? = nil
  ) -> Tool {
    webFetch(
      "web_fetch_20250910", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      citations: citations, maxContentTokens: maxContentTokens)
  }

  /// Web fetch with dynamic filtering (requires the code execution web tools beta).
  public static func webFetch_20260209(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil, citations: Bool? = nil,
    maxContentTokens: Int? = nil
  ) -> Tool {
    webFetch(
      "web_fetch_20260209", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      citations: citations, maxContentTokens: maxContentTokens)
  }

  /// Web fetch with dynamic filtering, caching and `responseInclusion`.
  public static func webFetch_20260318(
    maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil, citations: Bool? = nil,
    maxContentTokens: Int? = nil, useCache: Bool? = nil, responseInclusion: String? = nil
  ) -> Tool {
    webFetch(
      "web_fetch_20260318", maxUses: maxUses, allowedDomains: allowedDomains, blockedDomains: blockedDomains,
      citations: citations, maxContentTokens: maxContentTokens, useCache: useCache,
      responseInclusion: responseInclusion)
  }

  // MARK: Code execution

  /// Python code execution in a sandbox, executed by Anthropic.
  public static func codeExecution_20250522() -> Tool {
    tool(
      "code_execution_20250522", inputSchema: object(["code": string], required: ["code"]), isProviderExecuted: true)
  }

  private static let codeExecutionInput = object(
    [
      "type": enumeration(["programmatic-tool-call", "bash_code_execution", "text_editor_code_execution"]),
      "code": string, "command": string, "path": string, "file_text": string, "old_str": string, "new_str": string,
    ], required: ["type"])

  /// Bash and file editing in a sandbox, plus programmatic tool calling, executed by Anthropic.
  public static func codeExecution_20250825() -> Tool {
    tool("code_execution_20250825", inputSchema: codeExecutionInput, isProviderExecuted: true)
  }

  /// Code execution without a beta header, with encrypted output support.
  public static func codeExecution_20260120() -> Tool {
    tool("code_execution_20260120", inputSchema: codeExecutionInput, isProviderExecuted: true)
  }

  // MARK: Tool search

  /// Searches deferred tools (`deferLoading`) by regular expression, executed by Anthropic.
  public static func toolSearchRegex_20251119() -> Tool {
    tool(
      "tool_search_regex_20251119", inputSchema: object(["pattern": string, "limit": number], required: ["pattern"]),
      isProviderExecuted: true, supportsDeferredResults: true)
  }

  /// Searches deferred tools (`deferLoading`) with BM25, executed by Anthropic.
  public static func toolSearchBm25_20251119() -> Tool {
    tool(
      "tool_search_bm25_20251119", inputSchema: object(["query": string, "limit": number], required: ["query"]),
      isProviderExecuted: true, supportsDeferredResults: true)
  }

  // MARK: Advisor

  /// Consults a stronger advisor model, executed by Anthropic.
  ///
  /// - Parameter caching: e.g. `["type": "ephemeral", "ttl": "5m"]`.
  public static func advisor_20260301(
    model: String, maxUses: Int? = nil, maxTokens: Int? = nil, caching: JSONObject? = nil
  ) -> Tool {
    tool(
      "advisor_20260301",
      args: [
        "model": .string(model), "maxUses": maxUses.map { .number(Double($0)) },
        "maxTokens": maxTokens.map { .number(Double($0)) }, "caching": caching.map(JSONValue.object),
      ],
      inputSchema: object([:]), isProviderExecuted: true, supportsDeferredResults: true)
  }

  // MARK: Client tools

  /// A bash shell that your app runs. Input: `{command, restart?}`.
  public static func bash_20241022(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil) -> Tool {
    tool(
      "bash_20241022", inputSchema: object(["command": string, "restart": boolean], required: ["command"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }

  /// A bash shell that your app runs. Input: `{command, restart?}`.
  public static func bash_20250124(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil) -> Tool {
    tool(
      "bash_20250124", inputSchema: object(["command": string, "restart": boolean], required: ["command"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }

  private static func textEditorInput(commands: [String], extra: JSONObject = [:]) -> JSONSchema {
    var properties: JSONObject = [
      "command": enumeration(commands), "path": string, "file_text": string, "insert_line": integer,
      "new_str": string, "insert_text": string, "old_str": string, "view_range": integers(),
    ]
    properties.merge(extra) { _, new in new }
    return object(properties, required: ["command", "path"])
  }

  /// A file editor that your app runs (`str_replace_editor`).
  public static func textEditor_20241022(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil)
    -> Tool
  {
    tool(
      "text_editor_20241022",
      inputSchema: textEditorInput(commands: ["view", "create", "str_replace", "insert", "undo_edit"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }

  /// A file editor that your app runs (`str_replace_editor`).
  public static func textEditor_20250124(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil)
    -> Tool
  {
    tool(
      "text_editor_20250124",
      inputSchema: textEditorInput(commands: ["view", "create", "str_replace", "insert", "undo_edit"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }

  /// A file editor that your app runs (`str_replace_based_edit_tool`).
  public static func textEditor_20250429(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil)
    -> Tool
  {
    tool(
      "text_editor_20250429", inputSchema: textEditorInput(commands: ["view", "create", "str_replace", "insert"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }

  /// A file editor that your app runs (`str_replace_based_edit_tool`), with an optional view size limit.
  public static func textEditor_20250728(
    maxCharacters: Int? = nil, execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    tool(
      "text_editor_20250728", args: ["maxCharacters": maxCharacters.map { .number(Double($0)) }],
      inputSchema: textEditorInput(commands: ["view", "create", "str_replace", "insert"]), isProviderExecuted: false,
      execute: execute, needsApproval: needsApproval)
  }

  private static func computerInput(actions: [String]) -> JSONSchema {
    object(
      [
        "action": enumeration(actions), "coordinate": integers(2), "duration": number, "region": integers(4),
        "scroll_amount": number, "scroll_direction": enumeration(["up", "down", "left", "right"]),
        "start_coordinate": integers(2), "text": string, "repeat": integer,
      ], required: ["action"])
  }

  private static let computerActions20241022 = [
    "key", "type", "mouse_move", "left_click", "left_click_drag", "right_click", "middle_click", "double_click",
    "screenshot", "cursor_position",
  ]
  private static let computerActions20250124 =
    computerActions20241022 + ["triple_click", "left_mouse_down", "left_mouse_up", "hold_key", "scroll", "wait"]

  /// Computer use that your app runs: screenshots, mouse and keyboard.
  public static func computer_20241022(
    displayWidthPx: Int, displayHeightPx: Int, displayNumber: Int? = nil, execute: Tool.Execute? = nil,
    needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    tool(
      "computer_20241022",
      args: [
        "displayWidthPx": .number(Double(displayWidthPx)), "displayHeightPx": .number(Double(displayHeightPx)),
        "displayNumber": displayNumber.map { .number(Double($0)) },
      ],
      inputSchema: computerInput(actions: computerActions20241022), isProviderExecuted: false, execute: execute,
      needsApproval: needsApproval)
  }

  /// Computer use that your app runs: screenshots, mouse, keyboard, scrolling and waits.
  public static func computer_20250124(
    displayWidthPx: Int, displayHeightPx: Int, displayNumber: Int? = nil, execute: Tool.Execute? = nil,
    needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    tool(
      "computer_20250124",
      args: [
        "displayWidthPx": .number(Double(displayWidthPx)), "displayHeightPx": .number(Double(displayHeightPx)),
        "displayNumber": displayNumber.map { .number(Double($0)) },
      ],
      inputSchema: computerInput(actions: computerActions20250124), isProviderExecuted: false, execute: execute,
      needsApproval: needsApproval)
  }

  /// Computer use that your app runs, with optional zoom.
  public static func computer_20251124(
    displayWidthPx: Int, displayHeightPx: Int, displayNumber: Int? = nil, enableZoom: Bool? = nil,
    execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    tool(
      "computer_20251124",
      args: [
        "displayWidthPx": .number(Double(displayWidthPx)), "displayHeightPx": .number(Double(displayHeightPx)),
        "displayNumber": displayNumber.map { .number(Double($0)) }, "enableZoom": enableZoom.map(JSONValue.bool),
      ],
      inputSchema: computerInput(actions: computerActions20250124 + ["zoom"]), isProviderExecuted: false,
      execute: execute, needsApproval: needsApproval)
  }

  /// The members of the computer toolset.
  public static let computerToolsetMembers = [
    "screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
    "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position", "scroll", "type", "key",
    "hold_key", "wait",
  ]

  /// Computer use as a toolset: each action is a separate tool the model
  /// calls; your app receives `{action, ...}` inputs.
  ///
  /// - Parameter configs: Per member, e.g. `["zoom": ["enabled": false], "wait": ["deferLoading": true]]`.
  public static func computerToolset_20260801(
    configs: [String: JSONObject]? = nil, execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil
  ) -> Tool {
    tool(
      "computer_toolset_20260801", args: ["configs": configs.map { .object($0.mapValues(JSONValue.object)) }],
      inputSchema: computerInput(actions: computerToolsetMembers), isProviderExecuted: false, execute: execute,
      needsApproval: needsApproval)
  }

  /// A file-based memory directory that your app manages (`/memories`).
  public static func memory_20250818(execute: Tool.Execute? = nil, needsApproval: Tool.NeedsApproval? = nil) -> Tool {
    tool(
      "memory_20250818",
      inputSchema: object(
        [
          "command": enumeration(["view", "create", "str_replace", "insert", "delete", "rename"]), "path": string,
          "view_range": integers(2), "file_text": string, "old_str": string, "new_str": string,
          "insert_line": number, "insert_text": string, "old_path": string, "new_path": string,
        ], required: ["command"]),
      isProviderExecuted: false, execute: execute, needsApproval: needsApproval)
  }
}

extension AnthropicProvider {
  /// Anthropic's provider-defined tools. Mirrors upstream `anthropic.tools`.
  public var tools: AnthropicTools.Type { AnthropicTools.self }
}
