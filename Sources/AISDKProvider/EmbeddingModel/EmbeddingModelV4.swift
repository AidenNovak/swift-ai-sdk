/// Specification for an embedding model that implements the embedding model
/// interface version 4. Mirrors upstream `EmbeddingModelV4`.
public protocol EmbeddingModelV4: Sendable {
  /// The embedding model interface version. Always `"v4"`.
  var specificationVersion: String { get }

  /// Provider ID.
  var provider: String { get }

  /// Provider-specific model ID.
  var modelId: String { get }

  /// Limit of how many embeddings can be generated in a single call.
  /// `nil` means there is no limit.
  var maxEmbeddingsPerCall: Int? { get async throws }

  /// Whether the model can handle multiple embedding calls in parallel.
  var supportsParallelCalls: Bool { get async throws }

  /// Generates a list of embeddings for the given input values.
  ///
  /// The `do` prefix discourages calling the method directly; use `embed`
  /// and `embedMany` instead.
  func doEmbed(_ options: EmbeddingModelV4CallOptions) async throws -> EmbeddingModelV4Result
}

extension EmbeddingModelV4 {
  public var specificationVersion: String { "v4" }
}

/// An embedding vector. Mirrors upstream `EmbeddingModelV4Embedding`.
public typealias EmbeddingModelV4Embedding = [Double]

/// Options for an embedding call. Mirrors upstream `EmbeddingModelV4CallOptions`.
public struct EmbeddingModelV4CallOptions: Sendable, Equatable {
  /// Values to embed.
  public var values: [String]
  public var providerOptions: SharedV4ProviderOptions?
  /// Additional HTTP headers. Only applicable for HTTP-based providers.
  public var headers: SharedV4Headers?

  public init(
    values: [String],
    providerOptions: SharedV4ProviderOptions? = nil,
    headers: SharedV4Headers? = nil
  ) {
    self.values = values
    self.providerOptions = providerOptions
    self.headers = headers
  }
}

/// Result of an embedding call. Mirrors upstream `EmbeddingModelV4Result`.
public struct EmbeddingModelV4Result: Sendable, Equatable {
  public struct Usage: Sendable, Hashable {
    public var tokens: Int

    public init(tokens: Int) {
      self.tokens = tokens
    }
  }

  public struct Response: Sendable, Equatable {
    public var headers: SharedV4Headers?
    public var body: JSONValue?

    public init(headers: SharedV4Headers? = nil, body: JSONValue? = nil) {
      self.headers = headers
      self.body = body
    }
  }

  /// Embeddings in the same order as the input values.
  public var embeddings: [EmbeddingModelV4Embedding]
  public var usage: Usage?
  public var providerMetadata: SharedV4ProviderMetadata?
  public var response: Response?
  public var warnings: [SharedV4Warning]

  public init(
    embeddings: [EmbeddingModelV4Embedding],
    usage: Usage? = nil,
    providerMetadata: SharedV4ProviderMetadata? = nil,
    response: Response? = nil,
    warnings: [SharedV4Warning] = []
  ) {
    self.embeddings = embeddings
    self.usage = usage
    self.providerMetadata = providerMetadata
    self.response = response
    self.warnings = warnings
  }
}
