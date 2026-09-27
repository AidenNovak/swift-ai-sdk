import AISDK
import AISDKTestUtils
import Foundation

struct ValueInput: Codable, Sendable, Equatable {
  var value: String
}

let valueSchema = Schema(
  ValueInput.self,
  jsonSchema: [
    "type": "object",
    "properties": ["value": ["type": "string"]],
    "required": ["value"],
    "additionalProperties": false,
  ])

func toolCallResult(
  _ calls: [(id: String, name: String, input: String)],
  usage: LanguageModelV4Usage = .mock
) -> LanguageModelV4GenerateResult {
  LanguageModelV4GenerateResult(
    content: calls.map {
      .toolCall(LanguageModelV4ToolCall(toolCallId: $0.id, toolName: $0.name, input: $0.input))
    },
    finishReason: LanguageModelV4FinishReason(unified: .toolCalls),
    usage: usage,
    response: LanguageModelV4ResponseInfo(
      metadata: LanguageModelV4ResponseMetadata(
        id: "id-tools", timestamp: Date(timeIntervalSince1970: 0), modelId: "mock-model-id")))
}

let fixedIds: IdGenerator = { "test-id" }

