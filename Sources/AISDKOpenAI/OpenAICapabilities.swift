import AISDKProviderUtils
import Foundation

/// What an OpenAI model family supports. Mirrors upstream `OpenAILanguageModelCapabilities`.
public struct OpenAILanguageModelCapabilities: Sendable, Equatable {
  public enum SystemMessageMode: String, Sendable, Codable {
    case remove, system, developer
  }

  public var isReasoningModel: Bool
  public var systemMessageMode: SystemMessageMode
  public var supportsFlexProcessing: Bool
  public var supportsPriorityProcessing: Bool
  public var supportsConfigurationUpdate: Bool
  public var supportsAsyncToolCalling: Bool
  public var supportedReasoningEfforts: [String]?
  /// Allows temperature, topP and logprobs when reasoning effort is `none`.
  public var supportsNonReasoningParameters: Bool
}

private func oSeriesVersion(_ modelId: String) -> Int? {
  guard modelId.first == "o" else { return nil }
  let digits = modelId.dropFirst().prefix { $0.isASCII && $0.isNumber }
  guard !digits.isEmpty else { return nil }
  let rest = modelId.dropFirst(1 + digits.count)
  guard rest.isEmpty || rest.first == "-" else { return nil }
  return Int(digits)
}

private struct GptVersion {
  var major: Int
  var minor: Int?
  var variant: String?
}

private func gptVersion(_ modelId: String) -> GptVersion? {
  guard modelId.hasPrefix("gpt-") else { return nil }
  var rest = modelId.dropFirst(4)
  let majorDigits = rest.prefix { $0.isASCII && $0.isNumber }
  guard let major = Int(majorDigits) else { return nil }
  rest = rest.dropFirst(majorDigits.count)
  var minor: Int?
  if rest.first == "." {
    let minorDigits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
    guard let value = Int(minorDigits) else { return nil }
    minor = value
    rest = rest.dropFirst(1 + minorDigits.count)
  }
  var variant: String?
  if rest.first == "-" {
    let value = rest.dropFirst()
    guard !value.isEmpty else { return nil }
    variant = String(value)
  } else if !rest.isEmpty {
    return nil
  }
  return GptVersion(major: major, minor: minor, variant: variant)
}

/// Mirrors upstream `getOpenAILanguageModelCapabilities`.
public func getOpenAILanguageModelCapabilities(_ modelId: String) -> OpenAILanguageModelCapabilities {
  let oSeries = oSeriesVersion(modelId)
  let gpt = gptVersion(modelId)
  let isGptChatModel = gpt?.minor == nil && (gpt?.variant?.hasPrefix("chat") ?? false)
  let isGptNanoModel = gpt?.variant?.hasPrefix("nano") ?? false
  let isGpt6OrLater = gpt.map { $0.major >= 6 } ?? false
  let isGpt6SolOrLuna = modelId == "gpt-6-sol" || modelId == "gpt-6-luna"

  let supportsFlexProcessing =
    (oSeries.map { $0 >= 3 } ?? false) || (gpt.map { $0.major >= 5 } ?? false && !isGptChatModel)
  let supportsPriorityProcessing =
    modelId.hasPrefix("gpt-4")
    || (gpt.map { $0.major >= 5 } ?? false && !isGptNanoModel && !isGptChatModel)
    || (oSeries.map { $0 >= 3 } ?? false)
  let isReasoningModel = oSeries != nil || (gpt.map { $0.major >= 5 } ?? false && !isGptChatModel)
  let supportsNonReasoningParameters =
    !isGpt6OrLater
    && (gpt.map { $0.major > 5 || ($0.major == 5 && ($0.minor ?? 0) >= 1) } ?? false)

  return OpenAILanguageModelCapabilities(
    isReasoningModel: isReasoningModel,
    systemMessageMode: isReasoningModel ? .developer : .system,
    supportsFlexProcessing: supportsFlexProcessing,
    supportsPriorityProcessing: supportsPriorityProcessing,
    supportsConfigurationUpdate: isGpt6OrLater,
    supportsAsyncToolCalling: isGpt6OrLater,
    supportedReasoningEfforts: isGpt6SolOrLuna
      ? ["none", "low", "medium", "high", "xhigh", "max"]
      : isGpt6OrLater ? ["low", "medium", "high", "xhigh", "max"] : nil,
    supportsNonReasoningParameters: supportsNonReasoningParameters)
}
