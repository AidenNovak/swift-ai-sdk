import AISDKProviderUtils
import Foundation

/// The deprecated HTTP+SSE transport: an SSE stream announces a POST
/// endpoint, and responses arrive on the stream. Mirrors upstream `SseMCPTransport`.
public actor MCPSSETransport: MCPTransport {
  private let url: URL
  private let headers: [String: String]?
  private let authProvider: (any OAuthClientProvider)?
  private let httpClient: any HTTPClient

  private var handler: MCPTransportHandler?
  private var endpoint: URL?
  private var connected = false
  private var protocolVersion: String?
  private var resourceMetadataURL: URL?
  private var authTask: Task<OAuthAuthResult, any Error>?
  private var streamTask: Task<Void, Never>?
  private var startContinuation: CheckedContinuation<Void, any Error>?

  public init(_ config: MCPTransportConfig) throws {
    guard let url = URL(string: config.url), url.scheme != nil else {
      throw MCPClientError(message: "Invalid MCP server URL: \(config.url)")
    }
    self.url = url
    self.headers = config.headers
    self.authProvider = config.authProvider
    self.httpClient = config.httpClient ?? defaultHTTPClient
  }

  public func setProtocolVersion(_ version: String) async {
    protocolVersion = version
  }

  private func commonHeaders(_ base: [String: String]) async throws -> [String: String] {
    var result = headers ?? [:]
    for (name, value) in base { result[name] = value }
    result["mcp-protocol-version"] = protocolVersion ?? MCP_LATEST_LEGACY_PROTOCOL_VERSION
    if let token = try await authProvider?.tokens()?.accessToken, !token.isEmpty {
      result["Authorization"] = "Bearer \(token)"
    }
    return withUserAgentSuffix(result, mcpUserAgentSuffix, mcpRuntimeUserAgent)
  }

  private func authorizeOnce(scope: String?) async throws -> OAuthAuthResult {
    guard let authProvider else { return .redirect }
    if let authTask { return try await authTask.value }
    let options = OAuthOptions(
      serverURL: url.absoluteString, scope: scope, resourceMetadataURL: resourceMetadataURL, httpClient: httpClient)
    let task = Task { try await auth(authProvider, options) }
    authTask = task
    defer { authTask = nil }
    return try await task.value
  }

  private func accessTokenChanged(_ requestAuthorization: String?) async throws -> Bool {
    guard let token = try await authProvider?.tokens()?.accessToken else { return false }
    return requestAuthorization != "Bearer \(token)"
  }

  private func resumeStart(_ result: Result<Void, any Error>) {
    startContinuation?.resume(with: result)
    startContinuation = nil
  }

  public func start(_ handler: MCPTransportHandler) async throws {
    if connected { return }
    self.handler = handler
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      startContinuation = continuation
      streamTask = Task { [weak self] in await self?.establishConnection(triedAuth: false) }
    }
  }

  private func fail(_ error: any Error) async {
    await handler?.onError(error)
    resumeStart(.failure(error))
  }

  // swiftlint:disable:next function_body_length
  private func establishConnection(triedAuth: Bool) async {
    do {
      let requestHeaders = try await commonHeaders(["Accept": "text/event-stream"])
      let response = try await httpClient.send(HTTPRequest(method: "GET", url: url, headers: requestHeaders, redirect: .error))

      if response.statusCode == 401, authProvider != nil, !triedAuth {
        let (metadataURL, scope) = extractWWWAuthenticateParams(response.headers)
        resourceMetadataURL = metadataURL
        do {
          guard try await authorizeOnce(scope: scope) == .authorized else { return await fail(UnauthorizedError()) }
        } catch {
          return await fail(error)
        }
        return await establishConnection(triedAuth: true)
      }

      guard response.isOK else {
        var message = "MCP SSE Transport Error: \(response.statusCode) \(response.statusText)"
        if response.statusCode == 405 {
          message += ". This server does not support SSE transport. Try using `http` transport instead"
        }
        return await fail(MCPClientError(message: message))
      }

      for try await event in parseEventStream(response.body) {
        if event.event == "endpoint" {
          if endpoint != nil { continue }
          guard let resolved = URL(string: event.data, relativeTo: url)?.absoluteURL else { continue }
          guard urlOrigin(resolved.absoluteString) == urlOrigin(url.absoluteString) else {
            connected = false
            endpoint = nil
            return await fail(
              MCPClientError(
                message:
                  "MCP SSE Transport Error: Endpoint origin does not match connection origin: \(urlOrigin(resolved.absoluteString) ?? resolved.absoluteString)"
              ))
          }
          endpoint = resolved
          connected = true
          resumeStart(.success(()))
        } else if isMessageEvent(event.event) {
          do {
            await handler?.onMessage(try parseJSONRPCMessage(event.data))
          } catch {
            await handler?.onError(
              MCPClientError(message: "MCP SSE Transport Error: Failed to parse message", cause: error))
          }
        }
      }
      if connected {
        connected = false
        await fail(MCPClientError(message: "MCP SSE Transport Error: Connection closed unexpectedly"))
      } else {
        resumeStart(.failure(MCPClientError(message: "MCP SSE Transport Error: Connection closed unexpectedly")))
      }
    } catch where isCancellationError(error) {
      resumeStart(.failure(error))
    } catch {
      await fail(error)
    }
  }

  public func close() async throws {
    connected = false
    endpoint = nil
    streamTask?.cancel()
    streamTask = nil
    resumeStart(.failure(CancellationError()))
    await handler?.onClose()
  }

  public func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws {
    try Task.checkCancellation()
    guard let endpoint, connected else { throw MCPClientError(message: "MCP SSE Transport Error: Not connected") }
    do {
      try await attemptSend(message, endpoint: endpoint, triedAuth: false)
    } catch {
      if !isCancellationError(error) { await handler?.onError(error) }
      throw error
    }
  }

  private func attemptSend(_ message: JSONRPCMessage, endpoint: URL, triedAuth: Bool) async throws {
    let requestHeaders = try await commonHeaders(["Content-Type": "application/json"])
    let response = try await httpClient.send(
      HTTPRequest(
        method: "POST", url: endpoint, headers: requestHeaders, body: try message.json.jsonData(sortedKeys: false),
        redirect: .error))

    if response.statusCode == 401, authProvider != nil, !triedAuth {
      if try await accessTokenChanged(requestHeaders["authorization"]) {
        return try await attemptSend(message, endpoint: endpoint, triedAuth: true)
      }
      let (metadataURL, scope) = extractWWWAuthenticateParams(response.headers)
      resourceMetadataURL = metadataURL
      guard try await authorizeOnce(scope: scope) == .authorized else { throw UnauthorizedError() }
      return try await attemptSend(message, endpoint: endpoint, triedAuth: true)
    }

    guard response.isOK else {
      let text = try? await response.bodyText()
      throw MCPClientError(
        message: "MCP SSE Transport Error: POSTing to endpoint (HTTP \(response.statusCode)): \(text ?? "null")",
        statusCode: response.statusCode, url: endpoint.absoluteString, responseBody: text)
    }
  }
}
