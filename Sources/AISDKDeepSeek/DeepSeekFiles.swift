import AISDKProviderUtils
import Foundation

/// A file stored with DeepSeek. Mirrors the OpenAI-compatible file object.
public struct DeepSeekFile: Decodable, Sendable, Equatable {
  /// The file ID, e.g. `file-api-...`.
  public var id: String
  public var bytes: Int?
  public var createdAt: Date?
  public var filename: String?
  public var purpose: String?
  public var expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, bytes, filename, purpose
    case createdAt = "created_at"
    case expiresAt = "expires_at"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    bytes = try container.decodeIfPresent(Int.self, forKey: .bytes)
    filename = try container.decodeIfPresent(String.self, forKey: .filename)
    purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
    createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt).map { Date(timeIntervalSince1970: $0) }
    expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt).map { Date(timeIntervalSince1970: $0) }
  }

  /// A provider reference for use in prompts, e.g.
  /// `FilePart(data: .reference(file.reference), mediaType: "image")`.
  public var reference: SharedV4ProviderReference { ["deepseek": id] }
}

/// A page of files. Mirrors the OpenAI-compatible list object.
public struct DeepSeekFileList: Decodable, Sendable, Equatable {
  public var data: [DeepSeekFile]
  public var firstId: String?
  public var lastId: String?
  public var hasMore: Bool

  enum CodingKeys: String, CodingKey {
    case data
    case firstId = "first_id"
    case lastId = "last_id"
    case hasMore = "has_more"
  }
}

struct DeepSeekDeletedFile: Decodable, Sendable {
  var id: String
  var deleted: Bool
}

/// The DeepSeek Files API: upload images once and reference them by ID.
///
/// Supports JPEG, PNG, GIF and WebP, up to 64 MiB per file.
public struct DeepSeekFiles: Sendable {
  let baseURL: String
  let headers: @Sendable () throws -> [String: String]
  let httpClient: (any HTTPClient)?

  private var failedResponseHandler: ResponseHandler<APICallError> {
    createJsonErrorResponseHandler(errorType: DeepSeekErrorData.self, errorToMessage: { $0.error.message })
  }

  /// Uploads a file.
  ///
  /// - Parameter expiresAfterSeconds: Lifetime between 3600 and 2592000
  ///   seconds. `nil` keeps the file permanently.
  public func upload(
    data: Data, filename: String, mediaType: String, expiresAfterSeconds: Int? = nil
  ) async throws -> DeepSeekFile {
    if let seconds = expiresAfterSeconds, !(3600...2_592_000).contains(seconds) {
      throw InvalidArgumentError(
        argument: "expiresAfterSeconds", message: "expiresAfterSeconds must be between 3600 and 2592000")
    }
    var form = MultipartFormData()
    form.append("purpose", "user_data")
    if let seconds = expiresAfterSeconds {
      form.append("expires_after[anchor]", "created_at")
      form.append("expires_after[seconds]", String(seconds))
    }
    form.append("file", data: data, filename: filename, mediaType: mediaType)

    return try await postFormDataToApi(
      url: "\(baseURL)/files", headers: try headers(), formData: form,
      failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekFile.self), httpClient: httpClient
    ).value
  }

  /// Lists files.
  public func list(after: String? = nil, limit: Int? = nil, order: String? = nil) async throws -> DeepSeekFileList {
    var components = URLComponents(string: "\(baseURL)/files")!
    var query: [URLQueryItem] = []
    if let after { query.append(URLQueryItem(name: "after", value: after)) }
    if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let order { query.append(URLQueryItem(name: "order", value: order)) }
    components.queryItems = query.isEmpty ? nil : query

    return try await getFromApi(
      url: components.string!, headers: try headers(), failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekFileList.self), httpClient: httpClient
    ).value
  }

  /// Retrieves file information.
  public func retrieve(_ fileId: String) async throws -> DeepSeekFile {
    try await getFromApi(
      url: "\(baseURL)/files/\(fileId)", headers: try headers(), failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekFile.self), httpClient: httpClient
    ).value
  }

  /// Deletes a file. Returns whether it was deleted.
  @discardableResult
  public func delete(_ fileId: String) async throws -> Bool {
    try await deleteFromApi(
      url: "\(baseURL)/files/\(fileId)", headers: try headers(), failedResponseHandler: failedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(DeepSeekDeletedFile.self), httpClient: httpClient
    ).value.deleted
  }
}

/// A model available to the API key. Mirrors the `GET /models` entries.
public struct DeepSeekModelInfo: Decodable, Sendable, Equatable {
  public struct Effort: Decodable, Sendable, Equatable {
    public var supportedLevels: [String]?
    public var defaultLevel: String?

    enum CodingKeys: String, CodingKey {
      case supportedLevels = "supported_levels"
      case defaultLevel = "default_level"
    }
  }

  public var id: String
  public var name: String?
  public var ownedBy: String?
  public var contextWindow: Int?
  public var maxOutputTokens: Int?
  public var inputModalities: [String]?
  public var outputModalities: [String]?
  public var effort: Effort?

  enum CodingKeys: String, CodingKey {
    case id, name, effort
    case ownedBy = "owned_by"
    case contextWindow = "context_window"
    case maxOutputTokens = "max_output_tokens"
    case inputModalities = "input_modalities"
    case outputModalities = "output_modalities"
  }

  /// Whether the model accepts image input.
  public var supportsImages: Bool { inputModalities?.contains("image") ?? false }
}

struct DeepSeekModelList: Decodable, Sendable {
  var data: [DeepSeekModelInfo]
}

/// The account balance. Mirrors `GET /user/balance`.
public struct DeepSeekBalance: Decodable, Sendable, Equatable {
  public struct Info: Decodable, Sendable, Equatable {
    public var currency: String
    public var totalBalance: String
    public var grantedBalance: String
    public var toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
      case currency
      case totalBalance = "total_balance"
      case grantedBalance = "granted_balance"
      case toppedUpBalance = "topped_up_balance"
    }
  }

  /// Whether the balance is sufficient for API calls.
  public var isAvailable: Bool
  public var balanceInfos: [Info]

  enum CodingKeys: String, CodingKey {
    case isAvailable = "is_available"
    case balanceInfos = "balance_infos"
  }
}
