import Foundation

// The upstream JSON form of the language model specification types, so
// prompts, results and stream events can be persisted, recorded, sent over
// the wire or exchanged with JavaScript. Every type below is `Codable`
// through its `json` form.

/// A value could not be decoded from its specification JSON.
public struct SpecificationDecodingError: AISDKError {
  public let name = "AI_SpecificationDecodingError"
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

/// An error decoded from a stream `error` part; the original error type is not preserved.
public struct DecodedStreamError: AISDKError {
  public let name = "AI_DecodedStreamError"
  public let message: String
  /// The encoded error value.
  public let value: JSONValue

  public init(value: JSONValue) {
    self.value = value
    self.message = value.stringValue ?? value["message"]?.stringValue ?? value.jsonString()
  }
}

private func object(_ entries: KeyValuePairs<String, JSONValue?>) -> JSONValue {
  var result: JSONObject = [:]
  for (key, value) in entries {
    if let value { result[key] = value }
  }
  return .object(result)
}

private func string(_ value: String?) -> JSONValue? { value.map(JSONValue.string) }
private func number(_ value: Int?) -> JSONValue? { value.map { .number(Double($0)) } }
private func number(_ value: Double?) -> JSONValue? { value.map(JSONValue.number) }
private func bool(_ value: Bool?) -> JSONValue? { value.map(JSONValue.bool) }
private func metadata(_ value: SharedV4ProviderMetadata?) -> JSONValue? {
  value.map { .object($0.mapValues(JSONValue.object)) }
}

private func decodeMetadata(_ value: JSONValue?) -> SharedV4ProviderMetadata? {
  guard let object = value?.objectValue else { return nil }
  return object.compactMapValues(\.objectValue)
}

private func requireString(_ json: JSONValue, _ key: String) throws -> String {
  guard let value = json[key]?.stringValue else {
    throw SpecificationDecodingError(message: "Missing string '\(key)' in \(json.jsonString()).")
  }
  return value
}

private func unknownType(_ json: JSONValue, _ context: String) -> SpecificationDecodingError {
  SpecificationDecodingError(message: "Unknown \(context) type '\(json["type"]?.stringValue ?? "?")'.")
}

private func fractionalSecondsFormatter() -> ISO8601DateFormatter {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}

private func isoTimestamp(_ date: Date) -> String {
  fractionalSecondsFormatter().string(from: date)
}

private func date(_ text: String?) -> Date? {
  guard let text else { return nil }
  return fractionalSecondsFormatter().date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

/// Declares `Codable` through `json` / `init(json:)`.
public protocol SpecificationJSONCodable: Codable {
  var json: JSONValue { get }
  init(json: JSONValue) throws
}

extension SpecificationJSONCodable {
  public init(from decoder: any Decoder) throws {
    try self.init(json: JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}

// MARK: - Shared

extension SharedV4FileData: SpecificationJSONCodable {
  /// Tagged JSON form: `{type: 'data' | 'url' | 'reference' | 'text', ...}`; bytes are base64.
  public var json: JSONValue {
    switch self {
    case .data(let data): ["type": "data", "data": .string(data.base64EncodedString())]
    case .base64(let base64): ["type": "data", "data": .string(base64)]
    case .url(let url, _): ["type": "url", "url": .string(url.absoluteString)]
    case .reference(let reference): ["type": "reference", "reference": .object(reference.mapValues(JSONValue.string))]
    case .text(let text): ["type": "text", "text": .string(text)]
    }
  }

  public init(json: JSONValue) throws {
    switch json["type"]?.stringValue {
    case "data": self = .base64(try requireString(json, "data"))
    case "url":
      guard let url = URL(string: try requireString(json, "url")) else {
        throw SpecificationDecodingError(message: "Invalid URL in \(json.jsonString()).")
      }
      self = .url(url)
    case "reference": self = .reference((json["reference"]?.objectValue ?? [:]).compactMapValues(\.stringValue))
    case "text": self = .text(try requireString(json, "text"))
    default: throw unknownType(json, "file data")
    }
  }
}

extension SharedV4Warning: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .unsupported(let feature, let details):
      object(["type": "unsupported", "feature": .string(feature), "details": string(details)])
    case .compatibility(let feature, let details):
      object(["type": "compatibility", "feature": .string(feature), "details": string(details)])
    case .deprecated(let setting, let message):
      ["type": "deprecated", "setting": .string(setting), "message": .string(message)]
    case .other(let message):
      ["type": "other", "message": .string(message)]
    }
  }

  public init(json: JSONValue) throws {
    switch json["type"]?.stringValue {
    case "unsupported":
      self = .unsupported(feature: try requireString(json, "feature"), details: json["details"]?.stringValue)
    case "compatibility":
      self = .compatibility(feature: try requireString(json, "feature"), details: json["details"]?.stringValue)
    case "deprecated":
      self = .deprecated(setting: try requireString(json, "setting"), message: try requireString(json, "message"))
    case "other": self = .other(message: try requireString(json, "message"))
    default: throw unknownType(json, "warning")
    }
  }
}

// MARK: - Results

extension LanguageModelV4Usage: SpecificationJSONCodable {
  public var json: JSONValue {
    object([
      "inputTokens": object([
        "total": number(inputTokens.total), "noCache": number(inputTokens.noCache),
        "cacheRead": number(inputTokens.cacheRead), "cacheWrite": number(inputTokens.cacheWrite),
      ]),
      "outputTokens": object([
        "total": number(outputTokens.total), "text": number(outputTokens.text),
        "reasoning": number(outputTokens.reasoning),
      ]),
      "raw": raw.map(JSONValue.object),
    ])
  }

  public init(json: JSONValue) throws {
    let input = json["inputTokens"]
    let output = json["outputTokens"]
    self.init(
      inputTokens: InputTokens(
        total: input?["total"]?.intValue, noCache: input?["noCache"]?.intValue,
        cacheRead: input?["cacheRead"]?.intValue, cacheWrite: input?["cacheWrite"]?.intValue),
      outputTokens: OutputTokens(
        total: output?["total"]?.intValue, text: output?["text"]?.intValue, reasoning: output?["reasoning"]?.intValue),
      raw: json["raw"]?.objectValue)
  }
}

extension LanguageModelV4FinishReason: SpecificationJSONCodable {
  public var json: JSONValue {
    object(["unified": .string(unified.rawValue), "raw": string(raw)])
  }

  public init(json: JSONValue) throws {
    guard let unified = json["unified"]?.stringValue.flatMap(Unified.init(rawValue:)) else {
      throw SpecificationDecodingError(message: "Invalid finish reason \(json.jsonString()).")
    }
    self.init(unified: unified, raw: json["raw"]?.stringValue)
  }
}

extension LanguageModelV4ResponseMetadata: SpecificationJSONCodable {
  public var json: JSONValue {
    object(["id": string(id), "timestamp": timestamp.map { .string(isoTimestamp($0)) }, "modelId": string(modelId)])
  }

  public init(json: JSONValue) throws {
    self.init(
      id: json["id"]?.stringValue, timestamp: date(json["timestamp"]?.stringValue),
      modelId: json["modelId"]?.stringValue)
  }
}

extension LanguageModelV4Source: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .url(let id, let url, let title, let providerMetadata):
      object([
        "type": "source", "sourceType": "url", "id": .string(id), "url": .string(url), "title": string(title),
        "providerMetadata": metadata(providerMetadata),
      ])
    case .document(let id, let mediaType, let title, let filename, let providerMetadata):
      object([
        "type": "source", "sourceType": "document", "id": .string(id), "mediaType": .string(mediaType),
        "title": .string(title), "filename": string(filename), "providerMetadata": metadata(providerMetadata),
      ])
    }
  }

  public init(json: JSONValue) throws {
    let providerMetadata = decodeMetadata(json["providerMetadata"])
    switch json["sourceType"]?.stringValue {
    case "url":
      self = .url(
        id: try requireString(json, "id"), url: try requireString(json, "url"), title: json["title"]?.stringValue,
        providerMetadata: providerMetadata)
    case "document":
      self = .document(
        id: try requireString(json, "id"), mediaType: try requireString(json, "mediaType"),
        title: try requireString(json, "title"), filename: json["filename"]?.stringValue,
        providerMetadata: providerMetadata)
    default:
      throw SpecificationDecodingError(message: "Unknown source type in \(json.jsonString()).")
    }
  }
}

extension LanguageModelV4ToolCall: SpecificationJSONCodable {
  public var json: JSONValue {
    object([
      "type": "tool-call", "toolCallId": .string(toolCallId), "toolName": .string(toolName), "input": .string(input),
      "providerExecuted": bool(providerExecuted), "dynamic": bool(dynamic), "providerMetadata": metadata(providerMetadata),
    ])
  }

  public init(json: JSONValue) throws {
    self.init(
      toolCallId: try requireString(json, "toolCallId"), toolName: try requireString(json, "toolName"),
      input: try requireString(json, "input"), providerExecuted: json["providerExecuted"]?.boolValue,
      dynamic: json["dynamic"]?.boolValue, providerMetadata: decodeMetadata(json["providerMetadata"]))
  }
}

extension LanguageModelV4ToolResult: SpecificationJSONCodable {
  public var json: JSONValue {
    object([
      "type": "tool-result", "toolCallId": .string(toolCallId), "toolName": .string(toolName), "result": result,
      "isError": bool(isError), "preliminary": bool(preliminary), "dynamic": bool(dynamic),
      "providerMetadata": metadata(providerMetadata),
    ])
  }

  public init(json: JSONValue) throws {
    self.init(
      toolCallId: try requireString(json, "toolCallId"), toolName: try requireString(json, "toolName"),
      result: json["result"] ?? .null, isError: json["isError"]?.boolValue, preliminary: json["preliminary"]?.boolValue,
      dynamic: json["dynamic"]?.boolValue, providerMetadata: decodeMetadata(json["providerMetadata"]))
  }
}

extension LanguageModelV4Content: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .text(let text):
      object(["type": "text", "text": .string(text.text), "providerMetadata": metadata(text.providerMetadata)])
    case .reasoning(let reasoning):
      object(["type": "reasoning", "text": .string(reasoning.text), "providerMetadata": metadata(reasoning.providerMetadata)])
    case .custom(let custom):
      object(["type": "custom", "kind": .string(custom.kind), "providerMetadata": metadata(custom.providerMetadata)])
    case .file(let file):
      object([
        "type": "file", "mediaType": .string(file.mediaType), "data": file.data.json,
        "providerMetadata": metadata(file.providerMetadata),
      ])
    case .reasoningFile(let file):
      object([
        "type": "reasoning-file", "mediaType": .string(file.mediaType), "data": file.data.json,
        "providerMetadata": metadata(file.providerMetadata),
      ])
    case .toolApprovalRequest(let request):
      object([
        "type": "tool-approval-request", "approvalId": .string(request.approvalId),
        "toolCallId": .string(request.toolCallId), "providerMetadata": metadata(request.providerMetadata),
      ])
    case .source(let source): source.json
    case .toolCall(let call): call.json
    case .toolResult(let result): result.json
    }
  }

  public init(json: JSONValue) throws {
    let providerMetadata = decodeMetadata(json["providerMetadata"])
    switch json["type"]?.stringValue {
    case "text":
      self = .text(LanguageModelV4Text(text: try requireString(json, "text"), providerMetadata: providerMetadata))
    case "reasoning":
      self = .reasoning(LanguageModelV4Reasoning(text: try requireString(json, "text"), providerMetadata: providerMetadata))
    case "custom":
      self = .custom(LanguageModelV4CustomContent(kind: try requireString(json, "kind"), providerMetadata: providerMetadata))
    case "file":
      self = .file(
        LanguageModelV4File(
          mediaType: try requireString(json, "mediaType"), data: try SharedV4FileData(json: json["data"] ?? .null),
          providerMetadata: providerMetadata))
    case "reasoning-file":
      self = .reasoningFile(
        LanguageModelV4ReasoningFile(
          mediaType: try requireString(json, "mediaType"), data: try SharedV4FileData(json: json["data"] ?? .null),
          providerMetadata: providerMetadata))
    case "tool-approval-request":
      self = .toolApprovalRequest(
        LanguageModelV4ToolApprovalRequest(
          approvalId: try requireString(json, "approvalId"), toolCallId: try requireString(json, "toolCallId"),
          providerMetadata: providerMetadata))
    case "source": self = .source(try LanguageModelV4Source(json: json))
    case "tool-call": self = .toolCall(try LanguageModelV4ToolCall(json: json))
    case "tool-result": self = .toolResult(try LanguageModelV4ToolResult(json: json))
    default: throw unknownType(json, "content")
    }
  }
}

// MARK: - Stream parts

extension LanguageModelV4StreamPart: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .textStart(let id, let providerMetadata):
      object(["type": "text-start", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .textDelta(let id, let delta, let providerMetadata):
      object(["type": "text-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata)])
    case .textEnd(let id, let providerMetadata):
      object(["type": "text-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .reasoningStart(let id, let providerMetadata):
      object(["type": "reasoning-start", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .reasoningDelta(let id, let delta, let providerMetadata):
      object([
        "type": "reasoning-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata),
      ])
    case .reasoningEnd(let id, let providerMetadata):
      object(["type": "reasoning-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .toolInputStart(let start):
      object([
        "type": "tool-input-start", "id": .string(start.id), "toolName": .string(start.toolName),
        "providerMetadata": metadata(start.providerMetadata), "providerExecuted": bool(start.providerExecuted),
        "dynamic": bool(start.dynamic), "title": string(start.title),
      ])
    case .toolInputDelta(let id, let delta, let providerMetadata):
      object([
        "type": "tool-input-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata),
      ])
    case .toolInputEnd(let id, let providerMetadata):
      object(["type": "tool-input-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .toolApprovalRequest(let request): LanguageModelV4Content.toolApprovalRequest(request).json
    case .toolCall(let call): call.json
    case .toolResult(let result): result.json
    case .custom(let custom): LanguageModelV4Content.custom(custom).json
    case .file(let file): LanguageModelV4Content.file(file).json
    case .reasoningFile(let file): LanguageModelV4Content.reasoningFile(file).json
    case .source(let source): source.json
    case .streamStart(let warnings): ["type": "stream-start", "warnings": .array(warnings.map(\.json))]
    case .responseMetadata(let responseMetadata):
      object([
        "type": "response-metadata", "id": string(responseMetadata.id),
        "timestamp": responseMetadata.timestamp.map { .string(isoTimestamp($0)) }, "modelId": string(responseMetadata.modelId),
      ])
    case .finish(let usage, let finishReason, let providerMetadata):
      object([
        "type": "finish", "usage": usage.json, "finishReason": finishReason.json,
        "providerMetadata": metadata(providerMetadata),
      ])
    case .raw(let rawValue): ["type": "raw", "rawValue": rawValue]
    case .error(let error):
      if let decoded = error as? DecodedStreamError {
        ["type": "error", "error": decoded.value]
      } else {
        ["type": "error", "error": .string((error as? any AISDKError)?.message ?? String(describing: error))]
      }
    }
  }

  public init(json: JSONValue) throws {
    let providerMetadata = decodeMetadata(json["providerMetadata"])
    switch json["type"]?.stringValue {
    case "text-start": self = .textStart(id: try requireString(json, "id"), providerMetadata: providerMetadata)
    case "text-delta":
      self = .textDelta(
        id: try requireString(json, "id"), delta: try requireString(json, "delta"), providerMetadata: providerMetadata)
    case "text-end": self = .textEnd(id: try requireString(json, "id"), providerMetadata: providerMetadata)
    case "reasoning-start": self = .reasoningStart(id: try requireString(json, "id"), providerMetadata: providerMetadata)
    case "reasoning-delta":
      self = .reasoningDelta(
        id: try requireString(json, "id"), delta: try requireString(json, "delta"), providerMetadata: providerMetadata)
    case "reasoning-end": self = .reasoningEnd(id: try requireString(json, "id"), providerMetadata: providerMetadata)
    case "tool-input-start":
      self = .toolInputStart(
        LanguageModelV4ToolInputStart(
          id: try requireString(json, "id"), toolName: try requireString(json, "toolName"),
          providerMetadata: providerMetadata, providerExecuted: json["providerExecuted"]?.boolValue,
          dynamic: json["dynamic"]?.boolValue, title: json["title"]?.stringValue))
    case "tool-input-delta":
      self = .toolInputDelta(
        id: try requireString(json, "id"), delta: try requireString(json, "delta"), providerMetadata: providerMetadata)
    case "tool-input-end": self = .toolInputEnd(id: try requireString(json, "id"), providerMetadata: providerMetadata)
    case "tool-approval-request", "custom", "file", "reasoning-file":
      switch try LanguageModelV4Content(json: json) {
      case .toolApprovalRequest(let request): self = .toolApprovalRequest(request)
      case .custom(let custom): self = .custom(custom)
      case .file(let file): self = .file(file)
      case .reasoningFile(let file): self = .reasoningFile(file)
      default: throw unknownType(json, "stream part")
      }
    case "tool-call": self = .toolCall(try LanguageModelV4ToolCall(json: json))
    case "tool-result": self = .toolResult(try LanguageModelV4ToolResult(json: json))
    case "source": self = .source(try LanguageModelV4Source(json: json))
    case "stream-start": self = .streamStart(warnings: try (json["warnings"]?.arrayValue ?? []).map(SharedV4Warning.init(json:)))
    case "response-metadata": self = .responseMetadata(try LanguageModelV4ResponseMetadata(json: json))
    case "finish":
      self = .finish(
        usage: try LanguageModelV4Usage(json: json["usage"] ?? [:]),
        finishReason: try LanguageModelV4FinishReason(json: json["finishReason"] ?? .null),
        providerMetadata: providerMetadata)
    case "raw": self = .raw(rawValue: json["rawValue"] ?? .null)
    case "error": self = .error(DecodedStreamError(value: json["error"] ?? .null))
    default: throw unknownType(json, "stream part")
    }
  }
}

// MARK: - Prompt

extension LanguageModelV4ToolResultOutput: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .text(let value, let options):
      object(["type": "text", "value": .string(value), "providerOptions": metadata(options)])
    case .json(let value, let options):
      object(["type": "json", "value": value, "providerOptions": metadata(options)])
    case .errorText(let value, let options):
      object(["type": "error-text", "value": .string(value), "providerOptions": metadata(options)])
    case .errorJSON(let value, let options):
      object(["type": "error-json", "value": value, "providerOptions": metadata(options)])
    case .executionDenied(let reason, let options):
      object(["type": "execution-denied", "reason": string(reason), "providerOptions": metadata(options)])
    case .content(let parts):
      [
        "type": "content",
        "value": .array(
          parts.map { part in
            switch part {
            case .text(let text, let options):
              object(["type": "text", "text": .string(text), "providerOptions": metadata(options)])
            case .file(let data, let mediaType, let filename, let options):
              object([
                "type": "file", "data": data.json, "mediaType": .string(mediaType), "filename": string(filename),
                "providerOptions": metadata(options),
              ])
            case .custom(let options):
              object(["type": "custom", "providerOptions": metadata(options)])
            }
          }),
      ]
    }
  }

  public init(json: JSONValue) throws {
    let options = decodeMetadata(json["providerOptions"])
    switch json["type"]?.stringValue {
    case "text": self = .text(try requireString(json, "value"), providerOptions: options)
    case "json": self = .json(json["value"] ?? .null, providerOptions: options)
    case "error-text": self = .errorText(try requireString(json, "value"), providerOptions: options)
    case "error-json": self = .errorJSON(json["value"] ?? .null, providerOptions: options)
    case "execution-denied": self = .executionDenied(reason: json["reason"]?.stringValue, providerOptions: options)
    case "content":
      self = .content(
        try (json["value"]?.arrayValue ?? []).map { part in
          let partOptions = decodeMetadata(part["providerOptions"])
          switch part["type"]?.stringValue {
          case "text": return .text(try requireString(part, "text"), providerOptions: partOptions)
          case "file":
            return .file(
              data: try SharedV4FileData(json: part["data"] ?? .null), mediaType: try requireString(part, "mediaType"),
              filename: part["filename"]?.stringValue, providerOptions: partOptions)
          case "custom": return .custom(providerOptions: partOptions)
          default: throw unknownType(part, "tool result content")
          }
        })
    default: throw unknownType(json, "tool result output")
    }
  }
}

extension LanguageModelV4FilePart {
  fileprivate var json: JSONValue {
    object([
      "type": "file", "filename": string(filename), "data": data.json, "mediaType": .string(mediaType),
      "providerOptions": metadata(providerOptions),
    ])
  }

  fileprivate init(specificationJSON json: JSONValue) throws {
    self.init(
      data: try SharedV4FileData(json: json["data"] ?? .null), mediaType: try requireString(json, "mediaType"),
      filename: json["filename"]?.stringValue, providerOptions: decodeMetadata(json["providerOptions"]))
  }
}

extension LanguageModelV4ToolResultPart {
  fileprivate var json: JSONValue {
    object([
      "type": "tool-result", "toolCallId": .string(toolCallId), "toolName": .string(toolName), "output": output.json,
      "providerOptions": metadata(providerOptions),
    ])
  }

  fileprivate init(specificationJSON json: JSONValue) throws {
    self.init(
      toolCallId: try requireString(json, "toolCallId"), toolName: try requireString(json, "toolName"),
      output: try LanguageModelV4ToolResultOutput(json: json["output"] ?? .null),
      providerOptions: decodeMetadata(json["providerOptions"]))
  }
}

extension LanguageModelV4Message: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .system(let content, let options):
      object(["role": "system", "content": .string(content), "providerOptions": metadata(options)])
    case .user(let parts, let options):
      object([
        "role": "user",
        "content": .array(
          parts.map { part in
            switch part {
            case .text(let text):
              object(["type": "text", "text": .string(text.text), "providerOptions": metadata(text.providerOptions)])
            case .file(let file): file.json
            }
          }),
        "providerOptions": metadata(options),
      ])
    case .assistant(let parts, let options):
      object([
        "role": "assistant", "content": .array(parts.map(Self.assistantPartJSON)), "providerOptions": metadata(options),
      ])
    case .tool(let parts, let options):
      object([
        "role": "tool",
        "content": .array(
          parts.map { part in
            switch part {
            case .toolResult(let result): result.json
            case .toolApprovalResponse(let response):
              object([
                "type": "tool-approval-response", "approvalId": .string(response.approvalId),
                "approved": .bool(response.approved), "reason": string(response.reason),
                "providerOptions": metadata(response.providerOptions),
              ])
            }
          }),
        "providerOptions": metadata(options),
      ])
    }
  }

  private static func assistantPartJSON(_ part: LanguageModelV4AssistantContentPart) -> JSONValue {
    switch part {
    case .text(let text):
      object(["type": "text", "text": .string(text.text), "providerOptions": metadata(text.providerOptions)])
    case .file(let file): file.json
    case .custom(let custom):
      object(["type": "custom", "kind": .string(custom.kind), "providerOptions": metadata(custom.providerOptions)])
    case .reasoning(let reasoning):
      object(["type": "reasoning", "text": .string(reasoning.text), "providerOptions": metadata(reasoning.providerOptions)])
    case .reasoningFile(let file):
      object([
        "type": "reasoning-file", "data": file.data.json, "mediaType": .string(file.mediaType),
        "providerOptions": metadata(file.providerOptions),
      ])
    case .toolCall(let call):
      object([
        "type": "tool-call", "toolCallId": .string(call.toolCallId), "toolName": .string(call.toolName),
        "input": call.input, "providerExecuted": bool(call.providerExecuted),
        "providerOptions": metadata(call.providerOptions),
      ])
    case .toolResult(let result): result.json
    }
  }

  public init(json: JSONValue) throws {
    let options = decodeMetadata(json["providerOptions"])
    let content = json["content"]?.arrayValue ?? []
    switch json["role"]?.stringValue {
    case "system":
      self = .system(try requireString(json, "content"), providerOptions: options)
    case "user":
      self = .user(
        try content.map { part in
          switch part["type"]?.stringValue {
          case "text":
            return .text(
              LanguageModelV4TextPart(
                text: try requireString(part, "text"), providerOptions: decodeMetadata(part["providerOptions"])))
          case "file": return .file(try LanguageModelV4FilePart(specificationJSON: part))
          default: throw unknownType(part, "user content")
          }
        }, providerOptions: options)
    case "assistant":
      self = .assistant(try content.map(Self.assistantPart), providerOptions: options)
    case "tool":
      self = .tool(
        try content.map { part in
          switch part["type"]?.stringValue {
          case "tool-result": return .toolResult(try LanguageModelV4ToolResultPart(specificationJSON: part))
          case "tool-approval-response":
            return .toolApprovalResponse(
              LanguageModelV4ToolApprovalResponsePart(
                approvalId: try requireString(part, "approvalId"), approved: part["approved"]?.boolValue ?? false,
                reason: part["reason"]?.stringValue, providerOptions: decodeMetadata(part["providerOptions"])))
          default: throw unknownType(part, "tool content")
          }
        }, providerOptions: options)
    default:
      throw SpecificationDecodingError(message: "Unknown message role in \(json.jsonString()).")
    }
  }

  private static func assistantPart(_ part: JSONValue) throws -> LanguageModelV4AssistantContentPart {
    let options = decodeMetadata(part["providerOptions"])
    switch part["type"]?.stringValue {
    case "text": return .text(LanguageModelV4TextPart(text: try requireString(part, "text"), providerOptions: options))
    case "file": return .file(try LanguageModelV4FilePart(specificationJSON: part))
    case "custom": return .custom(LanguageModelV4CustomPart(kind: try requireString(part, "kind"), providerOptions: options))
    case "reasoning":
      return .reasoning(LanguageModelV4ReasoningPart(text: try requireString(part, "text"), providerOptions: options))
    case "reasoning-file":
      return .reasoningFile(
        LanguageModelV4ReasoningFilePart(
          data: try SharedV4FileData(json: part["data"] ?? .null), mediaType: try requireString(part, "mediaType"),
          providerOptions: options))
    case "tool-call":
      return .toolCall(
        LanguageModelV4ToolCallPart(
          toolCallId: try requireString(part, "toolCallId"), toolName: try requireString(part, "toolName"),
          input: part["input"] ?? .null, providerExecuted: part["providerExecuted"]?.boolValue, providerOptions: options))
    case "tool-result": return .toolResult(try LanguageModelV4ToolResultPart(specificationJSON: part))
    default: throw unknownType(part, "assistant content")
    }
  }
}

// MARK: - Call options

extension LanguageModelV4Tool: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .function(let tool):
      object([
        "type": "function", "name": .string(tool.name), "description": string(tool.description),
        "inputSchema": tool.inputSchema.value,
        "inputExamples": tool.inputExamples.map { .array($0.map { ["input": .object($0)] }) },
        "strict": bool(tool.strict), "providerOptions": metadata(tool.providerOptions),
      ])
    case .provider(let tool):
      ["type": "provider", "id": .string(tool.id), "name": .string(tool.name), "args": .object(tool.args)]
    }
  }

  public init(json: JSONValue) throws {
    switch json["type"]?.stringValue {
    case "function":
      self = .function(
        LanguageModelV4FunctionTool(
          name: try requireString(json, "name"), description: json["description"]?.stringValue,
          inputSchema: JSONSchema(json["inputSchema"] ?? ["type": "object"]),
          inputExamples: json["inputExamples"]?.arrayValue?.compactMap { $0["input"]?.objectValue },
          strict: json["strict"]?.boolValue, providerOptions: decodeMetadata(json["providerOptions"])))
    case "provider":
      self = .provider(
        LanguageModelV4ProviderTool(
          id: try requireString(json, "id"), name: try requireString(json, "name"), args: json["args"]?.objectValue ?? [:]))
    default: throw unknownType(json, "tool")
    }
  }
}

extension LanguageModelV4ToolChoice: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .auto: ["type": "auto"]
    case .none: ["type": "none"]
    case .required: ["type": "required"]
    case .tool(let toolName): ["type": "tool", "toolName": .string(toolName)]
    }
  }

  public init(json: JSONValue) throws {
    switch json["type"]?.stringValue {
    case "auto": self = .auto
    case "none": self = .none
    case "required": self = .required
    case "tool": self = .tool(toolName: try requireString(json, "toolName"))
    default: throw unknownType(json, "tool choice")
    }
  }
}

extension LanguageModelV4ResponseFormat: SpecificationJSONCodable {
  public var json: JSONValue {
    switch self {
    case .text: ["type": "text"]
    case .json(let schema, let name, let description):
      object(["type": "json", "schema": schema?.value, "name": string(name), "description": string(description)])
    }
  }

  public init(json: JSONValue) throws {
    switch json["type"]?.stringValue {
    case "text": self = .text
    case "json":
      self = .json(
        schema: json["schema"].map(JSONSchema.init), name: json["name"]?.stringValue,
        description: json["description"]?.stringValue)
    default: throw unknownType(json, "response format")
    }
  }
}

extension LanguageModelV4CallOptions: SpecificationJSONCodable {
  public var json: JSONValue {
    object([
      "prompt": .array(prompt.map(\.json)),
      "maxOutputTokens": number(maxOutputTokens),
      "temperature": number(temperature),
      "stopSequences": stopSequences.map { .array($0.map(JSONValue.string)) },
      "topP": number(topP),
      "topK": number(topK),
      "presencePenalty": number(presencePenalty),
      "frequencyPenalty": number(frequencyPenalty),
      "responseFormat": responseFormat?.json,
      "seed": number(seed),
      "tools": tools.map { .array($0.map(\.json)) },
      "toolChoice": toolChoice?.json,
      "includeRawChunks": bool(includeRawChunks),
      "headers": headers.map { .object($0.mapValues(JSONValue.string)) },
      "reasoning": string(reasoning?.rawValue),
      "providerOptions": metadata(providerOptions),
    ])
  }

  public init(json: JSONValue) throws {
    self.init(
      prompt: try (json["prompt"]?.arrayValue ?? []).map(LanguageModelV4Message.init(json:)),
      maxOutputTokens: json["maxOutputTokens"]?.intValue,
      temperature: json["temperature"]?.doubleValue,
      stopSequences: json["stopSequences"]?.arrayValue?.compactMap(\.stringValue),
      topP: json["topP"]?.doubleValue,
      topK: json["topK"]?.intValue,
      presencePenalty: json["presencePenalty"]?.doubleValue,
      frequencyPenalty: json["frequencyPenalty"]?.doubleValue,
      responseFormat: try json["responseFormat"].map(LanguageModelV4ResponseFormat.init(json:)),
      seed: json["seed"]?.intValue,
      tools: try json["tools"]?.arrayValue?.map(LanguageModelV4Tool.init(json:)),
      toolChoice: try json["toolChoice"].map(LanguageModelV4ToolChoice.init(json:)),
      includeRawChunks: json["includeRawChunks"]?.boolValue,
      headers: json["headers"]?.objectValue?.compactMapValues(\.stringValue),
      reasoning: json["reasoning"]?.stringValue.flatMap(LanguageModelV4ReasoningEffort.init(rawValue:)),
      providerOptions: decodeMetadata(json["providerOptions"]))
  }
}
