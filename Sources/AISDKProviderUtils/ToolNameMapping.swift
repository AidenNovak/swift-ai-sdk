import Foundation

/// Maps between the tool names a caller chose and the names a provider uses
/// for its built-in tools. Mirrors upstream `ToolNameMapping`.
public struct ToolNameMapping: Sendable {
  private let customToProvider: [String: String]
  private let providerToCustom: [String: String]

  /// - Parameter providerToolNames: Provider tool ID (e.g. `openai.web_search`) to provider tool name.
  public init(tools: [LanguageModelV4Tool]?, providerToolNames: [String: String]) {
    var customToProvider: [String: String] = [:]
    var providerToCustom: [String: String] = [:]
    for case .provider(let tool) in tools ?? [] {
      guard let providerName = providerToolNames[tool.id] else { continue }
      customToProvider[tool.name] = providerName
      providerToCustom[providerName] = tool.name
    }
    self.customToProvider = customToProvider
    self.providerToCustom = providerToCustom
  }

  /// The provider name for a caller tool name, or the name itself when unmapped.
  public func toProviderToolName(_ customToolName: String) -> String {
    customToProvider[customToolName] ?? customToolName
  }

  /// The caller tool name for a provider tool name, or the name itself when unmapped.
  public func toCustomToolName(_ providerToolName: String) -> String {
    providerToCustom[providerToolName] ?? providerToolName
  }
}
