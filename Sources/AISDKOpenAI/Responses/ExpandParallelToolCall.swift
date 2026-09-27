import AISDKProviderUtils
import Foundation

private let parallelToolName = "parallel"
private let recipientNamePrefix = "functions."

/// Identity of the `parallel` wrapper a tool call was expanded from, so the
/// child results can be sent back as one function output.
/// Mirrors upstream `ParallelToolCallMetadata`.
struct ParallelToolCallMetadata: Equatable {
  var itemId: String
  var toolCallId: String
  var toolName: String
  var input: String
  var index: Int
  var count: Int

  var json: JSONValue {
    [
      "itemId": .string(itemId), "toolCallId": .string(toolCallId), "toolName": .string(toolName),
      "input": .string(input), "index": .number(Double(index)), "count": .number(Double(count)),
    ]
  }

  /// Mirrors upstream `getParallelToolCallMetadata`.
  init?(providerOptions: SharedV4ProviderOptions?, providerOptionsName: String) {
    guard case .object(let value)? = providerOptions?[providerOptionsName]?["parallelToolCall"],
      let itemId = value["itemId"]?.stringValue, let toolCallId = value["toolCallId"]?.stringValue,
      let toolName = value["toolName"]?.stringValue, let input = value["input"]?.stringValue,
      let index = value["index"]?.intValue, let count = value["count"]?.intValue,
      index >= 0, count > index
    else { return nil }
    self.init(itemId: itemId, toolCallId: toolCallId, toolName: toolName, input: input, index: index, count: count)
  }

  init(itemId: String, toolCallId: String, toolName: String, input: String, index: Int, count: Int) {
    self.itemId = itemId
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.input = input
    self.index = index
    self.count = count
  }

  func isSameCall(as other: ParallelToolCallMetadata) -> Bool {
    itemId == other.itemId && toolCallId == other.toolCallId && toolName == other.toolName && input == other.input
      && count == other.count
  }
}

/// Mirrors upstream `isUndeclaredParallelToolCall`.
func isUndeclaredParallelToolCall(toolName: String, tools: [LanguageModelV4FunctionTool]) -> Bool {
  toolName == parallelToolName && !tools.contains { $0.name == parallelToolName }
}

/// Expands OpenAI's internal `parallel` wrapper call into the individual
/// function calls it contains, when every recipient is a declared function
/// tool. Mirrors upstream `expandParallelToolCall`.
func expandParallelToolCall(
  toolCallId: String, toolName: String, input: String, tools: [LanguageModelV4FunctionTool],
  providerOptionsName: String, itemId: String
) -> [LanguageModelV4ToolCall]? {
  guard isUndeclaredParallelToolCall(toolName: toolName, tools: tools),
    case .object(let parsed)? = try? JSONValue(jsonString: input),
    case .array(let toolUses)? = parsed["tool_uses"], !toolUses.isEmpty
  else { return nil }

  let available = Set(tools.map(\.name))
  var expanded: [LanguageModelV4ToolCall] = []
  for (index, toolUse) in toolUses.enumerated() {
    guard case .object(let use) = toolUse, let recipient = use["recipient_name"]?.stringValue,
      recipient.hasPrefix(recipientNamePrefix), case .object = use["parameters"]
    else { return nil }
    let name = String(recipient.dropFirst(recipientNamePrefix.count))
    guard !name.isEmpty, available.contains(name) else { return nil }
    let metadata = ParallelToolCallMetadata(
      itemId: itemId, toolCallId: toolCallId, toolName: toolName, input: input, index: index, count: toolUses.count)
    expanded.append(
      LanguageModelV4ToolCall(
        toolCallId: "\(toolCallId)_\(index)", toolName: name, input: (use["parameters"] ?? [:]).jsonString(),
        providerMetadata: [providerOptionsName: ["parallelToolCall": metadata.json]]))
  }
  return expanded
}
