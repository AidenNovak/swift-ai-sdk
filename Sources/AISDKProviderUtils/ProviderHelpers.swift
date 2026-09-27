import Foundation

/// A structured error reported inside a provider stream. Mirrors upstream
/// `ProviderStreamError` / `createProviderStreamError`.
public struct ProviderStreamError: AISDKError {
  public let name = "AI_ProviderStreamError"
  public let message: String
  public let type: String?
  /// The provider error code (a string or a number).
  public let code: JSONValue?
  public let statusCode: Int?
  public let isRetryable: Bool?
  /// The raw error payload.
  public let data: JSONValue?

  public init(
    message: String, type: String? = nil, code: JSONValue? = nil, statusCode: Int? = nil,
    isRetryable: Bool? = nil, data: JSONValue? = nil
  ) {
    self.message = message
    self.type = type
    self.code = code
    self.statusCode = statusCode
    self.isRetryable = isRetryable
    self.data = data
  }
}

/// Whether a reasoning setting overrides the provider default. Mirrors upstream `isCustomReasoning`.
public func isCustomReasoning(_ reasoning: LanguageModelV4ReasoningEffort?) -> Bool {
  guard let reasoning else { return false }
  return reasoning != .providerDefault
}

/// Maps a reasoning level to a provider effort value, warning on approximations.
/// Mirrors upstream `mapReasoningToProviderEffort`.
public func mapReasoningToProviderEffort<Effort: Equatable & CustomStringConvertible>(
  reasoning: LanguageModelV4ReasoningEffort,
  effortMap: [LanguageModelV4ReasoningEffort: Effort],
  warnings: inout [SharedV4Warning]
) -> Effort? {
  guard let mapped = effortMap[reasoning] else {
    warnings.append(
      .unsupported(feature: "reasoning", details: "reasoning \"\(reasoning.rawValue)\" is not supported by this model."))
    return nil
  }
  if mapped.description != reasoning.rawValue {
    warnings.append(
      .compatibility(
        feature: "reasoning",
        details:
          "reasoning \"\(reasoning.rawValue)\" is not directly supported by this model. mapped to effort \"\(mapped)\"."))
  }
  return mapped
}

/// Maps a reasoning level to a token budget. Mirrors upstream `mapReasoningToProviderBudget`.
public func mapReasoningToProviderBudget(
  reasoning: LanguageModelV4ReasoningEffort,
  maxOutputTokens: Int,
  maxReasoningBudget: Int,
  minReasoningBudget: Int = 1024,
  budgetPercentages: [LanguageModelV4ReasoningEffort: Double] = [
    .minimal: 0.02, .low: 0.1, .medium: 0.3, .high: 0.6, .xhigh: 0.9,
  ],
  warnings: inout [SharedV4Warning]
) -> Int? {
  guard let percentage = budgetPercentages[reasoning] else {
    warnings.append(
      .unsupported(feature: "reasoning", details: "reasoning \"\(reasoning.rawValue)\" is not supported by this model."))
    return nil
  }
  let budget = Int((Double(maxOutputTokens) * percentage).rounded())
  return min(maxReasoningBudget, max(minReasoningBudget, budget))
}

/// Builds response metadata from OpenAI-style `id`, `model` and `created`
/// fields. Mirrors upstream `createLanguageModelResponseMetadata`.
public func createLanguageModelResponseMetadata(id: String?, model: String?, created: Double?)
  -> LanguageModelV4ResponseMetadata
{
  LanguageModelV4ResponseMetadata(
    id: id, timestamp: created.map { Date(timeIntervalSince1970: $0) }, modelId: model)
}

extension LanguageModelV4ResponseMetadata {
  /// True when no field carries a value; empty strings count as missing.
  public var isEmpty: Bool {
    (id ?? "").isEmpty && (modelId ?? "").isEmpty && timestamp == nil
  }
}

/// Resolves a file part's full media type, detecting it from inline bytes if
/// needed. Mirrors upstream `resolveFullMediaType`.
public func resolveFullMediaType(_ part: LanguageModelV4FilePart) throws -> String {
  if isFullMediaType(part.mediaType) { return part.mediaType }
  let topLevel = getTopLevelMediaType(part.mediaType)
  switch part.data {
  case .data(let data):
    if let detected = detectMediaType(data: data, topLevelType: topLevel) { return detected }
  case .base64(let base64):
    if let detected = detectMediaType(base64: base64, topLevelType: topLevel) { return detected }
  case .url, .reference, .text:
    throw UnsupportedFunctionalityError(
      functionality:
        "file of media type \"\(part.mediaType)\" must specify subtype since it is not passed as inline bytes")
  }
  throw UnsupportedFunctionalityError(
    functionality:
      "file of media type \"\(part.mediaType)\" must specify subtype since it could not be auto-detected")
}

/// Returns the provider's ID from a provider reference. Mirrors upstream `resolveProviderReference`.
public func resolveProviderReference(_ reference: SharedV4ProviderReference, provider: String) throws -> String {
  guard let id = reference[provider] else {
    throw NoSuchProviderReferenceError(provider: provider, reference: reference)
  }
  return id
}

/// Builds a JSON object, dropping `nil` values. Useful for request bodies,
/// where upstream relies on `JSON.stringify` omitting `undefined`.
public func jsonObject(_ entries: KeyValuePairs<String, JSONValue?>) -> JSONValue {
  var object: JSONObject = [:]
  for (key, value) in entries {
    if let value { object[key] = value }
  }
  return .object(object)
}

extension JSONValue {
  /// Wraps an optional string.
  public static func optional(_ value: String?) -> JSONValue? { value.map(JSONValue.string) }
  /// Wraps an optional number.
  public static func optional(_ value: Double?) -> JSONValue? { value.map(JSONValue.number) }
  /// Wraps an optional integer.
  public static func optional(_ value: Int?) -> JSONValue? { value.map { .number(Double($0)) } }
  /// Wraps an optional boolean.
  public static func optional(_ value: Bool?) -> JSONValue? { value.map(JSONValue.bool) }
  /// Wraps an optional string array.
  public static func optional(_ value: [String]?) -> JSONValue? { value.map { .array($0.map(JSONValue.string)) } }
}
