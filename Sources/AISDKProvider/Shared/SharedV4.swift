import Foundation

/// Provider-specific options passed through to the provider, keyed by provider name.
/// Mirrors upstream `SharedV4ProviderOptions`.
public typealias SharedV4ProviderOptions = [String: JSONObject]

/// Provider-specific metadata returned from the provider, keyed by provider name.
/// Mirrors upstream `SharedV4ProviderMetadata`.
public typealias SharedV4ProviderMetadata = [String: JSONObject]

/// HTTP headers. Mirrors upstream `SharedV4Headers`.
public typealias SharedV4Headers = [String: String]

/// Provider-specific file references, keyed by provider name.
/// Mirrors upstream `SharedV4ProviderReference`.
public typealias SharedV4ProviderReference = [String: String]

/// An audio format descriptor. Mirrors upstream `SharedV4AudioFormat`.
public struct SharedV4AudioFormat: Sendable, Hashable {
  public var type: String
  public var rate: Int?

  public init(type: String, rate: Int? = nil) {
    self.type = type
    self.rate = rate
  }
}

/// Warning from the model provider for a call. The call proceeds, but some
/// settings might not be supported, which can lead to suboptimal results.
/// Mirrors upstream `SharedV4Warning`.
public enum SharedV4Warning: Sendable, Hashable {
  /// A feature is not supported by the model.
  case unsupported(feature: String, details: String? = nil)
  /// A compatibility feature is used that might lead to suboptimal results.
  case compatibility(feature: String, details: String? = nil)
  /// A setting is deprecated.
  case deprecated(setting: String, message: String)
  /// Other warning.
  case other(message: String)
}

/// File data. Mirrors upstream `SharedV4FileData`.
///
/// Upstream stores raw bytes as `Uint8Array | string` (base64) under
/// `{ type: 'data' }`; here the two encodings are separate cases.
public enum SharedV4FileData: Sendable, Hashable {
  /// Raw bytes.
  case data(Data)
  /// Base64-encoded bytes.
  case base64(String)
  /// A URL that points to the file.
  case url(URL, originalURL: String? = nil)
  /// A provider reference (`[provider: id]`).
  case reference(SharedV4ProviderReference)
  /// Inline text content, e.g. an inline text document.
  case text(String)
}

extension SharedV4FileData {
  /// The raw bytes for `.data` and `.base64`, `nil` otherwise.
  public var bytes: Data? {
    switch self {
    case .data(let data): data
    case .base64(let string): Data(base64Encoded: string)
    case .url, .reference, .text: nil
    }
  }

  /// The base64 string for `.data` and `.base64`, `nil` otherwise.
  public var base64String: String? {
    switch self {
    case .data(let data): data.base64EncodedString()
    case .base64(let string): string
    case .url, .reference, .text: nil
    }
  }
}
