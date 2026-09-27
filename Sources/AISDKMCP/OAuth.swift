import AISDKProviderUtils
import Foundation

/// The outcome of `auth`. Mirrors upstream `AuthResult`.
public enum OAuthAuthResult: String, Sendable {
  case authorized = "AUTHORIZED"
  case redirect = "REDIRECT"
}

/// OAuth tokens. Mirrors upstream `OAuthTokens`.
public struct OAuthTokens: Codable, Sendable, Equatable {
  public var accessToken: String
  public var idToken: String?
  public var tokenType: String
  public var expiresIn: Double?
  public var scope: String?
  public var refreshToken: String?
  /// The issuer, authorization server and token endpoint that issued the tokens.
  public var issuer: String?
  public var authorizationServer: String?
  public var tokenEndpoint: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token", idToken = "id_token", tokenType = "token_type", expiresIn = "expires_in"
    case scope, refreshToken = "refresh_token", issuer, authorizationServer = "authorization_server"
    case tokenEndpoint = "token_endpoint"
  }

  public init(
    accessToken: String, tokenType: String = "Bearer", idToken: String? = nil, expiresIn: Double? = nil,
    scope: String? = nil, refreshToken: String? = nil, issuer: String? = nil, authorizationServer: String? = nil,
    tokenEndpoint: String? = nil
  ) {
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.idToken = idToken
    self.expiresIn = expiresIn
    self.scope = scope
    self.refreshToken = refreshToken
    self.issuer = issuer
    self.authorizationServer = authorizationServer
    self.tokenEndpoint = tokenEndpoint
  }

  init(json: JSONValue) throws {
    self = try json.decode(as: OAuthTokens.self)
    for url in [issuer, authorizationServer, tokenEndpoint].compactMap({ $0 }) { try validateSafeURL(url) }
  }
}

/// Registered OAuth client credentials. Mirrors upstream `OAuthClientInformation`;
/// after dynamic registration it also carries the registered client metadata
/// (upstream `OAuthClientInformationFull`).
public struct OAuthClientInformation: Codable, Sendable, Equatable {
  public var clientId: String
  public var clientSecret: String?
  public var clientIdIssuedAt: Double?
  public var clientSecretExpiresAt: Double?
  public var issuer: String?
  public var authorizationServer: String?
  public var tokenEndpoint: String?
  /// The metadata the authorization server registered, when known.
  public var metadata: OAuthClientMetadata?

  enum CodingKeys: String, CodingKey {
    case clientId = "client_id", clientSecret = "client_secret", clientIdIssuedAt = "client_id_issued_at"
    case clientSecretExpiresAt = "client_secret_expires_at", issuer, authorizationServer = "authorization_server"
    case tokenEndpoint = "token_endpoint"
  }

  public init(
    clientId: String, clientSecret: String? = nil, clientIdIssuedAt: Double? = nil,
    clientSecretExpiresAt: Double? = nil, issuer: String? = nil, authorizationServer: String? = nil,
    tokenEndpoint: String? = nil, metadata: OAuthClientMetadata? = nil
  ) {
    self.clientId = clientId
    self.clientSecret = clientSecret
    self.clientIdIssuedAt = clientIdIssuedAt
    self.clientSecretExpiresAt = clientSecretExpiresAt
    self.issuer = issuer
    self.authorizationServer = authorizationServer
    self.tokenEndpoint = tokenEndpoint
    self.metadata = metadata
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    clientId = try container.decode(String.self, forKey: .clientId)
    clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
    clientIdIssuedAt = try container.decodeIfPresent(Double.self, forKey: .clientIdIssuedAt)
    clientSecretExpiresAt = try container.decodeIfPresent(Double.self, forKey: .clientSecretExpiresAt)
    issuer = try container.decodeIfPresent(String.self, forKey: .issuer)
    authorizationServer = try container.decodeIfPresent(String.self, forKey: .authorizationServer)
    tokenEndpoint = try container.decodeIfPresent(String.self, forKey: .tokenEndpoint)
    metadata = try? OAuthClientMetadata(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    try metadata?.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(clientId, forKey: .clientId)
    try container.encodeIfPresent(clientSecret, forKey: .clientSecret)
    try container.encodeIfPresent(clientIdIssuedAt, forKey: .clientIdIssuedAt)
    try container.encodeIfPresent(clientSecretExpiresAt, forKey: .clientSecretExpiresAt)
    try container.encodeIfPresent(issuer, forKey: .issuer)
    try container.encodeIfPresent(authorizationServer, forKey: .authorizationServer)
    try container.encodeIfPresent(tokenEndpoint, forKey: .tokenEndpoint)
  }
}

/// Client metadata for dynamic registration (RFC 7591). Mirrors upstream `OAuthClientMetadata`.
public struct OAuthClientMetadata: Codable, Sendable, Equatable {
  public var redirectUris: [String]
  /// `native` or `web`; inferred from the redirect URIs when omitted.
  public var applicationType: String?
  public var tokenEndpointAuthMethod: String?
  public var grantTypes: [String]?
  public var responseTypes: [String]?
  public var clientName: String?
  public var clientUri: String?
  public var logoUri: String?
  public var scope: String?
  public var contacts: [String]?
  public var tosUri: String?
  public var policyUri: String?
  public var jwksUri: String?
  public var jwks: JSONValue?
  public var softwareId: String?
  public var softwareVersion: String?
  public var softwareStatement: String?

  enum CodingKeys: String, CodingKey {
    case redirectUris = "redirect_uris", applicationType = "application_type"
    case tokenEndpointAuthMethod = "token_endpoint_auth_method", grantTypes = "grant_types"
    case responseTypes = "response_types", clientName = "client_name", clientUri = "client_uri", logoUri = "logo_uri"
    case scope, contacts, tosUri = "tos_uri", policyUri = "policy_uri", jwksUri = "jwks_uri", jwks
    case softwareId = "software_id", softwareVersion = "software_version", softwareStatement = "software_statement"
  }

  public init(
    redirectUris: [String], applicationType: String? = nil, tokenEndpointAuthMethod: String? = nil,
    grantTypes: [String]? = nil, responseTypes: [String]? = nil, clientName: String? = nil, clientUri: String? = nil,
    logoUri: String? = nil, scope: String? = nil, contacts: [String]? = nil, tosUri: String? = nil,
    policyUri: String? = nil, jwksUri: String? = nil, jwks: JSONValue? = nil, softwareId: String? = nil,
    softwareVersion: String? = nil, softwareStatement: String? = nil
  ) {
    self.redirectUris = redirectUris
    self.applicationType = applicationType
    self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    self.grantTypes = grantTypes
    self.responseTypes = responseTypes
    self.clientName = clientName
    self.clientUri = clientUri
    self.logoUri = logoUri
    self.scope = scope
    self.contacts = contacts
    self.tosUri = tosUri
    self.policyUri = policyUri
    self.jwksUri = jwksUri
    self.jwks = jwks
    self.softwareId = softwareId
    self.softwareVersion = softwareVersion
    self.softwareStatement = softwareStatement
  }
}

/// The authorization server that issued stored credentials.
/// Mirrors upstream `OAuthAuthorizationServerInformation`.
public struct OAuthAuthorizationServerInformation: Codable, Sendable, Equatable {
  public var issuer: String?
  public var authorizationServerUrl: String
  public var tokenEndpoint: String

  public init(issuer: String? = nil, authorizationServerUrl: String, tokenEndpoint: String) {
    self.issuer = issuer
    self.authorizationServerUrl = authorizationServerUrl
    self.tokenEndpoint = tokenEndpoint
  }
}

/// OAuth 2.0 / OpenID authorization server metadata. Mirrors upstream `AuthorizationServerMetadata`.
public struct OAuthAuthorizationServerMetadata: Sendable, Equatable {
  public var issuer: String
  public var authorizationEndpoint: String
  public var tokenEndpoint: String
  public var registrationEndpoint: String?
  public var responseTypesSupported: [String]
  public var grantTypesSupported: [String]?
  public var codeChallengeMethodsSupported: [String]?
  public var tokenEndpointAuthMethodsSupported: [String]?
  public var scopesSupported: [String]?
  /// All metadata fields.
  public var raw: JSONObject
}

/// Storage and UI hooks for the OAuth flow. Mirrors upstream `OAuthClientProvider`;
/// upstream's optional methods have default implementations here.
public protocol OAuthClientProvider: Sendable {
  func tokens() async throws -> OAuthTokens?
  func saveTokens(_ tokens: OAuthTokens) async throws
  /// Opens the authorization URL, e.g. with `ASWebAuthenticationSession`.
  func redirectToAuthorization(_ authorizationURL: URL) async throws
  func saveCodeVerifier(_ codeVerifier: String) async throws
  func codeVerifier() async throws -> String
  var redirectURL: String { get }
  var clientMetadata: OAuthClientMetadata { get }
  func clientInformation() async throws -> OAuthClientInformation?

  /// Adds custom client authentication to token requests.
  /// - Returns: `true` when handled, `false` to use the default methods.
  func addClientAuthentication(
    headers: inout [String: String], params: inout [(String, String)], url: String,
    metadata: OAuthAuthorizationServerMetadata?
  ) async throws -> Bool
  /// Discards credentials the server rejected.
  func invalidateCredentials(_ scope: OAuthCredentialScope) async throws
  func isClientInformationDynamicallyRegistered() async throws -> Bool
  /// - Returns: `false` when the provider cannot store client information.
  func saveClientInformation(_ clientInformation: OAuthClientInformation) async throws -> Bool
  func authorizationServerInformation() async throws -> OAuthAuthorizationServerInformation?
  /// - Returns: `false` when the provider cannot store server information.
  func saveAuthorizationServerInformation(_ information: OAuthAuthorizationServerInformation) async throws -> Bool
  /// Throws to reject an authorization server discovered from resource metadata.
  func validateAuthorizationServerURL(serverURL: String, authorizationServerURL: String) async throws
  func state() async throws -> String?
  func saveState(_ state: String) async throws
  /// The state saved before redirecting; `nil` skips the state check.
  func storedState() async throws -> String?
  /// Whether `validateResourceURL` replaces the default resource check.
  var validatesResourceURL: Bool { get }
  func validateResourceURL(serverURL: URL, resource: String?) async throws -> URL?
}

/// Which credentials to invalidate. Mirrors upstream `invalidateCredentials` scopes.
public enum OAuthCredentialScope: String, Sendable {
  case all, client, tokens, verifier
}

extension OAuthClientProvider {
  public func addClientAuthentication(
    headers: inout [String: String], params: inout [(String, String)], url: String,
    metadata: OAuthAuthorizationServerMetadata?
  ) async throws -> Bool { false }
  public func invalidateCredentials(_ scope: OAuthCredentialScope) async throws {}
  public func isClientInformationDynamicallyRegistered() async throws -> Bool { false }
  public func saveClientInformation(_ clientInformation: OAuthClientInformation) async throws -> Bool { false }
  public func authorizationServerInformation() async throws -> OAuthAuthorizationServerInformation? { nil }
  public func saveAuthorizationServerInformation(_ information: OAuthAuthorizationServerInformation) async throws
    -> Bool
  { false }
  public func validateAuthorizationServerURL(serverURL: String, authorizationServerURL: String) async throws {}
  public func state() async throws -> String? { nil }
  public func saveState(_ state: String) async throws {}
  public func storedState() async throws -> String? { nil }
  public var validatesResourceURL: Bool { false }
  public func validateResourceURL(serverURL: URL, resource: String?) async throws -> URL? { nil }
}

/// An OAuth error response. Mirrors upstream `MCPClientOAuthError` and its subclasses.
public struct MCPClientOAuthError: AISDKError {
  /// The OAuth `error` code, e.g. `invalid_grant`; `server_error` for unparseable responses.
  public enum Kind: String, Sendable {
    case generic, serverError = "server_error", invalidClient = "invalid_client", invalidGrant = "invalid_grant"
    case unauthorizedClient = "unauthorized_client"
  }

  public let name: String
  public let message: String
  public let kind: Kind
  public let cause: (any Error)?

  public init(kind: Kind = .generic, message: String, cause: (any Error)? = nil) {
    self.kind = kind
    self.message = message
    self.cause = cause
    self.name =
      switch kind {
      case .generic: "MCPClientOAuthError"
      case .serverError: "ServerError"
      case .invalidClient: "InvalidClientError"
      case .invalidGrant: "InvalidGrantError"
      case .unauthorizedClient: "UnauthorizedClientError"
      }
  }
}

/// Authorization is required and was not completed. Mirrors upstream `UnauthorizedError`.
public struct UnauthorizedError: Error, CustomStringConvertible {
  public var message: String

  public init(message: String = "Unauthorized") {
    self.message = message
  }

  public var description: String { message }
}

/// A plain error for incompatible or unexpected OAuth server behavior.
struct OAuthFlowError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

func validateSafeURL(_ value: String) throws {
  guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(), !scheme.isEmpty
  else { throw OAuthFlowError("URL must be parseable: \(value)") }
  if ["javascript", "data", "vbscript"].contains(scheme) {
    throw OAuthFlowError("URL cannot use javascript:, data:, or vbscript: scheme")
  }
}

private func normalizeURL(_ value: String) -> String {
  guard var components = URLComponents(string: value) else { return value }
  components.scheme = components.scheme?.lowercased()
  components.host = components.host?.lowercased()
  if components.path.isEmpty { components.path = "/" }
  if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
    components.port = nil
  }
  return components.string ?? value
}

private func resolve(_ path: String, against base: String) -> String {
  URL(string: path, relativeTo: URL(string: base))?.absoluteString ?? path
}

/// Loopback hosts allowed for local OAuth servers (RFC 8252 §7.3).
func isOAuthLoopbackHost(_ hostname: String) -> Bool {
  var normalized = hostname.lowercased()
  while normalized.hasSuffix(".") { normalized.removeLast() }
  return normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized == "127.0.0.1"
    || normalized == "[::1]" || normalized == "::1"
}

private func host(_ url: String) -> String { URLComponents(string: url)?.host ?? "" }

private func assertSafeOAuthEndpoint(_ endpoint: String, allowLoopback: Bool = false) throws {
  let scheme = URLComponents(string: endpoint)?.scheme?.lowercased()
  if allowLoopback, scheme == "http" || scheme == "https", isOAuthLoopbackHost(host(endpoint)) { return }
  do {
    try validateDownloadUrl(endpoint)
  } catch {
    throw MCPClientOAuthError(message: "OAuth endpoint URL is not allowed: \(endpoint)", cause: error)
  }
}

private func trustedLoopbackOrigin(_ authorizationServerURL: String) -> String? {
  isOAuthLoopbackHost(host(authorizationServerURL)) ? urlOrigin(authorizationServerURL) : nil
}

/// Reads `resource_metadata` and `scope` from a `WWW-Authenticate: Bearer` header.
/// Mirrors upstream `extractWWWAuthenticateParams`.
public func extractWWWAuthenticateParams(_ headers: [String: String]) -> (resourceMetadataURL: URL?, scope: String?) {
  guard let header = headers["www-authenticate"] ?? headers["WWW-Authenticate"] else { return (nil, nil) }
  let parts = header.split(separator: " ", maxSplits: 1)
  guard parts.count == 2, parts[0].lowercased() == "bearer" else { return (nil, nil) }

  func parameter(_ name: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: "(?:^|[,\\s])\(name)=\"([^\"]*)\"", options: [.caseInsensitive]),
      let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
      let range = Range(match.range(at: 1), in: header)
    else { return nil }
    return String(header[range])
  }

  let metadataURL = parameter("resource_metadata").flatMap { value -> URL? in
    guard let url = URL(string: value), url.scheme != nil else { return nil }
    return url
  }
  return (metadataURL, parameter("scope"))
}

/// The resource URL for a server URL, without its fragment. Mirrors upstream `resourceUrlFromServerUrl`.
func resourceURLFromServerURL(_ url: String) -> String {
  guard var components = URLComponents(string: url) else { return url }
  components.fragment = nil
  return normalizeURL(components.string ?? url)
}

/// Mirrors upstream `resourceUrlStripSlash`.
func resourceURLStripSlash(_ resource: String) -> String {
  let normalized = normalizeURL(resource)
  if URLComponents(string: normalized)?.path == "/", normalized.hasSuffix("/"), URLComponents(string: normalized)?.query == nil {
    return String(normalized.dropLast())
  }
  return normalized
}

/// Mirrors upstream `checkResourceAllowed`.
func checkResourceAllowed(requested: String, configured: String) -> Bool {
  guard urlOrigin(requested) == urlOrigin(configured), let requestedPath = URLComponents(string: requested)?.path,
    let configuredPath = URLComponents(string: configured)?.path
  else { return false }
  let requestedNormalized = requestedPath.isEmpty ? "/" : requestedPath
  let configuredNormalized = configuredPath.isEmpty ? "/" : configuredPath
  guard requestedNormalized.count >= configuredNormalized.count else { return false }
  let requestedSlash = requestedNormalized.hasSuffix("/") ? requestedNormalized : requestedNormalized + "/"
  let configuredSlash = configuredNormalized.hasSuffix("/") ? configuredNormalized : configuredNormalized + "/"
  return requestedSlash.hasPrefix(configuredSlash)
}

/// OAuth discovery, registration and token requests for MCP servers.
/// Mirrors the functions in upstream `oauth.ts`.
public struct MCPOAuth: Sendable {
  public var httpClient: (any HTTPClient)?

  public init(httpClient: (any HTTPClient)? = nil) {
    self.httpClient = httpClient
  }

  private func fetchWithCorsRetry(_ url: String, headers: [String: String]?, trustedOrigin: String?) async throws
    -> HTTPResponse?
  {
    do {
      return try await fetchUntrustedUrl(
        url: url, headers: headers, untrustedFirstHopHeaders: ["mcp-protocol-version"], trustedOrigin: trustedOrigin,
        httpClient: httpClient)
    } catch let error where error is URLError {
      if headers != nil { return try await fetchWithCorsRetry(url, headers: nil, trustedOrigin: trustedOrigin) }
      return nil
    }
  }

  private func wellKnownPath(_ prefix: String, _ pathname: String) -> String {
    var pathname = pathname
    if pathname.hasSuffix("/") { pathname.removeLast() }
    return "/.well-known/\(prefix)\(pathname)"
  }

  /// Mirrors upstream `discoverOAuthProtectedResourceMetadata`.
  public func discoverProtectedResourceMetadata(
    serverURL: String, resourceMetadataURL: String? = nil, protocolVersion: String = MCP_LATEST_PROTOCOL_VERSION
  ) async throws -> JSONObject {
    let headers = ["MCP-Protocol-Version": protocolVersion]
    let trustedOrigin = urlOrigin(serverURL)
    let url: String
    if let resourceMetadataURL {
      url = resourceMetadataURL
    } else {
      var components = URLComponents(string: serverURL)
      let issuerPath = components?.path ?? ""
      components?.path = wellKnownPath("oauth-protected-resource", issuerPath)
      url = components?.string ?? serverURL
    }
    var response = try await fetchWithCorsRetry(url, headers: headers, trustedOrigin: trustedOrigin)
    let pathname = URLComponents(string: serverURL)?.path ?? "/"
    if resourceMetadataURL == nil,
      response == nil || ((400..<500).contains(response?.statusCode ?? 0) && pathname != "/" && !pathname.isEmpty)
    {
      response = try await fetchWithCorsRetry(
        resolve("/.well-known/oauth-protected-resource", against: serverURL), headers: headers, trustedOrigin: trustedOrigin)
    }
    guard let response, response.statusCode != 404 else {
      throw OAuthFlowError("Resource server does not implement OAuth 2.0 Protected Resource Metadata.")
    }
    guard response.isOK else {
      throw OAuthFlowError("HTTP \(response.statusCode) trying to load well-known OAuth protected resource metadata.")
    }
    guard case .object(let metadata) = try JSONValue(jsonData: try await response.bodyData()),
      let resource = metadata["resource"]?.stringValue, URL(string: resource)?.scheme != nil
    else { throw OAuthFlowError("Invalid OAuth protected resource metadata") }
    for server in metadata["authorization_servers"]?.arrayValue ?? [] {
      guard let server = server.stringValue else { throw OAuthFlowError("Invalid authorization server URL") }
      try validateSafeURL(server)
    }
    return metadata
  }

  /// Discovery URLs in priority order. Mirrors upstream `buildDiscoveryUrls`.
  public func discoveryURLs(_ authorizationServerURL: String) -> [(url: String, type: String, expectedIssuer: String)] {
    let origin = urlOrigin(authorizationServerURL) ?? authorizationServerURL
    var pathname = URLComponents(string: authorizationServerURL)?.path ?? ""
    if pathname.isEmpty || pathname == "/" {
      return [
        ("\(origin)/.well-known/oauth-authorization-server", "oauth", origin),
        ("\(origin)/.well-known/openid-configuration", "oidc", origin),
      ]
    }
    if pathname.hasSuffix("/") { pathname.removeLast() }
    let pathIssuer = "\(origin)\(pathname)"
    return [
      ("\(origin)/.well-known/oauth-authorization-server\(pathname)", "oauth", pathIssuer),
      ("\(origin)/.well-known/oauth-authorization-server", "oauth", origin),
      ("\(origin)/.well-known/openid-configuration\(pathname)", "oidc", pathIssuer),
      ("\(origin)\(pathname)/.well-known/openid-configuration", "oidc", pathIssuer),
    ]
  }

  private func parseAuthorizationServerMetadata(_ object: JSONObject, oidc: Bool) throws
    -> OAuthAuthorizationServerMetadata
  {
    func strings(_ key: String) -> [String]? { object[key]?.arrayValue?.compactMap(\.stringValue) }
    guard let issuer = object["issuer"]?.stringValue, let authorizationEndpoint = object["authorization_endpoint"]?.stringValue,
      let tokenEndpoint = object["token_endpoint"]?.stringValue, let responseTypes = strings("response_types_supported")
    else { throw OAuthFlowError("Invalid OAuth authorization server metadata") }
    try validateSafeURL(authorizationEndpoint)
    try validateSafeURL(tokenEndpoint)
    if let registration = object["registration_endpoint"]?.stringValue { try validateSafeURL(registration) }
    if oidc {
      guard let jwks = object["jwks_uri"]?.stringValue, strings("subject_types_supported") != nil,
        strings("id_token_signing_alg_values_supported") != nil
      else { throw OAuthFlowError("Invalid OpenID provider metadata") }
      try validateSafeURL(jwks)
    }
    return OAuthAuthorizationServerMetadata(
      issuer: issuer, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint,
      registrationEndpoint: object["registration_endpoint"]?.stringValue, responseTypesSupported: responseTypes,
      grantTypesSupported: strings("grant_types_supported"),
      codeChallengeMethodsSupported: strings("code_challenge_methods_supported"),
      tokenEndpointAuthMethodsSupported: strings("token_endpoint_auth_methods_supported"),
      scopesSupported: strings("scopes_supported"), raw: object)
  }

  /// Mirrors upstream `discoverAuthorizationServerMetadata`.
  public func discoverAuthorizationServerMetadata(
    _ authorizationServerURL: String, protocolVersion: String = MCP_LATEST_PROTOCOL_VERSION, trustedOrigin: String? = nil
  ) async throws -> OAuthAuthorizationServerMetadata? {
    for (endpoint, type, expectedIssuer) in discoveryURLs(authorizationServerURL) {
      guard
        let response = try await fetchWithCorsRetry(
          endpoint, headers: ["MCP-Protocol-Version": protocolVersion], trustedOrigin: trustedOrigin)
      else { continue }
      guard response.isOK else {
        if (400..<500).contains(response.statusCode) { continue }
        throw OAuthFlowError(
          "HTTP \(response.statusCode) trying to load \(type == "oauth" ? "OAuth" : "OpenID provider") metadata from \(endpoint)")
      }
      guard case .object(let object) = try JSONValue(jsonData: try await response.bodyData()) else {
        throw OAuthFlowError("Invalid authorization server metadata from \(endpoint)")
      }
      let metadata = try parseAuthorizationServerMetadata(object, oidc: type == "oidc")
      let issuerMatches =
        metadata.issuer == expectedIssuer || (expectedIssuer == urlOrigin(expectedIssuer) && metadata.issuer == "\(expectedIssuer)/")
      guard issuerMatches else {
        throw MCPClientOAuthError(
          message:
            "OAuth authorization server metadata issuer \(metadata.issuer) does not match expected issuer \(expectedIssuer)")
      }
      if type == "oidc", metadata.codeChallengeMethodsSupported?.contains("S256") != true {
        throw OAuthFlowError(
          "Incompatible OIDC provider at \(endpoint): does not support S256 code challenge method required by MCP specification")
      }
      return metadata
    }
    return nil
  }

  /// Builds the authorization URL with a PKCE S256 challenge. Mirrors upstream `startAuthorization`.
  public func startAuthorization(
    _ authorizationServerURL: String, metadata: OAuthAuthorizationServerMetadata?,
    clientInformation: OAuthClientInformation, redirectURL: String, scope: String? = nil, state: String? = nil,
    resource: String? = nil
  ) throws -> (authorizationURL: URL, codeVerifier: String) {
    let endpoint: String
    if let metadata {
      endpoint = metadata.authorizationEndpoint
      guard metadata.responseTypesSupported.contains("code") else {
        throw OAuthFlowError("Incompatible auth server: does not support response type code")
      }
      guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
        throw OAuthFlowError("Incompatible auth server: does not support code challenge method S256")
      }
    } else {
      endpoint = resolve("/authorize", against: authorizationServerURL)
    }
    let challenge = PKCEChallenge.generate()
    guard var components = URLComponents(string: endpoint) else { throw OAuthFlowError("Invalid authorization endpoint") }
    var items = (components.queryItems ?? []).filter {
      !["response_type", "client_id", "code_challenge", "code_challenge_method", "redirect_uri", "state", "scope", "resource"]
        .contains($0.name)
    }
    items += [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientInformation.clientId),
      URLQueryItem(name: "code_challenge", value: challenge.codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "redirect_uri", value: redirectURL),
    ]
    if let state, !state.isEmpty { items.append(URLQueryItem(name: "state", value: state)) }
    if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
    if scope?.contains("offline_access") == true { items.append(URLQueryItem(name: "prompt", value: "consent")) }
    if let resource { items.append(URLQueryItem(name: "resource", value: resourceURLStripSlash(resource))) }
    components.percentEncodedQueryItems = items.map {
      URLQueryItem(name: $0.name, value: $0.value.map(formEncode))
    }
    guard let url = components.url else { throw OAuthFlowError("Invalid authorization URL") }
    return (url, challenge.codeVerifier)
  }

  private func selectClientAuthMethod(_ info: OAuthClientInformation, supported: [String]) -> String {
    let hasSecret = info.clientSecret != nil
    if supported.isEmpty { return hasSecret ? "client_secret_post" : "none" }
    if hasSecret && supported.contains("client_secret_basic") { return "client_secret_basic" }
    if hasSecret && supported.contains("client_secret_post") { return "client_secret_post" }
    if supported.contains("none") { return "none" }
    return hasSecret ? "client_secret_post" : "none"
  }

  private func applyClientAuthentication(
    _ method: String, _ info: OAuthClientInformation, headers: inout [String: String], params: inout [(String, String)]
  ) throws {
    switch method {
    case "client_secret_basic":
      guard let secret = info.clientSecret, !secret.isEmpty else {
        throw OAuthFlowError("client_secret_basic authentication requires a client_secret")
      }
      headers["Authorization"] = "Basic \(Data("\(info.clientId):\(secret)".utf8).base64EncodedString())"
    case "client_secret_post":
      setParam(&params, "client_id", info.clientId)
      if let secret = info.clientSecret, !secret.isEmpty { setParam(&params, "client_secret", secret) }
    default:
      setParam(&params, "client_id", info.clientId)
    }
  }

  /// Converts an OAuth error body into `MCPClientOAuthError`. Mirrors upstream `parseErrorResponse`.
  public func parseErrorResponse(statusCode: Int?, body: String) -> MCPClientOAuthError {
    if case .object(let object)? = try? JSONValue(jsonString: body), let error = object["error"]?.stringValue {
      return MCPClientOAuthError(
        kind: MCPClientOAuthError.Kind(rawValue: error) ?? .serverError,
        message: object["error_description"]?.stringValue ?? "",
        cause: object["error_uri"]?.stringValue.map(OAuthFlowError.init))
    }
    let prefix = statusCode.map { "HTTP \($0): " } ?? ""
    return MCPClientOAuthError(
      kind: .serverError, message: "\(prefix)Invalid OAuth error response: invalid error body. Raw body: \(body)")
  }

  private func postTokenRequest(
    _ authorizationServerURL: String, metadata: OAuthAuthorizationServerMetadata?, grantType: String,
    params initialParams: [(String, String)], clientInformation: OAuthClientInformation, resource: String?,
    provider: (any OAuthClientProvider)?
  ) async throws -> JSONValue {
    let tokenURL = metadata.map(\.tokenEndpoint) ?? resolve("/token", against: authorizationServerURL)
    let trustedOrigin = trustedLoopbackOrigin(authorizationServerURL)
    try assertSafeOAuthEndpoint(tokenURL, allowLoopback: urlOrigin(tokenURL) == trustedOrigin && trustedOrigin != nil)
    if let supported = metadata?.grantTypesSupported, !supported.contains(grantType) {
      throw OAuthFlowError("Incompatible auth server: does not support grant type \(grantType)")
    }
    var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
    var params = initialParams
    let handled =
      try await provider?.addClientAuthentication(
        headers: &headers, params: &params, url: authorizationServerURL, metadata: metadata) ?? false
    if !handled {
      let method = selectClientAuthMethod(clientInformation, supported: metadata?.tokenEndpointAuthMethodsSupported ?? [])
      try applyClientAuthentication(method, clientInformation, headers: &headers, params: &params)
    }
    if let resource { setParam(&params, "resource", resourceURLStripSlash(resource)) }
    guard let url = URL(string: tokenURL) else { throw OAuthFlowError("Invalid token endpoint") }
    let response = try await fetchWithValidatedEndpoint(
      HTTPRequest(method: "POST", url: url, headers: headers, body: Data(formBody(params).utf8)), httpClient: httpClient,
      trustedOrigin: trustedOrigin)
    let body = try await response.bodyText()
    guard response.isOK else { throw parseErrorResponse(statusCode: response.statusCode, body: body) }
    return try JSONValue(jsonString: body)
  }

  /// Exchanges an authorization code for tokens. Mirrors upstream `exchangeAuthorization`.
  public func exchangeAuthorization(
    _ authorizationServerURL: String, metadata: OAuthAuthorizationServerMetadata?,
    clientInformation: OAuthClientInformation, authorizationCode: String, codeVerifier: String, redirectURI: String,
    resource: String? = nil, provider: (any OAuthClientProvider)? = nil
  ) async throws -> OAuthTokens {
    let json = try await postTokenRequest(
      authorizationServerURL, metadata: metadata, grantType: "authorization_code",
      params: [
        ("grant_type", "authorization_code"), ("code", authorizationCode), ("code_verifier", codeVerifier),
        ("redirect_uri", redirectURI),
      ], clientInformation: clientInformation, resource: resource, provider: provider)
    return try OAuthTokens(json: json)
  }

  /// Refreshes tokens, keeping the old refresh token when none is returned.
  /// Mirrors upstream `refreshAuthorization`.
  public func refreshAuthorization(
    _ authorizationServerURL: String, metadata: OAuthAuthorizationServerMetadata?,
    clientInformation: OAuthClientInformation, refreshToken: String, resource: String? = nil,
    provider: (any OAuthClientProvider)? = nil
  ) async throws -> OAuthTokens {
    var json = try await postTokenRequest(
      authorizationServerURL, metadata: metadata, grantType: "refresh_token",
      params: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)], clientInformation: clientInformation,
      resource: resource, provider: provider
    ).objectValue ?? [:]
    if json["refresh_token"] == nil { json["refresh_token"] = .string(refreshToken) }
    return try OAuthTokens(json: .object(json))
  }

  /// Dynamic client registration (RFC 7591). Mirrors upstream `registerClient`.
  public func registerClient(
    _ authorizationServerURL: String, metadata: OAuthAuthorizationServerMetadata?, clientMetadata: OAuthClientMetadata
  ) async throws -> OAuthClientInformation {
    let registrationURL: String
    if let metadata {
      guard let endpoint = metadata.registrationEndpoint else {
        throw OAuthFlowError("Incompatible auth server: does not support dynamic client registration")
      }
      registrationURL = endpoint
    } else {
      registrationURL = resolve("/register", against: authorizationServerURL)
    }
    let trustedOrigin = trustedLoopbackOrigin(authorizationServerURL)
    try assertSafeOAuthEndpoint(
      registrationURL, allowLoopback: trustedOrigin != nil && urlOrigin(registrationURL) == trustedOrigin)

    var body = try JSONValue(encoding: clientMetadata).objectValue ?? [:]
    body["application_type"] = .string(clientMetadata.applicationType ?? inferApplicationType(clientMetadata.redirectUris))
    guard let url = URL(string: registrationURL) else { throw OAuthFlowError("Invalid registration endpoint") }
    let response = try await fetchWithValidatedEndpoint(
      HTTPRequest(
        method: "POST", url: url, headers: ["Content-Type": "application/json"],
        body: try JSONValue.object(body).jsonData(sortedKeys: false)),
      httpClient: httpClient, trustedOrigin: trustedOrigin)
    let text = try await response.bodyText()
    guard response.isOK else { throw parseErrorResponse(statusCode: response.statusCode, body: text) }
    let json = try JSONValue(jsonString: text)
    let information = try json.decode(as: OAuthClientInformation.self)
    guard let metadata = information.metadata else {
      throw OAuthFlowError("Invalid client registration response: redirect_uris must be an array of URLs")
    }
    for url in
      [information.issuer, information.authorizationServer, information.tokenEndpoint, metadata.clientUri,
        metadata.logoUri, metadata.tosUri, metadata.jwksUri].compactMap({ $0 }) + metadata.redirectUris
    {
      try validateSafeURL(url)
    }
    return information
  }

  private func inferApplicationType(_ redirectURIs: [String]) -> String {
    let allNative = redirectURIs.allSatisfy { uri in
      let scheme = URLComponents(string: uri)?.scheme?.lowercased() ?? ""
      return ((scheme == "http" || scheme == "https") && isOAuthLoopbackHost(host(uri))) || (scheme != "http" && scheme != "https")
    }
    return allNative ? "native" : "web"
  }

  /// Chooses the resource indicator sent to the authorization server.
  /// Mirrors upstream `selectResourceURL`.
  public func selectResourceURL(serverURL: String, provider: any OAuthClientProvider, resourceMetadata: JSONObject?)
    async throws -> String?
  {
    let defaultResource = resourceURLFromServerURL(serverURL)
    if provider.validatesResourceURL {
      return try await provider.validateResourceURL(
        serverURL: URL(string: defaultResource) ?? URL(fileURLWithPath: "/"), resource: resourceMetadata?["resource"]?.stringValue
      )?.absoluteString
    }
    guard let resource = resourceMetadata?["resource"]?.stringValue else { return nil }
    guard checkResourceAllowed(requested: defaultResource, configured: resource) else {
      throw OAuthFlowError("Protected resource \(resource) does not match expected \(defaultResource) (or origin)")
    }
    return resource
  }
}

private let formAllowed = CharacterSet(
  charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")

/// `application/x-www-form-urlencoded` value encoding, matching `URLSearchParams`.
func formEncode(_ value: String) -> String {
  value.addingPercentEncoding(withAllowedCharacters: formAllowed)?.replacingOccurrences(of: "%20", with: "+") ?? value
}

func formBody(_ params: [(String, String)]) -> String {
  params.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
}

private func setParam(_ params: inout [(String, String)], _ name: String, _ value: String) {
  if let index = params.firstIndex(where: { $0.0 == name }) {
    params[index].1 = value
    params.removeAll { $0.0 == name && $0.1 != value }
  } else {
    params.append((name, value))
  }
}
