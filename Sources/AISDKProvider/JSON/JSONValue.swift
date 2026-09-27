import Foundation

/// A JSON value. Mirrors upstream `JSONValue`.
///
/// Used wherever the upstream specification carries `unknown` or `JSONValue`
/// payloads, such as tool inputs, provider options and raw response bodies.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

/// A JSON object. Mirrors upstream `JSONObject`.
public typealias JSONObject = [String: JSONValue]

/// A JSON array. Mirrors upstream `JSONArray`.
public typealias JSONArray = [JSONValue]

// MARK: - Accessors

extension JSONValue {
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// The number as an `Int` when it is integral and representable.
  public var intValue: Int? {
    guard case .number(let value) = self, value.rounded() == value,
      let int = Int(exactly: value)
    else { return nil }
    return int
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Object member access. Returns `nil` for non-objects and missing keys.
  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  /// Array element access. Returns `nil` for non-arrays and out-of-range indices.
  public subscript(index: Int) -> JSONValue? {
    guard let array = arrayValue, array.indices.contains(index) else { return nil }
    return array[index]
  }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

// MARK: - Codable

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Value is not valid JSON.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      if value.rounded() == value, abs(value) < 9_007_199_254_740_992,
        let int = Int64(exactly: value)
      {
        try container.encode(int)
      } else {
        try container.encode(value)
      }
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

// MARK: - Serialization

extension JSONValue {
  /// Parses JSON data.
  public init(jsonData: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
  }

  /// Parses a JSON string.
  public init(jsonString: String) throws {
    try self.init(jsonData: Data(jsonString.utf8))
  }

  /// Converts any `Encodable` value into a `JSONValue`.
  public init(encoding value: some Encodable) throws {
    let data = try JSONEncoder().encode(value)
    try self.init(jsonData: data)
  }

  /// Serializes the value to JSON data. Keys are sorted by default so that
  /// identical values always produce identical bytes, which provider prompt
  /// caches depend on.
  public func jsonData(sortedKeys: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Serializes the value to a JSON string, like `JSON.stringify`.
  public func jsonString(sortedKeys: Bool = true) -> String {
    guard let data = try? jsonData(sortedKeys: sortedKeys) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Decodes the value into a `Decodable` type.
  public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: jsonData())
  }
}

extension JSONValue: CustomStringConvertible {
  public var description: String { jsonString() }
}
