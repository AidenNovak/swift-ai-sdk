/// A JSON Schema (draft 7) document. Mirrors upstream `JSONSchema7`.
///
/// The schema is stored as raw JSON so that every keyword round-trips
/// unchanged to the provider.
public struct JSONSchema: Sendable, Hashable, Codable {
  public var value: JSONValue

  public init(_ value: JSONValue) {
    self.value = value
  }

  public init(from decoder: any Decoder) throws {
    value = try JSONValue(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    try value.encode(to: encoder)
  }

  /// The top-level `type` keyword, when it is a single string.
  public var type: String? { value["type"]?.stringValue }
}

extension JSONSchema: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    value = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
