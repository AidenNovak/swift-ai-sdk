import AISDKProviderUtils
import Foundation

/// The resolved thinking configuration of a DeepSeek request.
struct DeepSeekThinking {
  /// `enabled` / `disabled`, or `nil` to use the model default.
  var type: String?
  /// `low` / `high` / `max`, or `nil` to use the model default.
  var effort: String?
  /// Whether the request runs in thinking mode (explicitly or by default).
  var isEnabled: Bool
}

/// Resolves thinking mode and effort from provider options and top-level
/// `reasoning`. Provider options win.
///
/// DeepSeek's canonical efforts are `low`, `high` and `max`; `none` turns
/// thinking off. Other values are mapped with a compatibility warning.
func resolveDeepSeekThinking(
  modelId: String,
  supportsThinking: Bool,
  thinkingType requestedType: String?,
  reasoningEffort requestedEffort: String?,
  reasoning: LanguageModelV4ReasoningEffort?,
  warnings: inout [SharedV4Warning]
) -> DeepSeekThinking {
  guard supportsThinking else { return DeepSeekThinking(type: nil, effort: nil, isEnabled: false) }

  if requestedType == "adaptive" {
    warnings.append(
      .compatibility(
        feature: "thinking.type",
        details: "thinking.type \"adaptive\" is not a canonical DeepSeek value. mapped to \"enabled\"."))
  }

  var effort: String?
  var effortDisablesThinking = false
  if let requestedEffort {
    let mapped: String =
      switch requestedEffort {
      case "minimal": "low"
      case "medium": "high"
      case "xhigh", "ultra": "max"
      default: requestedEffort
      }
    if mapped != requestedEffort {
      warnings.append(
        .compatibility(
          feature: "reasoningEffort",
          details: "reasoningEffort \"\(requestedEffort)\" is not a canonical DeepSeek value. mapped to \"\(mapped)\"."))
    }
    if mapped == "none" {
      effortDisablesThinking = true
    } else {
      effort = mapped
    }
  } else if let reasoning, isCustomReasoning(reasoning), reasoning != .none {
    effort = mapReasoningToProviderEffort(
      reasoning: reasoning,
      effortMap: [.minimal: "low", .low: "low", .medium: "high", .high: "high", .xhigh: "max"],
      warnings: &warnings)
  }

  let type: String? =
    if let requestedType {
      requestedType == "adaptive" ? "enabled" : requestedType
    } else if effortDisablesThinking {
      "disabled"
    } else if requestedEffort == nil, isCustomReasoning(reasoning) {
      reasoning == LanguageModelV4ReasoningEffort.none ? "disabled" : "enabled"
    } else {
      nil
    }

  let isEnabled =
    type != "disabled" && (type != nil || modelId == "deepseek-reasoner" || isDeepSeekV4Model(modelId))
  return DeepSeekThinking(type: type, effort: type == "disabled" ? nil : effort, isEnabled: isEnabled)
}

/// Applies DeepSeek's sampling rules: `temperature` only works without
/// thinking; `top_p` only works with thinking, clamped to at least 0.95.
func deepSeekSampling(
  temperature: Double?, topP: Double?, isThinkingEnabled: Bool, warnings: inout [SharedV4Warning]
) -> (temperature: Double?, topP: Double?) {
  if isThinkingEnabled {
    if temperature != nil {
      warnings.append(
        .unsupported(
          feature: "temperature",
          details:
            "temperature has no effect when DeepSeek thinking is enabled. Set providerOptions.deepseek.thinking.type to 'disabled' to use temperature."
        ))
    }
    if let topP, topP < 0.95 {
      warnings.append(
        .compatibility(
          feature: "topP",
          details: "topP \(topP) is below DeepSeek's thinking-mode minimum of 0.95 and is treated as 0.95."))
    }
    return (nil, topP)
  }
  if topP != nil {
    warnings.append(
      .unsupported(
        feature: "topP",
        details: "topP has no effect when DeepSeek thinking is disabled; it is fixed at 1.0. Enable thinking to use topP."
      ))
  }
  return (temperature, nil)
}
