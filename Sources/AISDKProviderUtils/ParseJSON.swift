import Foundation

/// The result of parsing and validating JSON. Mirrors upstream `ParseResult`.
public enum ParseResult<T: Sendable>: Sendable {
  case success(value: T, rawValue: JSONValue)
  case failure(error: any Error, rawValue: JSONValue?)

  public var value: T? {
    if case .success(let value, _) = self { return value }
    return nil
  }

  public var error: (any Error)? {
    if case .failure(let error, _) = self { return error }
    return nil
  }

  public var rawValue: JSONValue? {
    switch self {
    case .success(_, let rawValue): rawValue
    case .failure(_, let rawValue): rawValue
    }
  }

  public var isSuccess: Bool { value != nil }
}

/// Parses JSON text. Mirrors upstream `parseJSON` without a schema.
///
/// - Throws: `JSONParseError`.
public func parseJSON(_ text: String) throws -> JSONValue {
  do {
    return try JSONValue(jsonString: text)
  } catch {
    throw JSONParseError(text: text, cause: error)
  }
}

/// Parses JSON text and decodes it. Mirrors upstream `parseJSON` with a schema.
///
/// - Throws: `JSONParseError` when the text is not JSON, `TypeValidationError`
///   when it does not decode as `T`.
public func parseJSON<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
  let value = try parseJSON(text)
  do {
    return try JSONDecoder().decode(T.self, from: Data(text.utf8))
  } catch {
    throw TypeValidationError.wrap(value: value, cause: error)
  }
}

/// Parses JSON text and validates it against a schema.
public func parseJSON<T>(_ text: String, schema: Schema<T>) throws -> T {
  try validateTypes(value: parseJSON(text), schema: schema)
}

/// Parses JSON text without throwing. Mirrors upstream `safeParseJSON`.
public func safeParseJSON(_ text: String) -> ParseResult<JSONValue> {
  do {
    let value = try parseJSON(text)
    return .success(value: value, rawValue: value)
  } catch {
    return .failure(error: error, rawValue: nil)
  }
}

/// Parses and decodes JSON text without throwing. Mirrors upstream `safeParseJSON`.
public func safeParseJSON<T: Decodable & Sendable>(_ text: String, as type: T.Type)
  -> ParseResult<T>
{
  let value: JSONValue
  do {
    value = try parseJSON(text)
  } catch {
    return .failure(error: error, rawValue: nil)
  }
  do {
    return .success(value: try JSONDecoder().decode(T.self, from: Data(text.utf8)), rawValue: value)
  } catch {
    return .failure(error: TypeValidationError.wrap(value: value, cause: error), rawValue: value)
  }
}

/// Parses and validates JSON text against a schema without throwing.
public func safeParseJSON<T>(_ text: String, schema: Schema<T>) -> ParseResult<T> {
  let value: JSONValue
  do {
    value = try parseJSON(text)
  } catch {
    return .failure(error: error, rawValue: nil)
  }
  return safeValidateTypes(value: value, schema: schema)
}

/// Whether the text is valid JSON. Mirrors upstream `isParsableJson`.
public func isParsableJson(_ text: String) -> Bool {
  (try? JSONValue(jsonString: text)) != nil
}
