import Foundation

/// Reads fields from a JSON object while decoding UI messages and chunks,
/// throwing `MessageDecodingError` with the offending path.
struct UIJSONReader {
  let object: JSONObject
  let path: String

  init(_ value: JSONValue, path: String) throws {
    guard let object = value.objectValue else {
      throw MessageDecodingError(message: "Expected an object at \(path), got \(value.jsonString()).")
    }
    self.object = object
    self.path = path
  }

  func string(_ key: String) throws -> String {
    guard let value = object[key]?.stringValue else {
      throw MessageDecodingError(message: "Expected a string at \(path).\(key).")
    }
    return value
  }

  func optionalString(_ key: String) throws -> String? {
    guard let value = object[key] else { return nil }
    guard let string = value.stringValue else {
      throw MessageDecodingError(message: "Expected a string at \(path).\(key).")
    }
    return string
  }

  func bool(_ key: String) throws -> Bool {
    guard let value = object[key]?.boolValue else {
      throw MessageDecodingError(message: "Expected a boolean at \(path).\(key).")
    }
    return value
  }

  func optionalBool(_ key: String) throws -> Bool? {
    guard let value = object[key] else { return nil }
    guard let bool = value.boolValue else {
      throw MessageDecodingError(message: "Expected a boolean at \(path).\(key).")
    }
    return bool
  }

  func optionalObject(_ key: String) throws -> JSONObject? {
    guard let value = object[key] else { return nil }
    guard let object = value.objectValue else {
      throw MessageDecodingError(message: "Expected an object at \(path).\(key).")
    }
    return object
  }

  func providerMetadata(_ key: String) throws -> ProviderMetadata? {
    guard let object = try optionalObject(key) else { return nil }
    var metadata: ProviderMetadata = [:]
    for (provider, value) in object {
      guard let entry = value.objectValue else {
        throw MessageDecodingError(message: "Expected an object at \(path).\(key).\(provider).")
      }
      metadata[provider] = entry
    }
    return metadata
  }

  func stringMap(_ key: String) throws -> [String: String]? {
    guard let object = try optionalObject(key) else { return nil }
    var map: [String: String] = [:]
    for (name, value) in object {
      guard let string = value.stringValue else {
        throw MessageDecodingError(message: "Expected a string at \(path).\(key).\(name).")
      }
      map[name] = string
    }
    return map
  }
}

/// Builds a JSON object, dropping `nil` entries (like `JSON.stringify` drops `undefined`).
func uiJSON(_ entries: [(String, JSONValue?)]) -> JSONValue {
  var object: JSONObject = [:]
  for (key, value) in entries {
    if let value { object[key] = value }
  }
  return .object(object)
}

func uiJSON(_ metadata: ProviderMetadata?) -> JSONValue? {
  metadata.map { .object($0.mapValues(JSONValue.object)) }
}

func uiJSON(_ map: [String: String]?) -> JSONValue? {
  map.map { .object($0.mapValues(JSONValue.string)) }
}

func uiJSON(_ string: String?) -> JSONValue? { string.map(JSONValue.string) }

func uiJSON(_ bool: Bool?) -> JSONValue? { bool.map(JSONValue.bool) }

func uiJSON(_ object: JSONObject?) -> JSONValue? { object.map(JSONValue.object) }

/// Deep-merges JSON objects; arrays and scalars in `overrides` replace `base`.
/// Mirrors upstream `mergeObjects`.
func mergeJSONObjects(_ base: JSONValue?, _ overrides: JSONValue?) -> JSONValue? {
  guard let base else { return overrides }
  guard let overrides else { return base }
  guard case .object(var result) = base, case .object(let overrideObject) = overrides else {
    return overrides
  }
  for (key, value) in overrideObject {
    if case .object = value, let existing = result[key], case .object = existing {
      result[key] = mergeJSONObjects(existing, value)
    } else {
      result[key] = value
    }
  }
  return .object(result)
}
