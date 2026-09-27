import Foundation

/// Loads an API key from the parameter or an environment variable.
/// Mirrors upstream `loadApiKey`.
///
/// - Throws: `LoadAPIKeyError` when the key is missing.
public func loadApiKey(
  apiKey: String?,
  environmentVariableName: String,
  apiKeyParameterName: String = "apiKey",
  description: String,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> String {
  if let apiKey { return apiKey }
  guard let value = environment[environmentVariableName] else {
    throw LoadAPIKeyError(
      message:
        "\(description) API key is missing. Pass it using the '\(apiKeyParameterName)' parameter or the \(environmentVariableName) environment variable."
    )
  }
  return value
}

/// Loads a required setting from the parameter or an environment variable.
/// Mirrors upstream `loadSetting`.
///
/// - Throws: `LoadSettingError` when the setting is missing.
public func loadSetting(
  settingValue: String?,
  environmentVariableName: String,
  settingName: String,
  description: String,
  environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> String {
  if let settingValue { return settingValue }
  guard let value = environment[environmentVariableName] else {
    throw LoadSettingError(
      message:
        "\(description) setting is missing. Pass it using the '\(settingName)' parameter or the \(environmentVariableName) environment variable."
    )
  }
  return value
}

/// Loads an optional setting from the parameter or an environment variable.
/// Mirrors upstream `loadOptionalSetting`.
public func loadOptionalSetting(
  settingValue: String?,
  environmentVariableName: String,
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
  settingValue ?? environment[environmentVariableName]
}

/// Removes one trailing slash. Mirrors upstream `withoutTrailingSlash`.
public func withoutTrailingSlash(_ url: String?) -> String? {
  guard let url else { return nil }
  return url.hasSuffix("/") ? String(url.dropLast()) : url
}

/// Merges header dictionaries; later values win. Mirrors upstream `combineHeaders`.
public func combineHeaders(_ headers: [String: String]?...) -> [String: String] {
  var combined: [String: String] = [:]
  for dictionary in headers {
    for (name, value) in dictionary ?? [:] {
      if let existing = combined.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
        combined.removeValue(forKey: existing)
      }
      combined[name] = value
    }
  }
  return combined
}

/// Lower-cases header names and appends parts to the `user-agent` header.
/// Mirrors upstream `withUserAgentSuffix`.
public func withUserAgentSuffix(_ headers: [String: String]?, _ suffixParts: String...)
  -> [String: String]
{
  var normalized: [String: String] = [:]
  for (name, value) in headers ?? [:] {
    normalized[name.lowercased()] = value
  }
  let current = normalized["user-agent"] ?? ""
  normalized["user-agent"] = ([current] + suffixParts).filter { !$0.isEmpty }.joined(separator: " ")
  return normalized
}

/// Parses the options for one provider out of `providerOptions`.
/// Mirrors upstream `parseProviderOptions`.
///
/// - Returns: `nil` when there are no options for the provider.
/// - Throws: `InvalidArgumentError` when the options do not decode.
public func parseProviderOptions<Options: Decodable>(
  provider: String, providerOptions: SharedV4ProviderOptions?, as type: Options.Type
) throws -> Options? {
  guard let options = providerOptions?[provider] else { return nil }
  do {
    return try JSONValue.object(options).decode(as: Options.self)
  } catch {
    throw InvalidArgumentError(
      argument: "providerOptions",
      message: "invalid \(provider) provider options",
      cause: TypeValidationError.wrap(value: .object(options), cause: error))
  }
}
