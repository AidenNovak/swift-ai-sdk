import AISDKProviderUtils
import Foundation

private let supportedStringFormats: Set<String> = [
  "date-time", "time", "date", "duration", "email", "hostname", "uri", "ipv4", "ipv6", "uuid",
]

private let descriptionConstraintKeys = [
  "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "pattern",
  "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties", "not",
]

/// Reduces a JSON Schema to what Anthropic structured outputs accept: objects
/// become closed, `oneOf` becomes `anyOf`, and unsupported constraints move
/// into the description. Mirrors upstream `sanitizeJsonSchema`.
func sanitizeJsonSchema(_ schema: JSONValue) -> JSONValue {
  guard case .object(let object) = schema else { return schema }
  if let ref = object["$ref"] { return ["$ref": ref] }

  var result: JSONObject = [:]
  for key in ["$schema", "$id", "title", "description", "default", "const", "enum", "type"] {
    if let value = object[key], !(key != "default" && key != "const" && value.isNull) { result[key] = value }
  }
  if let anyOf = object["anyOf"]?.arrayValue {
    result["anyOf"] = .array(anyOf.map(sanitizeJsonSchema))
  } else if let oneOf = object["oneOf"]?.arrayValue {
    result["anyOf"] = .array(oneOf.map(sanitizeJsonSchema))
  }
  if let allOf = object["allOf"]?.arrayValue {
    result["allOf"] = .array(allOf.map(sanitizeJsonSchema))
  }
  for key in ["definitions", "$defs"] {
    if let definitions = object[key]?.objectValue {
      result[key] = .object(definitions.mapValues(sanitizeJsonSchema))
    }
  }
  if object["type"] == "object" || object["properties"] != nil {
    if let properties = object["properties"]?.objectValue {
      result["properties"] = .object(properties.mapValues(sanitizeJsonSchema))
    }
    result["additionalProperties"] = false
    if let required = object["required"] { result["required"] = required }
  }
  if let items = object["items"] {
    result["items"] = items.arrayValue.map { .array($0.map(sanitizeJsonSchema)) } ?? sanitizeJsonSchema(items)
  }

  let format = object["format"]?.stringValue
  if let format, supportedStringFormats.contains(format) {
    result["format"] = .string(format)
  }

  var constraints: [String] = descriptionConstraintKeys.compactMap { key in
    guard let value = object[key], !value.isNull, value != false else { return nil }
    let name = key.replacingOccurrences(of: "[A-Z]", with: " $0", options: .regularExpression).lowercased()
    return "\(name): \(value.stringValue ?? value.jsonString(sortedKeys: false))"
  }
  if let format, !supportedStringFormats.contains(format) {
    constraints.append("format: \(format)")
  }
  if !constraints.isEmpty {
    let description = constraints.joined(separator: "; ") + "."
    result["description"] = .string(result["description"]?.stringValue.map { "\($0)\n\(description)" } ?? description)
  }
  return .object(result)
}
