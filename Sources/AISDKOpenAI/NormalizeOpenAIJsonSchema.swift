import AISDKProviderUtils
import Foundation

/// Removes JSON Schema features OpenAI structured outputs reject:
/// `propertyNames` (string schemas only) and `pattern`s with regex lookaround.
/// Both are left to client-side validation. Mirrors upstream `normalizeOpenAIJsonSchema`.
///
/// - Throws: `UnsupportedFunctionalityError` for non-string `propertyNames`.
public func normalizeOpenAIJsonSchema(_ schema: JSONSchema) throws -> (schema: JSONSchema, warnings: [SharedV4Warning]) {
  var removedPropertyNames = false
  var removedLookaroundPattern = false

  func normalizeDefinition(_ definition: JSONValue) throws -> JSONValue {
    guard case .object = definition else { return definition }
    return try normalize(definition)
  }

  func normalizeRecord(_ value: JSONValue?) throws -> JSONValue? {
    guard case .object(let record)? = value else { return value }
    return .object(try record.mapValues(normalizeDefinition))
  }

  func normalize(_ schema: JSONValue) throws -> JSONValue {
    guard case .object(var object) = schema else { return schema }

    if let propertyNames = object["propertyNames"] {
      guard propertyNames["type"]?.stringValue == "string" else {
        throw UnsupportedFunctionalityError(functionality: "JSON Schema propertyNames that does not use a string schema")
      }
      removedPropertyNames = true
      object["propertyNames"] = nil
    }

    if let pattern = object["pattern"]?.stringValue, containsRegexLookaround(pattern) {
      object["pattern"] = nil
      removedLookaroundPattern = true
    }

    for key in ["properties", "patternProperties", "definitions", "$defs"] where object[key] != nil {
      object[key] = try normalizeRecord(object[key])
    }
    for key in ["additionalProperties", "additionalItems", "contains", "not", "if", "then", "else"] {
      if let value = object[key] { object[key] = try normalizeDefinition(value) }
    }
    switch object["items"] {
    case .array(let items)?: object["items"] = .array(try items.map(normalizeDefinition))
    case let items?: object["items"] = try normalizeDefinition(items)
    case nil: break
    }
    for key in ["allOf", "anyOf", "oneOf"] {
      if case .array(let values)? = object[key] { object[key] = .array(try values.map(normalizeDefinition)) }
    }
    if case .object(let dependencies)? = object["dependencies"] {
      object["dependencies"] = .object(
        try dependencies.mapValues { dependency in
          if case .array = dependency { return dependency }
          return try normalizeDefinition(dependency)
        })
    }
    return .object(object)
  }

  let normalized = try normalize(schema.value)
  var warnings: [SharedV4Warning] = []
  if removedPropertyNames {
    warnings.append(
      .compatibility(
        feature: "JSON Schema propertyNames",
        details:
          "OpenAI does not support JSON Schema propertyNames. It was removed before sending the schema, so OpenAI will not enforce property-name constraints."
      ))
  }
  if removedLookaroundPattern {
    warnings.append(
      .compatibility(
        feature: "JSON Schema pattern with regex lookaround",
        details:
          "OpenAI does not support regex lookaround in JSON Schema patterns. The pattern was removed before sending the schema, so OpenAI will not enforce that constraint."
      ))
  }
  return (JSONSchema(normalized), warnings)
}

func containsRegexLookaround(_ pattern: String) -> Bool {
  let characters = Array(pattern)
  var escaped = false
  var inCharacterClass = false
  for index in characters.indices {
    let character = characters[index]
    if escaped {
      escaped = false
      continue
    }
    switch character {
    case "\\":
      escaped = true
    case "[":
      inCharacterClass = true
    case "]":
      inCharacterClass = false
    case "(" where !inCharacterClass && index + 2 < characters.count && characters[index + 1] == "?":
      let prefix = characters[index + 2]
      if prefix == "=" || prefix == "!" { return true }
      if prefix == "<", index + 3 < characters.count, characters[index + 3] == "=" || characters[index + 3] == "!" {
        return true
      }
    default:
      break
    }
  }
  return false
}
