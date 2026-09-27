import Foundation

/// A JSON Schema paired with a validator that turns JSON into a typed value.
/// Mirrors upstream `Schema` / `FlexibleSchema`.
///
/// Upstream accepts zod and Standard Schema objects; in Swift a schema is
/// built from a JSON Schema plus a `Decodable` type or a custom validator.
public struct Schema<Output: Sendable>: Sendable {
  /// The JSON Schema sent to the model.
  public let jsonSchema: JSONSchema
  private let validator: @Sendable (JSONValue) throws -> Output

  /// Creates a schema with a custom validator. The validator throws when the
  /// value does not match.
  public init(jsonSchema: JSONSchema, validate: @escaping @Sendable (JSONValue) throws -> Output) {
    self.jsonSchema = jsonSchema
    self.validator = validate
  }

  /// Validates a value and converts it to `Output`.
  public func validate(_ value: JSONValue) throws -> Output {
    try validator(value)
  }
}

extension Schema where Output: Decodable {
  /// A schema that validates by decoding `Output` with `JSONDecoder`.
  public init(_ type: Output.Type = Output.self, jsonSchema: JSONSchema) {
    self.init(jsonSchema: jsonSchema) { value in
      try JSONDecoder().decode(Output.self, from: value.jsonData())
    }
  }
}

/// A schema that accepts any JSON value. Mirrors upstream `jsonSchema()` without a validator.
public func jsonSchema(_ schema: JSONSchema) -> Schema<JSONValue> {
  Schema(jsonSchema: schema) { $0 }
}

/// A schema with a custom validator. Mirrors upstream `jsonSchema(schema, { validate })`.
public func jsonSchema<Output: Sendable>(
  _ schema: JSONSchema, validate: @escaping @Sendable (JSONValue) throws -> Output
) -> Schema<Output> {
  Schema(jsonSchema: schema, validate: validate)
}

/// The result of validating a value. Mirrors upstream `ValidationResult`.
public typealias ValidationResult<T: Sendable> = ParseResult<T>

/// Validates a value against a schema. Mirrors upstream `validateTypes`.
///
/// - Throws: `TypeValidationError`.
public func validateTypes<T>(
  value: JSONValue, schema: Schema<T>, context: TypeValidationContext? = nil
) throws -> T {
  do {
    return try schema.validate(value)
  } catch {
    throw TypeValidationError.wrap(value: value, cause: error, context: context)
  }
}

/// Validates a value against a schema without throwing. Mirrors upstream `safeValidateTypes`.
public func safeValidateTypes<T>(
  value: JSONValue, schema: Schema<T>, context: TypeValidationContext? = nil
) -> ValidationResult<T> {
  do {
    return .success(value: try schema.validate(value), rawValue: value)
  } catch {
    return .failure(
      error: TypeValidationError.wrap(value: value, cause: error, context: context),
      rawValue: value)
  }
}

extension Schema {
  /// A schema that validates with this schema but keeps the value as JSON,
  /// e.g. to validate UI message metadata with a typed schema.
  public var validatingJSON: Schema<JSONValue> {
    Schema<JSONValue>(jsonSchema: jsonSchema) { value in
      _ = try validate(value)
      return value
    }
  }
}
