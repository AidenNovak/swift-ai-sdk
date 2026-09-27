import AISDKProviderUtils
import Foundation

/// Converts between the upstream TypeScript JSON shapes and the Swift spec
/// types, so conformance tests can replay cases recorded by running vercel/ai
/// itself (see `Tools/conformance`).
public enum UpstreamConformance {
  public struct DecodingError: Error, CustomStringConvertible {
    public var description: String
  }

  private static func fail(_ message: String) -> DecodingError { DecodingError(description: message) }

  private static func providerOptions(_ value: JSONValue?) -> SharedV4ProviderOptions? {
    guard case .object(let object)? = value else { return nil }
    return object.compactMapValues { $0.objectValue }
  }

  // MARK: Decoding call options

  public static func callOptions(_ json: JSONValue) throws -> LanguageModelV4CallOptions {
    let responseFormat: LanguageModelV4ResponseFormat? =
      switch json["responseFormat"]?["type"]?.stringValue {
      case "json"?:
        .json(
          schema: json["responseFormat"]?["schema"].map(JSONSchema.init), name: json["responseFormat"]?["name"]?.stringValue,
          description: json["responseFormat"]?["description"]?.stringValue)
      case "text"?: .text
      default: nil
      }
    return LanguageModelV4CallOptions(
      prompt: try prompt(json["prompt"] ?? []),
      maxOutputTokens: json["maxOutputTokens"]?.intValue,
      temperature: json["temperature"]?.doubleValue,
      stopSequences: json["stopSequences"]?.arrayValue?.compactMap(\.stringValue),
      topP: json["topP"]?.doubleValue,
      topK: json["topK"]?.intValue,
      presencePenalty: json["presencePenalty"]?.doubleValue,
      frequencyPenalty: json["frequencyPenalty"]?.doubleValue,
      responseFormat: responseFormat,
      seed: json["seed"]?.intValue,
      tools: try json["tools"]?.arrayValue?.map(tool),
      toolChoice: try json["toolChoice"].map(toolChoice),
      reasoning: json["reasoning"]?.stringValue.flatMap(LanguageModelV4ReasoningEffort.init(rawValue:)),
      providerOptions: providerOptions(json["providerOptions"]))
  }

  public static func tool(_ json: JSONValue) throws -> LanguageModelV4Tool {
    switch json["type"]?.stringValue {
    case "function":
      return .function(
        LanguageModelV4FunctionTool(
          name: json["name"]?.stringValue ?? "", description: json["description"]?.stringValue,
          inputSchema: JSONSchema(json["inputSchema"] ?? ["type": "object"]),
          inputExamples: json["inputExamples"]?.arrayValue?.compactMap { $0["input"]?.objectValue },
          strict: json["strict"]?.boolValue, providerOptions: providerOptions(json["providerOptions"])))
    case "provider":
      return .provider(
        LanguageModelV4ProviderTool(
          id: json["id"]?.stringValue ?? "", name: json["name"]?.stringValue ?? "", args: json["args"]?.objectValue ?? [:]))
    default:
      throw fail("unknown tool \(json)")
    }
  }

  public static func toolChoice(_ json: JSONValue) throws -> LanguageModelV4ToolChoice {
    switch json["type"]?.stringValue {
    case "auto": .auto
    case "none": .none
    case "required": .required
    case "tool": .tool(toolName: json["toolName"]?.stringValue ?? "")
    default: throw fail("unknown tool choice \(json)")
    }
  }

  public static func fileData(_ json: JSONValue) throws -> SharedV4FileData {
    switch json["type"]?.stringValue {
    case "data": return .base64(json["data"]?.stringValue ?? "")
    case "url":
      guard let url = json["url"]?.stringValue.flatMap(URL.init(string:)) else { throw fail("bad url \(json)") }
      return .url(url)
    case "reference":
      return .reference((json["reference"]?.objectValue ?? [:]).compactMapValues(\.stringValue))
    case "text": return .text(json["text"]?.stringValue ?? "")
    default: throw fail("unknown file data \(json)")
    }
  }

  public static func toolResultOutput(_ json: JSONValue) throws -> LanguageModelV4ToolResultOutput {
    let options = providerOptions(json["providerOptions"])
    switch json["type"]?.stringValue {
    case "text": return .text(json["value"]?.stringValue ?? "", providerOptions: options)
    case "json": return .json(json["value"] ?? .null, providerOptions: options)
    case "error-text": return .errorText(json["value"]?.stringValue ?? "", providerOptions: options)
    case "error-json": return .errorJSON(json["value"] ?? .null, providerOptions: options)
    case "execution-denied": return .executionDenied(reason: json["reason"]?.stringValue, providerOptions: options)
    case "content":
      return .content(
        try (json["value"]?.arrayValue ?? []).map { part in
          let partOptions = providerOptions(part["providerOptions"])
          switch part["type"]?.stringValue {
          case "text": return .text(part["text"]?.stringValue ?? "", providerOptions: partOptions)
          case "file":
            return .file(
              data: try fileData(part["data"] ?? .null), mediaType: part["mediaType"]?.stringValue ?? "",
              filename: part["filename"]?.stringValue, providerOptions: partOptions)
          default: return .custom(providerOptions: partOptions)
          }
        })
    default: throw fail("unknown tool result output \(json)")
    }
  }

  public static func prompt(_ json: JSONValue) throws -> LanguageModelV4Prompt {
    try (json.arrayValue ?? []).map { message in
      let options = providerOptions(message["providerOptions"])
      let content = message["content"]?.arrayValue ?? []
      switch message["role"]?.stringValue {
      case "system":
        return .system(message["content"]?.stringValue ?? "", providerOptions: options)
      case "user":
        return .user(
          try content.map { part in
            let partOptions = providerOptions(part["providerOptions"])
            switch part["type"]?.stringValue {
            case "text": return .text(LanguageModelV4TextPart(text: part["text"]?.stringValue ?? "", providerOptions: partOptions))
            case "file":
              return .file(
                LanguageModelV4FilePart(
                  data: try fileData(part["data"] ?? .null), mediaType: part["mediaType"]?.stringValue ?? "",
                  filename: part["filename"]?.stringValue, providerOptions: partOptions))
            default: throw fail("unknown user part \(part)")
            }
          }, providerOptions: options)
      case "assistant":
        return .assistant(try content.map(assistantPart), providerOptions: options)
      case "tool":
        return .tool(
          try content.map { part in
            let partOptions = providerOptions(part["providerOptions"])
            switch part["type"]?.stringValue {
            case "tool-result":
              return .toolResult(
                LanguageModelV4ToolResultPart(
                  toolCallId: part["toolCallId"]?.stringValue ?? "", toolName: part["toolName"]?.stringValue ?? "",
                  output: try toolResultOutput(part["output"] ?? .null), providerOptions: partOptions))
            case "tool-approval-response":
              return .toolApprovalResponse(
                LanguageModelV4ToolApprovalResponsePart(
                  approvalId: part["approvalId"]?.stringValue ?? "", approved: part["approved"]?.boolValue ?? false,
                  reason: part["reason"]?.stringValue, providerOptions: partOptions))
            default: throw fail("unknown tool part \(part)")
            }
          }, providerOptions: options)
      default:
        throw fail("unknown message \(message)")
      }
    }
  }

  private static func assistantPart(_ part: JSONValue) throws -> LanguageModelV4AssistantContentPart {
    let options = providerOptions(part["providerOptions"])
    switch part["type"]?.stringValue {
    case "text": return .text(LanguageModelV4TextPart(text: part["text"]?.stringValue ?? "", providerOptions: options))
    case "reasoning":
      return .reasoning(LanguageModelV4ReasoningPart(text: part["text"]?.stringValue ?? "", providerOptions: options))
    case "tool-call":
      return .toolCall(
        LanguageModelV4ToolCallPart(
          toolCallId: part["toolCallId"]?.stringValue ?? "", toolName: part["toolName"]?.stringValue ?? "",
          input: part["input"] ?? .null, providerExecuted: part["providerExecuted"]?.boolValue, providerOptions: options))
    case "tool-result":
      return .toolResult(
        LanguageModelV4ToolResultPart(
          toolCallId: part["toolCallId"]?.stringValue ?? "", toolName: part["toolName"]?.stringValue ?? "",
          output: try toolResultOutput(part["output"] ?? .null), providerOptions: options))
    case "custom":
      return .custom(LanguageModelV4CustomPart(kind: part["kind"]?.stringValue ?? "", providerOptions: options))
    default:
      throw fail("unknown assistant part \(part)")
    }
  }

  // MARK: Encoding results

  private static func metadata(_ value: SharedV4ProviderMetadata?) -> JSONValue? {
    value.map { .object($0.mapValues(JSONValue.object)) }
  }

  public static func json(_ warning: SharedV4Warning) -> JSONValue {
    switch warning {
    case .unsupported(let feature, let details):
      jsonObject(["type": "unsupported", "feature": .string(feature), "details": .optional(details)])
    case .compatibility(let feature, let details):
      jsonObject(["type": "compatibility", "feature": .string(feature), "details": .optional(details)])
    case .deprecated(let setting, let message):
      ["type": "deprecated", "setting": .string(setting), "message": .string(message)]
    case .other(let message):
      ["type": "other", "message": .string(message)]
    }
  }

  public static func json(_ usage: LanguageModelV4Usage) -> JSONValue {
    jsonObject([
      "inputTokens": jsonObject([
        "total": .optional(usage.inputTokens.total), "noCache": .optional(usage.inputTokens.noCache),
        "cacheRead": .optional(usage.inputTokens.cacheRead), "cacheWrite": .optional(usage.inputTokens.cacheWrite),
      ]),
      "outputTokens": jsonObject([
        "total": .optional(usage.outputTokens.total), "text": .optional(usage.outputTokens.text),
        "reasoning": .optional(usage.outputTokens.reasoning),
      ]),
      "raw": usage.raw.map(JSONValue.object),
    ])
  }

  public static func json(_ finishReason: LanguageModelV4FinishReason) -> JSONValue {
    jsonObject(["unified": .string(finishReason.unified.rawValue), "raw": .optional(finishReason.raw)])
  }

  public static func json(_ source: LanguageModelV4Source) -> JSONValue {
    switch source {
    case .url(let id, let url, let title, let providerMetadata):
      jsonObject([
        "type": "source", "sourceType": "url", "id": .string(id), "url": .string(url), "title": .optional(title),
        "providerMetadata": metadata(providerMetadata),
      ])
    case .document(let id, let mediaType, let title, let filename, let providerMetadata):
      jsonObject([
        "type": "source", "sourceType": "document", "id": .string(id), "mediaType": .string(mediaType),
        "title": .string(title), "filename": .optional(filename), "providerMetadata": metadata(providerMetadata),
      ])
    }
  }

  public static func json(_ call: LanguageModelV4ToolCall) -> JSONValue {
    jsonObject([
      "type": "tool-call", "toolCallId": .string(call.toolCallId), "toolName": .string(call.toolName),
      "input": .string(call.input), "providerExecuted": .optional(call.providerExecuted), "dynamic": .optional(call.dynamic),
      "providerMetadata": metadata(call.providerMetadata),
    ])
  }

  public static func json(_ result: LanguageModelV4ToolResult) -> JSONValue {
    jsonObject([
      "type": "tool-result", "toolCallId": .string(result.toolCallId), "toolName": .string(result.toolName),
      "result": result.result, "isError": .optional(result.isError), "preliminary": .optional(result.preliminary),
      "dynamic": .optional(result.dynamic), "providerMetadata": metadata(result.providerMetadata),
    ])
  }

  public static func json(_ content: LanguageModelV4Content) -> JSONValue {
    switch content {
    case .text(let text):
      jsonObject(["type": "text", "text": .string(text.text), "providerMetadata": metadata(text.providerMetadata)])
    case .reasoning(let reasoning):
      jsonObject(["type": "reasoning", "text": .string(reasoning.text), "providerMetadata": metadata(reasoning.providerMetadata)])
    case .custom(let custom):
      jsonObject(["type": "custom", "kind": .string(custom.kind), "providerMetadata": metadata(custom.providerMetadata)])
    case .file(let file):
      jsonObject([
        "type": "file", "mediaType": .string(file.mediaType), "data": .optional(file.data.base64String),
        "providerMetadata": metadata(file.providerMetadata),
      ])
    case .reasoningFile(let file):
      jsonObject([
        "type": "reasoning-file", "mediaType": .string(file.mediaType), "data": .optional(file.data.base64String),
        "providerMetadata": metadata(file.providerMetadata),
      ])
    case .toolApprovalRequest(let request):
      jsonObject([
        "type": "tool-approval-request", "approvalId": .string(request.approvalId), "toolCallId": .string(request.toolCallId),
        "providerMetadata": metadata(request.providerMetadata),
      ])
    case .source(let source): json(source)
    case .toolCall(let call): json(call)
    case .toolResult(let result): json(result)
    }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public static func json(_ part: LanguageModelV4StreamPart) -> JSONValue {
    switch part {
    case .textStart(let id, let providerMetadata):
      jsonObject(["type": "text-start", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .textDelta(let id, let delta, let providerMetadata):
      jsonObject(["type": "text-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata)])
    case .textEnd(let id, let providerMetadata):
      jsonObject(["type": "text-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .reasoningStart(let id, let providerMetadata):
      jsonObject(["type": "reasoning-start", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .reasoningDelta(let id, let delta, let providerMetadata):
      jsonObject([
        "type": "reasoning-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata),
      ])
    case .reasoningEnd(let id, let providerMetadata):
      jsonObject(["type": "reasoning-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .toolInputStart(let start):
      jsonObject([
        "type": "tool-input-start", "id": .string(start.id), "toolName": .string(start.toolName),
        "providerMetadata": metadata(start.providerMetadata), "providerExecuted": .optional(start.providerExecuted),
        "dynamic": .optional(start.dynamic), "title": .optional(start.title),
      ])
    case .toolInputDelta(let id, let delta, let providerMetadata):
      jsonObject([
        "type": "tool-input-delta", "id": .string(id), "delta": .string(delta), "providerMetadata": metadata(providerMetadata),
      ])
    case .toolInputEnd(let id, let providerMetadata):
      jsonObject(["type": "tool-input-end", "id": .string(id), "providerMetadata": metadata(providerMetadata)])
    case .toolApprovalRequest(let request): json(LanguageModelV4Content.toolApprovalRequest(request))
    case .toolCall(let call): json(call)
    case .toolResult(let result): json(result)
    case .custom(let custom): json(LanguageModelV4Content.custom(custom))
    case .file(let file): json(LanguageModelV4Content.file(file))
    case .reasoningFile(let file): json(LanguageModelV4Content.reasoningFile(file))
    case .source(let source): json(source)
    case .streamStart(let warnings): ["type": "stream-start", "warnings": .array(warnings.map(json))]
    case .responseMetadata(let responseMetadata):
      jsonObject([
        "type": "response-metadata", "id": .optional(responseMetadata.id),
        "timestamp": responseMetadata.timestamp.map { .string(timestamp($0)) },
        "modelId": .optional(responseMetadata.modelId),
      ])
    case .finish(let usage, let finishReason, let providerMetadata):
      jsonObject([
        "type": "finish", "usage": json(usage), "finishReason": json(finishReason),
        "providerMetadata": metadata(providerMetadata),
      ])
    case .raw(let rawValue): ["type": "raw", "rawValue": rawValue]
    case .error(let error):
      ["type": "error", "message": .string((error as? any AISDKError)?.message ?? String(describing: error))]
    }
  }

  // MARK: Decoding stream parts

  /// Decodes an upstream `LanguageModelV4StreamPart` (as written by `JSON.stringify`).
  public static func streamPart(_ json: JSONValue) throws -> LanguageModelV4StreamPart {
    let metadata = providerOptions(json["providerMetadata"])
    func string(_ key: String) throws -> String {
      guard let value = json[key]?.stringValue else { throw fail("missing \(key) in \(json)") }
      return value
    }
    switch json["type"]?.stringValue {
    case "text-start": return .textStart(id: try string("id"), providerMetadata: metadata)
    case "text-delta": return .textDelta(id: try string("id"), delta: try string("delta"), providerMetadata: metadata)
    case "text-end": return .textEnd(id: try string("id"), providerMetadata: metadata)
    case "reasoning-start": return .reasoningStart(id: try string("id"), providerMetadata: metadata)
    case "reasoning-delta":
      return .reasoningDelta(id: try string("id"), delta: try string("delta"), providerMetadata: metadata)
    case "reasoning-end": return .reasoningEnd(id: try string("id"), providerMetadata: metadata)
    case "tool-input-start":
      return .toolInputStart(
        LanguageModelV4ToolInputStart(
          id: try string("id"), toolName: try string("toolName"), providerMetadata: metadata,
          providerExecuted: json["providerExecuted"]?.boolValue, dynamic: json["dynamic"]?.boolValue,
          title: json["title"]?.stringValue))
    case "tool-input-delta":
      return .toolInputDelta(id: try string("id"), delta: try string("delta"), providerMetadata: metadata)
    case "tool-input-end": return .toolInputEnd(id: try string("id"), providerMetadata: metadata)
    case "tool-call":
      return .toolCall(
        LanguageModelV4ToolCall(
          toolCallId: try string("toolCallId"), toolName: try string("toolName"), input: try string("input"),
          providerExecuted: json["providerExecuted"]?.boolValue, dynamic: json["dynamic"]?.boolValue,
          providerMetadata: metadata))
    case "tool-result":
      return .toolResult(
        LanguageModelV4ToolResult(
          toolCallId: try string("toolCallId"), toolName: try string("toolName"), result: json["result"] ?? .null,
          isError: json["isError"]?.boolValue, preliminary: json["preliminary"]?.boolValue,
          dynamic: json["dynamic"]?.boolValue, providerMetadata: metadata))
    case "tool-approval-request":
      return .toolApprovalRequest(
        LanguageModelV4ToolApprovalRequest(
          approvalId: try string("approvalId"), toolCallId: try string("toolCallId"), providerMetadata: metadata))
    case "custom": return .custom(LanguageModelV4CustomContent(kind: try string("kind"), providerMetadata: metadata))
    case "file":
      return .file(
        LanguageModelV4File(mediaType: try string("mediaType"), data: try fileData(json["data"] ?? .null), providerMetadata: metadata))
    case "reasoning-file":
      return .reasoningFile(
        LanguageModelV4ReasoningFile(
          mediaType: try string("mediaType"), data: try fileData(json["data"] ?? .null), providerMetadata: metadata))
    case "source":
      if json["sourceType"]?.stringValue == "document" {
        return .source(
          .document(
            id: try string("id"), mediaType: try string("mediaType"), title: try string("title"),
            filename: json["filename"]?.stringValue, providerMetadata: metadata))
      }
      return .source(
        .url(id: try string("id"), url: try string("url"), title: json["title"]?.stringValue, providerMetadata: metadata))
    case "stream-start": return .streamStart(warnings: [])
    case "response-metadata":
      return .responseMetadata(
        LanguageModelV4ResponseMetadata(
          id: json["id"]?.stringValue,
          timestamp: json["timestamp"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) },
          modelId: json["modelId"]?.stringValue))
    case "finish":
      let usage = json["usage"] ?? [:]
      let reason = json["finishReason"] ?? [:]
      return .finish(
        usage: LanguageModelV4Usage(
          inputTokens: .init(
            total: usage["inputTokens"]?["total"]?.intValue, noCache: usage["inputTokens"]?["noCache"]?.intValue,
            cacheRead: usage["inputTokens"]?["cacheRead"]?.intValue,
            cacheWrite: usage["inputTokens"]?["cacheWrite"]?.intValue),
          outputTokens: .init(
            total: usage["outputTokens"]?["total"]?.intValue, text: usage["outputTokens"]?["text"]?.intValue,
            reasoning: usage["outputTokens"]?["reasoning"]?.intValue)),
        finishReason: LanguageModelV4FinishReason(
          unified: LanguageModelV4FinishReason.Unified(rawValue: reason["unified"]?.stringValue ?? "") ?? .other,
          raw: reason["raw"]?.stringValue),
        providerMetadata: metadata)
    case "raw": return .raw(rawValue: json["rawValue"] ?? .null)
    case "error":
      return .error(DecodingError(description: json["error"]?.stringValue ?? json["error"]?.jsonString() ?? "error"))
    default: throw fail("unknown stream part \(json)")
    }
  }

  // MARK: Comparing

  /// Differences between an expected and actual JSON value, by path. Strings
  /// that are both valid JSON compare by their parsed value, since Swift
  /// serializes objects with sorted keys while JavaScript keeps insertion order.
  public static func differences(_ expected: JSONValue, _ actual: JSONValue, path: String = "$") -> [String] {
    switch (expected, actual) {
    case (.object(let e), .object(let a)):
      return Set(e.keys).union(a.keys).sorted().flatMap { key -> [String] in
        switch (e[key], a[key]) {
        case (let ev?, let av?): differences(ev, av, path: "\(path).\(key)")
        case (let ev?, nil): ["\(path).\(key): missing, expected \(ev.jsonString())"]
        case (nil, let av?): ["\(path).\(key): unexpected \(av.jsonString())"]
        case (nil, nil): []
        }
      }
    case (.array(let e), .array(let a)):
      guard e.count == a.count else {
        return ["\(path): expected \(e.count) elements, got \(a.count)"]
          + zip(e, a).enumerated().flatMap { differences($1.0, $1.1, path: "\(path)[\($0)]") }.prefix(5)
      }
      return zip(e, a).enumerated().flatMap { differences($1.0, $1.1, path: "\(path)[\($0)]") }
    case (.string(let e), .string(let a)) where e != a:
      if let ej = try? JSONValue(jsonString: e), let aj = try? JSONValue(jsonString: a), ej.isContainer, aj.isContainer {
        return differences(ej, aj, path: "\(path)<json>")
      }
      return ["\(path): expected \(expected.jsonString()), got \(actual.jsonString())"]
    case (.number(let e), .number(let a)):
      return abs(e - a) < 1e-9 ? [] : ["\(path): expected \(e), got \(a)"]
    default:
      return expected == actual ? [] : ["\(path): expected \(expected.jsonString()), got \(actual.jsonString())"]
    }
  }
}

extension JSONValue {
  fileprivate var isContainer: Bool {
    switch self {
    case .object, .array: true
    default: false
    }
  }
}
