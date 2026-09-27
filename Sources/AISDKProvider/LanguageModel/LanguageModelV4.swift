/// Specification for a language model that implements the language model
/// interface version 4. Mirrors upstream `LanguageModelV4`.
public protocol LanguageModelV4: Sendable {
  /// The language model interface version. Always `"v4"`.
  var specificationVersion: String { get }

  /// Provider ID.
  var provider: String { get }

  /// Provider-specific model ID.
  var modelId: String { get }

  /// URL patterns the model supports natively, keyed by media type pattern
  /// (e.g. `*/*`, `image/*`, `application/pdf`). Values are regular
  /// expression sources matched against lower-case URLs. Matching URLs are
  /// passed to the model instead of being downloaded.
  var supportedUrls: [String: [String]] { get async throws }

  /// Generates a language model output (non-streaming).
  ///
  /// The `do` prefix discourages calling the method directly; use the core
  /// functions such as `generateText` instead.
  func doGenerate(_ options: LanguageModelV4CallOptions) async throws
    -> LanguageModelV4GenerateResult

  /// Generates a language model output (streaming).
  ///
  /// Cancelling the consuming task cancels the underlying request.
  func doStream(_ options: LanguageModelV4CallOptions) async throws -> LanguageModelV4StreamResult
}

extension LanguageModelV4 {
  public var specificationVersion: String { "v4" }
  public var supportedUrls: [String: [String]] { get async throws { [:] } }
}

/// A stream of language model output parts.
public typealias LanguageModelV4Stream = AsyncThrowingStream<LanguageModelV4StreamPart, any Error>

/// Request information for telemetry and debugging.
public struct LanguageModelV4RequestInfo: Sendable, Equatable {
  /// The request HTTP body that was sent to the provider API.
  public var body: JSONValue?

  public init(body: JSONValue? = nil) {
    self.body = body
  }
}

/// Response information for a non-streaming call.
public struct LanguageModelV4ResponseInfo: Sendable, Equatable {
  public var metadata: LanguageModelV4ResponseMetadata
  /// Response headers.
  public var headers: SharedV4Headers?
  /// Response HTTP body.
  public var body: JSONValue?

  public init(
    metadata: LanguageModelV4ResponseMetadata = LanguageModelV4ResponseMetadata(),
    headers: SharedV4Headers? = nil,
    body: JSONValue? = nil
  ) {
    self.metadata = metadata
    self.headers = headers
    self.body = body
  }

  public var id: String? { metadata.id }
  public var modelId: String? { metadata.modelId }
}

/// Result of a non-streaming call. Mirrors upstream `LanguageModelV4GenerateResult`.
public struct LanguageModelV4GenerateResult: Sendable, Equatable {
  /// The ordered content the model generated.
  public var content: [LanguageModelV4Content]
  public var finishReason: LanguageModelV4FinishReason
  public var usage: LanguageModelV4Usage
  /// Provider-specific metadata, passed through to the caller.
  public var providerMetadata: SharedV4ProviderMetadata?
  public var request: LanguageModelV4RequestInfo?
  public var response: LanguageModelV4ResponseInfo?
  /// Warnings for the call, e.g. unsupported settings.
  public var warnings: [SharedV4Warning]

  public init(
    content: [LanguageModelV4Content],
    finishReason: LanguageModelV4FinishReason,
    usage: LanguageModelV4Usage,
    providerMetadata: SharedV4ProviderMetadata? = nil,
    request: LanguageModelV4RequestInfo? = nil,
    response: LanguageModelV4ResponseInfo? = nil,
    warnings: [SharedV4Warning] = []
  ) {
    self.content = content
    self.finishReason = finishReason
    self.usage = usage
    self.providerMetadata = providerMetadata
    self.request = request
    self.response = response
    self.warnings = warnings
  }
}

/// Result of a streaming call. Mirrors upstream `LanguageModelV4StreamResult`.
public struct LanguageModelV4StreamResult: Sendable {
  public var stream: LanguageModelV4Stream
  public var request: LanguageModelV4RequestInfo?
  /// Response headers.
  public var responseHeaders: SharedV4Headers?

  public init(
    stream: LanguageModelV4Stream,
    request: LanguageModelV4RequestInfo? = nil,
    responseHeaders: SharedV4Headers? = nil
  ) {
    self.stream = stream
    self.request = request
    self.responseHeaders = responseHeaders
  }
}
