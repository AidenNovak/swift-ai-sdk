import AISDKProviderUtils
import Foundation

/// Callbacks a transport reports to. Replaces upstream's mutable `onmessage`,
/// `onerror` and `onclose` properties; transports deliver messages in order.
public struct MCPTransportHandler: Sendable {
  public var onMessage: @Sendable (JSONRPCMessage) async -> Void
  public var onError: @Sendable (any Error) async -> Void
  public var onClose: @Sendable () async -> Void

  public init(
    onMessage: @escaping @Sendable (JSONRPCMessage) async -> Void,
    onError: @escaping @Sendable (any Error) async -> Void = { _ in },
    onClose: @escaping @Sendable () async -> Void = {}
  ) {
    self.onMessage = onMessage
    self.onError = onError
    self.onClose = onClose
  }
}

/// Per-message send options. Mirrors upstream `MCPTransportSendOptions`;
/// cancellation replaces `signal`.
public struct MCPTransportSendOptions: Sendable, Equatable {
  /// Extra HTTP headers, e.g. `Mcp-Param-*` tool argument headers.
  public var headers: [String: String]?

  public init(headers: [String: String]? = nil) {
    self.headers = headers
  }
}

/// A bidirectional JSON-RPC channel to an MCP server. Mirrors upstream `MCPTransport`.
public protocol MCPTransport: Sendable {
  /// Whether the client may probe with `server/discover` (stateless protocol).
  var supportsProtocolVersionDiscovery: Bool { get }
  /// Whether the transport can send `Mcp-Param-*` headers for tool arguments.
  var supportsMcpToolParameterHeaders: Bool { get }

  func start(_ handler: MCPTransportHandler) async throws
  func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws
  func close() async throws
  /// Called when the protocol version is negotiated.
  func setProtocolVersion(_ version: String) async
}

extension MCPTransport {
  public var supportsProtocolVersionDiscovery: Bool { false }
  public var supportsMcpToolParameterHeaders: Bool { false }
  public func setProtocolVersion(_ version: String) async {}

  public func send(_ message: JSONRPCMessage) async throws {
    try await send(message, options: MCPTransportSendOptions())
  }
}

/// Configuration for the built-in HTTP transports. Mirrors upstream `MCPTransportConfig`.
public struct MCPTransportConfig: Sendable {
  public enum Kind: String, Sendable {
    /// Streamable HTTP.
    case http
    /// The deprecated HTTP+SSE transport.
    case sse
  }

  public var type: Kind
  public var url: String
  public var headers: [String: String]?
  /// Adds bearer tokens and runs the OAuth flow on 401 responses.
  public var authProvider: (any OAuthClientProvider)?
  /// Resumes an existing session (legacy protocol, Streamable HTTP only).
  public var initialSessionId: String?
  public var initialProtocolVersion: String?
  public var onSessionIdChange: (@Sendable (String?) -> Void)?
  public var onSessionExpired: (@Sendable (String) -> Void)?
  /// Sends `DELETE` to end the session on close. Defaults to true.
  public var terminateSessionOnClose: Bool
  public var httpClient: (any HTTPClient)?

  public init(
    type: Kind, url: String, headers: [String: String]? = nil, authProvider: (any OAuthClientProvider)? = nil,
    initialSessionId: String? = nil, initialProtocolVersion: String? = nil,
    onSessionIdChange: (@Sendable (String?) -> Void)? = nil, onSessionExpired: (@Sendable (String) -> Void)? = nil,
    terminateSessionOnClose: Bool = true, httpClient: (any HTTPClient)? = nil
  ) {
    self.type = type
    self.url = url
    self.headers = headers
    self.authProvider = authProvider
    self.initialSessionId = initialSessionId
    self.initialProtocolVersion = initialProtocolVersion
    self.onSessionIdChange = onSessionIdChange
    self.onSessionExpired = onSessionExpired
    self.terminateSessionOnClose = terminateSessionOnClose
    self.httpClient = httpClient
  }
}

/// Creates a built-in transport. Mirrors upstream `createMcpTransport`.
public func createMCPTransport(_ config: MCPTransportConfig) throws -> any MCPTransport {
  switch config.type {
  case .sse:
    return try MCPSSETransport(config)
  case .http:
    var config = config
    config.initialProtocolVersion = config.initialProtocolVersion ?? MCP_LATEST_PROTOCOL_VERSION
    return try MCPHTTPTransport(config)
  }
}

let mcpUserAgentSuffix = "ai-sdk/\(AISDK_VERSION)"
let mcpRuntimeUserAgent = "runtime/swift"

func isMessageEvent(_ event: String?) -> Bool {
  event == nil || event == "message"
}
