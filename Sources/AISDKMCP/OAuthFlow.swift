import AISDKProviderUtils
import Foundation

private func normalizedURL(_ value: String) -> String {
  guard var components = URLComponents(string: value) else { return value }
  components.scheme = components.scheme?.lowercased()
  components.host = components.host?.lowercased()
  if components.path.isEmpty { components.path = "/" }
  return components.string ?? value
}

private func serverInformation(_ authorizationServerURL: String, _ metadata: OAuthAuthorizationServerMetadata?)
  -> OAuthAuthorizationServerInformation
{
  OAuthAuthorizationServerInformation(
    issuer: metadata?.issuer ?? authorizationServerURL,
    authorizationServerUrl: normalizedURL(authorizationServerURL),
    tokenEndpoint: normalizedURL(
      metadata?.tokenEndpoint ?? (URL(string: "/token", relativeTo: URL(string: authorizationServerURL))?.absoluteString
        ?? authorizationServerURL)))
}

private func information(issuer: String?, authorizationServer: String?, tokenEndpoint: String?)
  -> OAuthAuthorizationServerInformation?
{
  guard let authorizationServer, !authorizationServer.isEmpty, let tokenEndpoint, !tokenEndpoint.isEmpty else {
    return nil
  }
  return OAuthAuthorizationServerInformation(
    issuer: issuer, authorizationServerUrl: normalizedURL(authorizationServer), tokenEndpoint: normalizedURL(tokenEndpoint))
}

private func storedServerInformation(
  provider: any OAuthClientProvider, clientInformation: OAuthClientInformation, tokens: OAuthTokens? = nil
) async throws -> OAuthAuthorizationServerInformation? {
  if let fromTokens = information(
    issuer: tokens?.issuer, authorizationServer: tokens?.authorizationServer, tokenEndpoint: tokens?.tokenEndpoint)
  {
    return fromTokens
  }
  if let fromProvider = try await provider.authorizationServerInformation() {
    return OAuthAuthorizationServerInformation(
      issuer: fromProvider.issuer, authorizationServerUrl: normalizedURL(fromProvider.authorizationServerUrl),
      tokenEndpoint: normalizedURL(fromProvider.tokenEndpoint))
  }
  return information(
    issuer: clientInformation.issuer, authorizationServer: clientInformation.authorizationServer,
    tokenEndpoint: clientInformation.tokenEndpoint)
}

private func assertMatches(_ stored: OAuthAuthorizationServerInformation, _ current: OAuthAuthorizationServerInformation)
  throws
{
  let issuerMismatch = stored.issuer != nil && current.issuer != nil && stored.issuer != current.issuer
  if issuerMismatch || stored.authorizationServerUrl != current.authorizationServerUrl
    || stored.tokenEndpoint != current.tokenEndpoint
  {
    throw MCPClientOAuthError(
      message: "OAuth authorization server metadata does not match the metadata that issued the stored credentials")
  }
}

private func pinned(_ tokens: OAuthTokens, _ information: OAuthAuthorizationServerInformation) -> OAuthTokens {
  var tokens = tokens
  tokens.issuer = information.issuer
  tokens.authorizationServer = information.authorizationServerUrl
  tokens.tokenEndpoint = information.tokenEndpoint
  return tokens
}

private func pinned(_ client: OAuthClientInformation, _ information: OAuthAuthorizationServerInformation)
  -> OAuthClientInformation
{
  var client = client
  client.issuer = information.issuer
  client.authorizationServer = information.authorizationServerUrl
  client.tokenEndpoint = information.tokenEndpoint
  return client
}

/// Options for `auth`. Mirrors the upstream options object.
public struct OAuthOptions: Sendable {
  public var serverURL: String
  /// The `code` from the authorization callback, to exchange for tokens.
  public var authorizationCode: String?
  /// The `state` from the authorization callback.
  public var callbackState: String?
  /// The `iss` from the authorization callback.
  public var callbackIssuer: String?
  public var scope: String?
  public var resourceMetadataURL: URL?
  public var httpClient: (any HTTPClient)?

  public init(
    serverURL: String, authorizationCode: String? = nil, callbackState: String? = nil, callbackIssuer: String? = nil,
    scope: String? = nil, resourceMetadataURL: URL? = nil, httpClient: (any HTTPClient)? = nil
  ) {
    self.serverURL = serverURL
    self.authorizationCode = authorizationCode
    self.callbackState = callbackState
    self.callbackIssuer = callbackIssuer
    self.scope = scope
    self.resourceMetadataURL = resourceMetadataURL
    self.httpClient = httpClient
  }
}

/// Runs the MCP OAuth flow: refreshes tokens, completes an authorization
/// callback, or starts a new authorization (returning `.redirect`).
/// Retries once after invalidating rejected credentials. Mirrors upstream `auth`.
public func auth(_ provider: any OAuthClientProvider, _ options: OAuthOptions) async throws -> OAuthAuthResult {
  do {
    return try await authInternal(provider, options)
  } catch let error as MCPClientOAuthError where error.kind == .invalidClient || error.kind == .unauthorizedClient {
    if options.authorizationCode != nil { throw error }
    guard try await provider.isClientInformationDynamicallyRegistered() else { throw error }
    try await provider.invalidateCredentials(.all)
    return try await authInternal(provider, options)
  } catch let error as MCPClientOAuthError where error.kind == .invalidGrant {
    try await provider.invalidateCredentials(.tokens)
    return try await authInternal(provider, options)
  }
}

// swiftlint:disable:next function_body_length cyclomatic_complexity
private func authInternal(_ provider: any OAuthClientProvider, _ options: OAuthOptions) async throws -> OAuthAuthResult {
  let oauth = MCPOAuth(httpClient: options.httpClient)
  let serverURL = options.serverURL

  if let metadataURL = options.resourceMetadataURL, urlOrigin(metadataURL.absoluteString) != urlOrigin(serverURL) {
    throw MCPClientOAuthError(
      message:
        "OAuth protected resource metadata URL \(metadataURL.absoluteString) must have the same origin as the MCP server URL \(urlOrigin(serverURL) ?? serverURL)"
    )
  }

  var resourceMetadata: JSONObject?
  var authorizationServerURL: String?
  if let metadata = try? await oauth.discoverProtectedResourceMetadata(
    serverURL: serverURL, resourceMetadataURL: options.resourceMetadataURL?.absoluteString)
  {
    resourceMetadata = metadata
    authorizationServerURL = metadata["authorization_servers"]?.arrayValue?.first?.stringValue
  }

  var clientInformation: OAuthClientInformation?
  var callbackServerInformation: OAuthAuthorizationServerInformation?
  if options.authorizationCode != nil {
    clientInformation = try await provider.clientInformation()
    if let clientInformation {
      callbackServerInformation = try await storedServerInformation(provider: provider, clientInformation: clientInformation)
    }
  }

  let resolvedServerURL = authorizationServerURL ?? callbackServerInformation?.authorizationServerUrl ?? serverURL
  let serverHost = URLComponents(string: serverURL)?.host ?? ""
  let authorizationHost = URLComponents(string: resolvedServerURL)?.host ?? ""
  let trustedOrigin: String? =
    urlOrigin(resolvedServerURL) == urlOrigin(serverURL)
      || (isOAuthLoopbackHost(serverHost) && isOAuthLoopbackHost(authorizationHost))
    ? urlOrigin(resolvedServerURL) : nil
  if trustedOrigin == nil {
    do {
      try validateDownloadUrl(resolvedServerURL)
    } catch {
      throw MCPClientOAuthError(message: "OAuth endpoint URL is not allowed: \(resolvedServerURL)", cause: error)
    }
  }

  let resource = try await oauth.selectResourceURL(serverURL: serverURL, provider: provider, resourceMetadata: resourceMetadata)
  try await provider.validateAuthorizationServerURL(serverURL: serverURL, authorizationServerURL: resolvedServerURL)

  let metadata = try await oauth.discoverAuthorizationServerMetadata(resolvedServerURL, trustedOrigin: trustedOrigin)
  let currentInformation = serverInformation(resolvedServerURL, metadata)
  let clientMetadata = provider.clientMetadata
  let selectedScope =
    options.scope.flatMap { $0.isEmpty ? nil : $0 }
    ?? resourceMetadata?["scopes_supported"]?.arrayValue.map { $0.compactMap(\.stringValue).joined(separator: " ") }
      .flatMap { $0.isEmpty ? nil : $0 }
    ?? clientMetadata.scope

  if options.authorizationCode == nil {
    clientInformation = try await provider.clientInformation()
  }
  if let client = clientInformation, client.issuer != nil {
    var stored = callbackServerInformation
    if stored == nil { stored = try await storedServerInformation(provider: provider, clientInformation: client) }
    if let stored { try assertMatches(stored, currentInformation) }
  }

  if clientInformation == nil {
    if options.authorizationCode != nil {
      throw OAuthFlowError("Existing OAuth client information is required when exchanging an authorization code")
    }
    var registrationMetadata = clientMetadata
    registrationMetadata.scope = selectedScope
    let registered = pinned(
      try await oauth.registerClient(resolvedServerURL, metadata: metadata, clientMetadata: registrationMetadata),
      currentInformation)
    guard try await provider.saveClientInformation(registered) else {
      throw OAuthFlowError("OAuth client information must be saveable for dynamic registration")
    }
    clientInformation = registered
  }
  guard let client = clientInformation else { throw OAuthFlowError("OAuth client information is missing") }

  if let authorizationCode = options.authorizationCode {
    if let expectedState = try await provider.storedState(), expectedState != options.callbackState {
      throw OAuthFlowError("OAuth state parameter mismatch - possible CSRF attack")
    }
    let storedCandidate = try await storedServerInformation(provider: provider, clientInformation: client)
    guard let stored = callbackServerInformation ?? storedCandidate else {
      throw MCPClientOAuthError(
        message: "Stored OAuth authorization server metadata is required when exchanging an authorization code")
    }
    let expectedIssuer = stored.issuer ?? metadata?.issuer ?? resolvedServerURL
    if let callbackIssuer = options.callbackIssuer, callbackIssuer != expectedIssuer {
      throw MCPClientOAuthError(
        message: "OAuth authorization response issuer \(callbackIssuer) does not match expected issuer \(expectedIssuer)")
    }
    try assertMatches(stored, currentInformation)
    let tokens = try await oauth.exchangeAuthorization(
      resolvedServerURL, metadata: metadata, clientInformation: client, authorizationCode: authorizationCode,
      codeVerifier: try await provider.codeVerifier(), redirectURI: provider.redirectURL, resource: resource,
      provider: provider)
    try await provider.saveTokens(pinned(tokens, currentInformation))
    return .authorized
  }

  if let tokens = try await provider.tokens(), let refreshToken = tokens.refreshToken {
    let stored = try await storedServerInformation(provider: provider, clientInformation: client, tokens: tokens)
    if let stored {
      try assertMatches(stored, currentInformation)
    } else {
      try await provider.invalidateCredentials(.tokens)
    }
    do {
      if stored != nil {
        let refreshed = try await oauth.refreshAuthorization(
          resolvedServerURL, metadata: metadata, clientInformation: client, refreshToken: refreshToken, resource: resource,
          provider: provider)
        try await provider.saveTokens(pinned(refreshed, currentInformation))
        return .authorized
      }
    } catch let error as MCPClientOAuthError where error.kind != .serverError {
      throw error
    } catch {
      // Refresh failed with a server or transport error; fall through to a new authorization.
    }
  }

  let state = try await provider.state()
  if let state, !state.isEmpty { try await provider.saveState(state) }
  let (authorizationURL, codeVerifier) = try oauth.startAuthorization(
    resolvedServerURL, metadata: metadata, clientInformation: client, redirectURL: provider.redirectURL,
    scope: selectedScope, state: state, resource: resource)

  var saved = try await provider.saveAuthorizationServerInformation(currentInformation)
  if !saved { saved = try await provider.saveClientInformation(pinned(client, currentInformation)) }
  guard saved else {
    throw MCPClientOAuthError(message: "OAuth authorization server metadata must be saveable before starting authorization")
  }
  try await provider.saveCodeVerifier(codeVerifier)
  try await provider.redirectToAuthorization(authorizationURL)
  return .redirect
}
