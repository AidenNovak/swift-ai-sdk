import Foundation

/// The model generated no valid object. Mirrors upstream `NoObjectGeneratedError`.
public struct NoObjectGeneratedError: AISDKError {
  public let name = "AI_NoObjectGeneratedError"
  public let message: String
  public let cause: (any Error)?
  /// The text the model generated.
  public let text: String?
  public let response: LanguageModelResponseMetadata?
  public let usage: LanguageModelUsage?
  public let finishReason: FinishReason?

  public init(
    message: String = "No object generated.",
    cause: (any Error)? = nil,
    text: String? = nil,
    response: LanguageModelResponseMetadata? = nil,
    usage: LanguageModelUsage? = nil,
    finishReason: FinishReason? = nil
  ) {
    self.message = message
    self.cause = cause
    self.text = text
    self.response = response
    self.usage = usage
    self.finishReason = finishReason
  }
}

/// Context passed when parsing the complete output.
public struct OutputContext: Sendable {
  public var response: LanguageModelResponseMetadata
  public var usage: LanguageModelUsage
  public var finishReason: FinishReason
}

/// Describes the output of `generateText` / `streamText`. Mirrors upstream `Output`.
///
/// - `Value`: the parsed complete output.
/// - `Partial`: the partial output while streaming.
/// - `Element`: the elements emitted by `elementStream` (arrays only).
public struct Output<Value: Sendable, Partial: Sendable & Equatable, Element: Sendable>: Sendable {
  public let name: String
  /// The response format sent to the model.
  public let responseFormat: LanguageModelV4ResponseFormat
  let parseComplete: @Sendable (String, OutputContext) throws -> Value
  let parsePartial: @Sendable (String) -> Partial?
  let elements: (@Sendable (Partial) -> [Element])?

  public init(
    name: String,
    responseFormat: LanguageModelV4ResponseFormat,
    parseComplete: @escaping @Sendable (String, OutputContext) throws -> Value,
    parsePartial: @escaping @Sendable (String) -> Partial?,
    elements: (@Sendable (Partial) -> [Element])? = nil
  ) {
    self.name = name
    self.responseFormat = responseFormat
    self.parseComplete = parseComplete
    self.parsePartial = parsePartial
    self.elements = elements
  }

  /// Parses the complete output text.
  public func parseCompleteOutput(_ text: String, context: OutputContext) throws -> Value {
    try parseComplete(text, context)
  }

  /// Parses partial output text, or returns `nil` when nothing can be parsed yet.
  public func parsePartialOutput(_ text: String) -> Partial? {
    parsePartial(text)
  }
}

/// A type with no values, for outputs without an element stream.
public enum NoElement: Sendable {}

private func parseFailure(_ cause: any Error, text: String, context: OutputContext) -> NoObjectGeneratedError {
  NoObjectGeneratedError(
    message: "No object generated: could not parse the response.", cause: cause, text: text,
    response: context.response, usage: context.usage, finishReason: context.finishReason)
}

private func schemaFailure(_ cause: any Error, text: String, context: OutputContext) -> NoObjectGeneratedError {
  NoObjectGeneratedError(
    message: "No object generated: response did not match schema.", cause: cause, text: text,
    response: context.response, usage: context.usage, finishReason: context.finishReason)
}

private func parseOrThrow(_ text: String, context: OutputContext) throws -> JSONValue {
  switch safeParseJSON(text) {
  case .success(let value, _): return value
  case .failure(let error, _): throw parseFailure(error, text: text, context: context)
  }
}

extension Output where Value == String, Partial == String, Element == NoElement {
  /// Plain text output. Mirrors upstream `Output.text()`.
  public static func text() -> Output {
    Output(
      name: "text", responseFormat: .text, parseComplete: { text, _ in text }, parsePartial: { $0 })
  }

  /// One of the given options. Mirrors upstream `Output.choice()`.
  public static func choice(_ options: [String], name: String? = nil, description: String? = nil) -> Output {
    Output(
      name: "choice",
      responseFormat: .json(
        schema: [
          "$schema": "http://json-schema.org/draft-07/schema#",
          "type": "object",
          "properties": ["result": ["type": "string", "enum": .array(options.map(JSONValue.string))]],
          "required": ["result"],
          "additionalProperties": false,
        ],
        name: name, description: description),
      parseComplete: { text, context in
        let value = try parseOrThrow(text, context: context)
        guard let result = value["result"]?.stringValue, options.contains(result) else {
          throw schemaFailure(
            TypeValidationError(
              value: value,
              cause: InvalidArgumentError(
                argument: "result", message: "response must be an object that contains a choice value.")),
            text: text, context: context)
        }
        return result
      },
      parsePartial: { text in
        let parsed = parsePartialJson(text)
        guard let result = parsed.value?["result"]?.stringValue else { return nil }
        let matches = options.filter { $0.hasPrefix(result) }
        if parsed.state == .successfulParse {
          return matches.contains(result) ? result : nil
        }
        return matches.count == 1 ? matches[0] : nil
      })
  }
}

extension Output where Partial == JSONValue, Element == NoElement {
  /// An object matching the schema. The partial output is the partially
  /// parsed JSON, since Swift has no deep-partial types. Mirrors upstream `Output.object()`.
  public static func object(schema: Schema<Value>, name: String? = nil, description: String? = nil) -> Output {
    Output(
      name: "object",
      responseFormat: .json(schema: schema.jsonSchema, name: name, description: description),
      parseComplete: { text, context in
        let value = try parseOrThrow(text, context: context)
        do {
          return try validateTypes(value: value, schema: schema)
        } catch {
          throw schemaFailure(error, text: text, context: context)
        }
      },
      parsePartial: { text in
        let parsed = parsePartialJson(text)
        switch parsed.state {
        case .successfulParse, .repairedParse: return parsed.value
        case .failedParse, .undefinedInput: return nil
        }
      })
  }
}

extension Output where Value == JSONValue, Partial == JSONValue, Element == NoElement {
  /// Any JSON value, without a schema. Mirrors upstream `Output.json()`.
  public static func json(name: String? = nil, description: String? = nil) -> Output {
    Output(
      name: "json",
      responseFormat: .json(schema: nil, name: name, description: description),
      parseComplete: { text, context in try parseOrThrow(text, context: context) },
      parsePartial: { text in
        let parsed = parsePartialJson(text)
        switch parsed.state {
        case .successfulParse, .repairedParse: return parsed.value
        case .failedParse, .undefinedInput: return nil
        }
      })
  }
}

/// Elements of a streamed array, compared by their JSON.
public struct ArrayPartial<Element: Sendable>: Sendable, Equatable {
  public var elements: [Element]
  let json: [JSONValue]

  public static func == (lhs: ArrayPartial, rhs: ArrayPartial) -> Bool { lhs.json == rhs.json }
}

extension Output where Value == [Element], Partial == ArrayPartial<Element> {
  /// An array of elements matching the element schema. The model is asked for
  /// `{"elements": [...]}`. Mirrors upstream `Output.array()`.
  public static func array(
    element: Schema<Element>, minItems: Int? = nil, maxItems: Int? = nil, name: String? = nil, description: String? = nil
  ) throws -> Output {
    typealias E = Element
    for (bound, value) in [("minItems", minItems), ("maxItems", maxItems)] {
      if let value, value < 0 {
        throw InvalidArgumentError(argument: bound, message: "\(bound) must be greater than or equal to 0")
      }
    }
    if let minItems, let maxItems, minItems > maxItems {
      throw InvalidArgumentError(argument: "minItems", message: "minItems must be less than or equal to maxItems")
    }

    var itemSchema = element.jsonSchema.value.objectValue ?? [:]
    let definitions = itemSchema.removeValue(forKey: "definitions")
    let defs = itemSchema.removeValue(forKey: "$defs")
    itemSchema.removeValue(forKey: "$schema")
    var arraySchema: JSONObject = ["type": "array", "items": .object(itemSchema)]
    if let minItems { arraySchema["minItems"] = .number(Double(minItems)) }
    if let maxItems { arraySchema["maxItems"] = .number(Double(maxItems)) }
    var schema: JSONObject = [
      "$schema": "http://json-schema.org/draft-07/schema#",
      "type": "object",
      "properties": ["elements": .object(arraySchema)],
      "required": ["elements"],
      "additionalProperties": false,
    ]
    if let definitions { schema["definitions"] = definitions }
    if let defs { schema["$defs"] = defs }

    @Sendable func lengthError(_ elements: [JSONValue]) -> TypeValidationError? {
      if let minItems, elements.count < minItems {
        return TypeValidationError(
          value: .array(elements),
          cause: InvalidArgumentError(argument: "elements", message: "elements array must contain at least \(minItems) items"))
      }
      if let maxItems, elements.count > maxItems {
        return TypeValidationError(
          value: .array(elements),
          cause: InvalidArgumentError(argument: "elements", message: "elements array must contain at most \(maxItems) items"))
      }
      return nil
    }

    return Output(
      name: "array",
      responseFormat: .json(schema: JSONSchema(.object(schema)), name: name, description: description),
      parseComplete: { text, context in
        let value = try parseOrThrow(text, context: context)
        guard let elements = value["elements"]?.arrayValue else {
          throw schemaFailure(
            TypeValidationError(
              value: value,
              cause: InvalidArgumentError(argument: "elements", message: "response must be an object with an elements array")),
            text: text, context: context)
        }
        if let error = lengthError(elements) { throw schemaFailure(error, text: text, context: context) }
        do {
          return try elements.map { try validateTypes(value: $0, schema: element) }
        } catch {
          throw schemaFailure(error, text: text, context: context)
        }
      },
      parsePartial: { text in
        let parsed = parsePartialJson(text)
        guard parsed.state == .successfulParse || parsed.state == .repairedParse,
          var raw = parsed.value?["elements"]?.arrayValue
        else { return nil }
        // The last element of a repaired parse may still be incomplete.
        if parsed.state == .repairedParse, !raw.isEmpty { raw.removeLast() }
        var valid: [E] = []
        var json: [JSONValue] = []
        for item in raw {
          if let value = try? element.validate(item) {
            valid.append(value)
            json.append(item)
          }
        }
        return ArrayPartial(elements: valid, json: json)
      },
      elements: { $0.elements })
  }
}
