import AISDKProviderUtils
import Foundation

/// The MCP Streamable HTTP transport: POSTs messages and reads JSON or SSE
/// responses; legacy protocol versions also keep an inbound SSE stream (GET)
/// with resumption. Mirrors upstream `HttpMCPTransport`.
public actor MCPHTTPTransport: MCPTransport {
  public nonisolated let supportsProtocolVersionDiscovery = true
  public nonisolated let supportsMcpToolParameterHeaders = true

  private let url: URL
  private let headers: [String: String]?
  private let authProvider: (any OAuthClientProvider)?
  private let httpClient: any HTTPClient
  private let onSessionIdChange: (@Sendable (String?) -> Void)?
  private let onSessionExpired: (@Sendable (String) -> Void)?
  private let terminateSessionOnClose: Bool

  private var handler: MCPTransportHandler?
  private var started = false
  private var closed = false
  private var sessionId: String?
  private(set) var protocolVersion: String
  private var resourceMetadataURL: URL?
  private var authTask: Task<OAuthAuthResult, any Error>?
  private var inboundTask: Task<Void, Never>?
  private var responseTasks: [UUID: Task<Void, Never>] = [:]
  private var lastInboundEventId: String?
  private var inboundReconnectAttempts = 0

  private let initialReconnectionDelay = 1000.0
  private let maxReconnectionDelay = 30000.0
  private let reconnectionDelayGrowFactor = 1.5
  private let maxRetries = 2

  public init(_ config: MCPTransportConfig) throws {
    guard let url = URL(string: config.url), url.scheme != nil else {
      throw MCPClientError(message: "Invalid MCP server URL: \(config.url)")
    }
    self.url = url
    self.headers = config.headers
    self.authProvider = config.authProvider
    self.httpClient = config.httpClient ?? defaultHTTPClient
    self.sessionId = config.initialSessionId
    self.protocolVersion = config.initialProtocolVersion ?? MCP_LATEST_LEGACY_PROTOCOL_VERSION
    self.onSessionIdChange = config.onSessionIdChange
    self.onSessionExpired = config.onSessionExpired
    self.terminateSessionOnClose = config.terminateSessionOnClose
  }

  /// The current session ID (legacy protocol).
  public var currentSessionId: String? { sessionId }

  private var isModernProtocol: Bool { protocolVersion == MCP_LATEST_PROTOCOL_VERSION }

  public func setProtocolVersion(_ version: String) async {
    protocolVersion = version
    guard started else { return }
    if isModernProtocol {
      inboundTask?.cancel()
      inboundTask = nil
    } else if inboundTask == nil {
      startInboundSse()
    }
  }

  private func commonHeaders(_ base: [String: String], includeSessionId: Bool = true) async throws -> [String: String] {
    var result = headers ?? [:]
    for (name, value) in base { result[name] = value }
    result["mcp-protocol-version"] = protocolVersion
    if !isModernProtocol, includeSessionId, let sessionId { result["mcp-session-id"] = sessionId }
    if let token = try await authProvider?.tokens()?.accessToken, !token.isEmpty {
      result["Authorization"] = "Bearer \(token)"
    }
    return withUserAgentSuffix(result, mcpUserAgentSuffix, mcpRuntimeUserAgent)
  }

  private func setSessionId(_ id: String?) {
    guard sessionId != id else { return }
    sessionId = id
    onSessionIdChange?(id)
  }

  private func applySessionId(from response: HTTPResponse) {
    guard !isModernProtocol, let id = response.headers["mcp-session-id"], !id.isEmpty else { return }
    setSessionId(id)
  }

  private func expireSession(_ id: String) {
    if sessionId == id { setSessionId(nil) }
    onSessionExpired?(id)
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

  private func report(_ error: any Error) async {
    await handler?.onError(error)
  }

  public func start(_ handler: MCPTransportHandler) async throws {
    guard !started else {
      throw MCPClientError(
        message:
          "MCP HTTP Transport Error: Transport already started. Note: client.connect() calls start() automatically.")
    }
    self.handler = handler
    started = true
    if !isModernProtocol { startInboundSse() }
  }

  public func close() async throws {
    inboundTask?.cancel()
    inboundTask = nil
    for task in responseTasks.values { task.cancel() }
    responseTasks.removeAll()
    let wasStarted = started && !closed
    closed = true
    if !isModernProtocol, let sessionId, terminateSessionOnClose, wasStarted {
      if let headers = try? await commonHeaders([:]) {
        _ = try? await httpClient.send(HTTPRequest(method: "DELETE", url: url, headers: headers))
      }
      _ = sessionId
    }
    await handler?.onClose()
  }

  private func standardRequestHeaders(method: String, params: JSONObject?) -> [String: String] {
    var result = ["Mcp-Method": method]
    let name: JSONValue? =
      switch method {
      case "resources/read": params?["uri"]
      case "tools/call", "prompts/get": params?["name"]
      default: nil
      }
    if let name = name?.stringValue { result["Mcp-Name"] = encodeMCPHeaderValue(name) }
    return result
  }

  public func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws {
    try Task.checkCancellation()
    do {
      try await attemptSend(message, options: options, triedAuth: false)
    } catch {
      if !(error is CancellationError) { await report(error) }
      throw error
    }
  }

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private func attemptSend(_ message: JSONRPCMessage, options: MCPTransportSendOptions, triedAuth: Bool) async throws {
    var isInitialize = false
    var base = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
    if case .request(_, let method, let params) = message {
      isInitialize = method == "initialize"
      if isModernProtocol {
        for (name, value) in options.headers ?? [:] { base[name] = value }
        for (name, value) in standardRequestHeaders(method: method, params: params) { base[name] = value }
      }
    } else if isModernProtocol {
      for (name, value) in options.headers ?? [:] { base[name] = value }
    }
    let sessionIdForRequest = isInitialize ? nil : sessionId
    let requestHeaders = try await commonHeaders(base, includeSessionId: !isInitialize)
    let response = try await httpClient.send(
      HTTPRequest(
        method: "POST", url: url, headers: requestHeaders, body: try message.json.jsonData(sortedKeys: false),
        redirect: .error))
    applySessionId(from: response)

    if response.statusCode == 401, authProvider != nil, !triedAuth {
      let (metadataURL, scope) = extractWWWAuthenticateParams(response.headers)
      resourceMetadataURL = metadataURL
      guard try await authorizeOnce(scope: scope) == .authorized else { throw UnauthorizedError() }
      return try await attemptSend(message, options: options, triedAuth: true)
    }

    if response.statusCode == 202 {
      if !isModernProtocol, inboundTask == nil { startInboundSse() }
      return
    }

    let isNotification: Bool =
      if case .notification = message { true } else { false }
    let messageId = message.id

    guard response.isOK else {
      let text = try? await response.bodyText()
      if let messageId, !isNotification, let text,
        case .error(let id, let error)? = try? parseJSONRPCMessage(text)
      {
        await handler?.onMessage(.error(id: id ?? messageId, error: error))
        return
      }
      var errorMessage =
        "MCP HTTP Transport Error: POSTing to endpoint (HTTP \(response.statusCode)): \(text ?? "null")"
      if response.statusCode == 404 {
        if !isModernProtocol, let sessionIdForRequest {
          expireSession(sessionIdForRequest)
          errorMessage +=
            ". The MCP session expired. Create a new client without `initialSessionId` to start a fresh session"
        } else if !isModernProtocol {
          errorMessage += ". This server does not support HTTP transport. Try using `sse` transport instead"
        }
      }
      throw MCPClientError(
        message: errorMessage, statusCode: response.statusCode, url: url.absoluteString, responseBody: text)
    }

    if isNotification { return }

    let contentType = response.headers["content-type"] ?? ""
    if contentType.contains("application/json") {
      let data = try JSONValue(jsonData: try await response.bodyData())
      let messages = try (data.arrayValue ?? [data]).map(validateJSONRPCMessage)
      for message in messages { await handler?.onMessage(message) }
      return
    }

    if contentType.contains("text/event-stream") {
      let events = parseEventStream(response.body)
      let taskId = UUID()
      let task = Task { [weak self] in
        do {
          for try await event in events where isMessageEvent(event.event) {
            do {
              await self?.deliver(try parseJSONRPCMessage(event.data))
            } catch {
              await self?.report(
                MCPClientError(message: "MCP HTTP Transport Error: Failed to parse message", cause: error))
            }
          }
        } catch where !isCancellationError(error) {
          await self?.report(error)
        } catch {}
        await self?.finishResponseTask(taskId)
      }
      responseTasks[taskId] = task
      return
    }

    throw MCPClientError(
      message: "MCP HTTP Transport Error: Unexpected content type: \(contentType)", statusCode: response.statusCode,
      url: url.absoluteString)
  }

  private func deliver(_ message: JSONRPCMessage) async {
    await handler?.onMessage(message)
  }

  private func finishResponseTask(_ id: UUID) {
    responseTasks[id] = nil
  }

  private func startInboundSse(triedAuth: Bool = false, resumeToken: String? = nil) {
    guard !isModernProtocol, !closed else { return }
    inboundTask = Task { [weak self] in
      await self?.openInboundSse(triedAuth: triedAuth, resumeToken: resumeToken)
    }
  }

  private func scheduleInboundReconnection() async {
    if maxRetries > 0, inboundReconnectAttempts >= maxRetries {
      await report(
        MCPClientError(message: "MCP HTTP Transport Error: Maximum reconnection attempts (\(maxRetries)) exceeded."))
      return
    }
    let delayMs = min(
      initialReconnectionDelay * pow(reconnectionDelayGrowFactor, Double(inboundReconnectAttempts)), maxReconnectionDelay)
    inboundReconnectAttempts += 1
    let resumeToken = lastInboundEventId
    inboundTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
      guard !Task.isCancelled else { return }
      await self?.openInboundSse(triedAuth: false, resumeToken: resumeToken)
    }
  }

  private func openInboundSse(triedAuth: Bool, resumeToken: String?) async {
    guard !isModernProtocol, !closed else { return }
    do {
      let sessionIdForRequest = sessionId
      var requestHeaders = try await commonHeaders(["Accept": "text/event-stream"])
      if let resumeToken { requestHeaders["last-event-id"] = resumeToken }
      let response = try await httpClient.send(HTTPRequest(method: "GET", url: url, headers: requestHeaders, redirect: .error))
      applySessionId(from: response)

      if response.statusCode == 401, authProvider != nil, !triedAuth {
        let (metadataURL, scope) = extractWWWAuthenticateParams(response.headers)
        resourceMetadataURL = metadataURL
        do {
          guard try await authorizeOnce(scope: scope) == .authorized else {
            await report(UnauthorizedError())
            return
          }
        } catch {
          await report(error)
          return
        }
        return await openInboundSse(triedAuth: true, resumeToken: resumeToken)
      }
      if response.statusCode == 405 { return }
      guard response.isOK else {
        if response.statusCode == 404, let sessionIdForRequest { expireSession(sessionIdForRequest) }
        await report(
          MCPClientError(
            message: "MCP HTTP Transport Error: GET SSE failed: \(response.statusCode) \(response.statusText)",
            statusCode: response.statusCode, url: url.absoluteString))
        return
      }

      inboundReconnectAttempts = 0
      do {
        for try await event in parseEventStream(response.body) {
          if let id = event.id, !id.isEmpty { lastInboundEventId = id }
          guard isMessageEvent(event.event) else { continue }
          do {
            await deliver(try parseJSONRPCMessage(event.data))
          } catch {
            await report(MCPClientError(message: "MCP HTTP Transport Error: Failed to parse message", cause: error))
          }
        }
      } catch where !isCancellationError(error) {
        await report(error)
        if !closed { await scheduleInboundReconnection() }
      }
    } catch where !isCancellationError(error) {
      await report(error)
      if !closed { await scheduleInboundReconnection() }
    } catch {}
  }
}
