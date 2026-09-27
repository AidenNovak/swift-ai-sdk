@_exported import AISDKProviderUtils
import Foundation

private let defaultProtocolDiscoveryTimeout = Duration.milliseconds(1000)
private let modernProtocolErrorCodes: Set<Int> = [-32020, -32021, -32022]
private let defaultRetryErrorCodes: Set<String> = [
  "ConnectionRefused", "ConnectionClosed", "FailedToOpenSocket", "ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EPIPE",
]

/// Explicit schemas for `MCPClient.tools(schemas:)`. Mirrors upstream `ToolSchemas`.
public struct MCPToolSchema: Sendable {
  public var inputSchema: Schema<JSONValue>
  /// When set, results are validated `structuredContent` (or parsed text).
  public var outputSchema: Schema<JSONValue>?

  public init(inputSchema: Schema<JSONValue>, outputSchema: Schema<JSONValue>? = nil) {
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
  }
}

/// Configuration for `createMCPClient`. Mirrors upstream `MCPClientConfig`.
public struct MCPClientConfig: Sendable {
  public var transport: any MCPTransport
  /// Probe stateless servers with `server/discover` before `initialize`. Defaults to true.
  public var protocolVersionDiscovery: Bool
  /// Bounds transport startup and initialization.
  public var initializationOptions: MCPRequestOptions?
  public var onUncaughtError: (@Sendable (any Error) -> Void)?
  /// Retries for transient `tools/call` failures. Defaults to 0.
  public var maxRetries: Int
  /// Reuses a previous session's initialize result instead of initializing.
  public var initialInitializeResult: MCPInitializeResult?
  public var clientName: String
  public var version: String
  /// Capabilities advertised to the server, e.g. `elicitation` or `mcpAppClientCapabilities`.
  public var capabilities: JSONObject

  public init(
    transport: any MCPTransport, protocolVersionDiscovery: Bool = true, initializationOptions: MCPRequestOptions? = nil,
    onUncaughtError: (@Sendable (any Error) -> Void)? = nil, maxRetries: Int = 0,
    initialInitializeResult: MCPInitializeResult? = nil, clientName: String = "ai-sdk-mcp-client",
    version: String = "1.0.0", capabilities: JSONObject = [:]
  ) {
    self.transport = transport
    self.protocolVersionDiscovery = protocolVersionDiscovery
    self.initializationOptions = initializationOptions
    self.onUncaughtError = onUncaughtError
    self.maxRetries = maxRetries
    self.initialInitializeResult = initialInitializeResult
    self.clientName = clientName
    self.version = version
    self.capabilities = capabilities
  }

  /// Uses a built-in HTTP or SSE transport.
  public init(
    transport config: MCPTransportConfig, protocolVersionDiscovery: Bool = true,
    initializationOptions: MCPRequestOptions? = nil, onUncaughtError: (@Sendable (any Error) -> Void)? = nil,
    maxRetries: Int = 0, initialInitializeResult: MCPInitializeResult? = nil, clientName: String = "ai-sdk-mcp-client",
    version: String = "1.0.0", capabilities: JSONObject = [:]
  ) throws {
    self.init(
      transport: try createMCPTransport(config), protocolVersionDiscovery: protocolVersionDiscovery,
      initializationOptions: initializationOptions, onUncaughtError: onUncaughtError, maxRetries: maxRetries,
      initialInitializeResult: initialInitializeResult, clientName: clientName, version: version,
      capabilities: capabilities)
  }
}

/// Connects to an MCP server and initializes the session. Mirrors upstream `createMCPClient`.
public func createMCPClient(_ config: MCPClientConfig) async throws -> MCPClient {
  let client = try MCPClient(config)
  try await client.initialize()
  return client
}

/// Converts an MCP tool result into model output. Mirrors upstream `mcpToModelOutput`.
func mcpToModelOutput(_ output: JSONValue) -> ToolResultOutput {
  guard case .array(let content)? = output["content"] else { return .json(output) }
  return .content(
    content.map { part in
      if part["type"] == "text", let text = part["text"]?.stringValue { return .text(text) }
      if part["type"] == "image", let data = part["data"]?.stringValue, let mimeType = part["mimeType"]?.stringValue {
        return .file(data: .base64(data), mediaType: mimeType)
      }
      return .text(part.jsonString(sortedKeys: false))
    })
}

private func isRetryableToolCallError(_ error: any Error) -> Bool {
  if let status = (error as? MCPClientError)?.statusCode ?? (error as? APICallError)?.statusCode {
    return status == 408 || status == 409 || status == 429 || status >= 500
  }
  if let mcpError = error as? MCPClientError, mcpError.code != nil { return false }
  if let urlError = error as? URLError {
    return [.cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(urlError.code)
  }
  let nsError = error as NSError
  return defaultRetryErrorCodes.contains(nsError.localizedDescription)
}

private extension Duration {
  var milliseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1000 + attoseconds / 1_000_000_000_000_000
  }
}

/// A lightweight MCP client: converts server tools into SDK tools and exposes
/// resources, prompts, completions and elicitation. Use one client per server.
/// Mirrors upstream `MCPClient`.
public actor MCPClient {
  private enum ProtocolEra {
    case legacy, modern
  }

  private let transport: any MCPTransport
  private let protocolVersionDiscovery: Bool
  private let onUncaughtError: (@Sendable (any Error) -> Void)?
  private let maxRetries: Int
  private let clientInfo: MCPImplementation
  private let clientCapabilities: JSONObject
  private let initialInitializeResult: MCPInitializeResult?
  private let initializationOptions: MCPRequestOptions?

  private var nextMessageId = 0
  private var pending: [Int: CheckedContinuation<JSONObject, any Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  private var serverCapabilities: JSONObject = [:]
  private var protocolEra = ProtocolEra.legacy
  private var protocolVersion = MCP_LATEST_LEGACY_PROTOCOL_VERSION
  private var toolHeaderBindings: [String: [MCPToolHeaderBinding]] = [:]
  private var isClosed = true
  private var elicitationHandler: (@Sendable (MCPElicitationRequest) async throws -> MCPElicitResult)?

  /// The server implementation reported during initialization.
  public private(set) var serverInfo = MCPImplementation(name: "", version: "")
  /// The initialize result used by this client.
  public private(set) var initializeResult: MCPInitializeResult
  /// Server usage instructions, e.g. for the system prompt.
  public private(set) var instructions: String?

  init(_ config: MCPClientConfig) throws {
    guard config.maxRetries >= 0 else { throw MCPClientError(message: "maxRetries must be >= 0") }
    transport = config.transport
    protocolVersionDiscovery = config.protocolVersionDiscovery
    onUncaughtError = config.onUncaughtError
    maxRetries = config.maxRetries
    clientInfo = MCPImplementation(name: config.clientName, version: config.version)
    clientCapabilities = config.capabilities
    initialInitializeResult = config.initialInitializeResult
    initializationOptions = config.initializationOptions
    initializeResult = MCPInitializeResult(
      protocolVersion: MCP_LATEST_LEGACY_PROTOCOL_VERSION, capabilities: [:], serverInfo: MCPImplementation(name: "", version: ""))
  }

  private var handler: MCPTransportHandler {
    MCPTransportHandler(
      onMessage: { [weak self] message in await self?.onMessage(message) },
      onError: { [weak self] error in await self?.onError(error) },
      onClose: { [weak self] in await self?.onClose() })
  }

  func initialize() async throws {
    let timeout = initializationOptions?.effectiveTimeout
    do {
      if let timeout {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await self.initializeSession() }
          group.addTask {
            try await Task.sleep(for: timeout)
            throw MCPClientError(message: "MCP client initialization timed out after \(timeout.milliseconds)ms")
          }
          try await group.next()
          group.cancelAll()
        }
      } else {
        try await initializeSession()
      }
    } catch {
      try? await transport.close()
      onClose()
      if isCancellationError(error) {
        throw MCPClientError(message: "MCP client initialization was aborted", cause: error)
      }
      throw error
    }
  }

  private func initializeSession() async throws {
    isClosed = false
    try Task.checkCancellation()
    try await transport.start(handler)

    if let initialInitializeResult {
      try applyInitializeResult(initialInitializeResult)
      return
    }
    if protocolVersionDiscovery, transport.supportsProtocolVersionDiscovery, try await tryProtocolDiscovery() {
      return
    }

    protocolEra = .legacy
    protocolVersion = MCP_LATEST_LEGACY_PROTOCOL_VERSION
    await transport.setProtocolVersion(protocolVersion)
    let result = try await request(
      method: "initialize",
      params: [
        "protocolVersion": .string(MCP_LATEST_LEGACY_PROTOCOL_VERSION), "capabilities": .object(clientCapabilities),
        "clientInfo": .object(clientInfo.raw),
      ])
    try applyInitializeResult(try MCPInitializeResult(json: result))
    try await transport.send(.notification(method: "notifications/initialized"))
  }

  private func tryProtocolDiscovery() async throws -> Bool {
    protocolEra = .modern
    protocolVersion = MCP_LATEST_PROTOCOL_VERSION
    await transport.setProtocolVersion(protocolVersion)
    do {
      let result = try await request(
        method: "server/discover", options: MCPRequestOptions(timeout: defaultProtocolDiscoveryTimeout))
      try applyDiscoverResult(result)
      return true
    } catch let error as MCPClientError where error.code.map(modernProtocolErrorCodes.contains) == true {
      throw error
    } catch {
      return false
    }
  }

  private func applyDiscoverResult(_ result: JSONObject) throws {
    guard case .array(let versions)? = result["supportedVersions"], case .object(let capabilities)? = result["capabilities"]
    else {
      throw MCPClientError(message: "Failed to parse server response", cause: MCPClientError(message: "invalid discover result"))
    }
    guard versions.contains(.string(protocolVersion)) else {
      throw MCPClientError(message: "Server does not support the requested protocol version: \(protocolVersion)")
    }
    if case .object(let info)? = result["_meta"]?["io.modelcontextprotocol/serverInfo"],
      let implementation = try? MCPImplementation(json: info)
    {
      serverInfo = implementation
    }
    serverCapabilities = capabilities
    instructions = result["instructions"]?.stringValue
    initializeResult = MCPInitializeResult(
      protocolVersion: protocolVersion, capabilities: capabilities, serverInfo: serverInfo, instructions: instructions)
  }

  private func applyInitializeResult(_ result: MCPInitializeResult) throws {
    guard MCP_SUPPORTED_PROTOCOL_VERSIONS.contains(result.protocolVersion) else {
      throw MCPClientError(message: "Server's protocol version is not supported: \(result.protocolVersion)")
    }
    serverCapabilities = result.capabilities
    protocolEra = .legacy
    protocolVersion = result.protocolVersion
    serverInfo = result.serverInfo
    initializeResult = result
    instructions = result.instructions
    Task { [transport, protocolVersion] in await transport.setProtocolVersion(protocolVersion) }
  }

  /// Closes the transport; pending requests fail with "Connection closed".
  public func close() async throws {
    if isClosed { return }
    try await transport.close()
    onClose()
  }

  private func assertCapability(_ method: String) throws {
    switch method {
    case "initialize", "server/discover":
      return
    case "completion/complete":
      if serverCapabilities["completions"] == nil { throw MCPClientError(message: "Server does not support completions") }
    case "tools/list", "tools/call":
      if serverCapabilities["tools"] == nil { throw MCPClientError(message: "Server does not support tools") }
    case "resources/list", "resources/read", "resources/templates/list":
      if serverCapabilities["resources"] == nil { throw MCPClientError(message: "Server does not support resources") }
    case "prompts/list", "prompts/get":
      if serverCapabilities["prompts"] == nil { throw MCPClientError(message: "Server does not support prompts") }
    default:
      throw MCPClientError(message: "Unsupported method: \(method)")
    }
  }

  private func request(method: String, params: JSONObject? = nil, options: MCPRequestOptions? = nil) async throws
    -> JSONObject
  {
    guard !isClosed else { throw MCPClientError(message: "Attempted to send a request from a closed client") }
    try assertCapability(method)
    try Task.checkCancellation()

    let messageId = nextMessageId
    nextMessageId += 1
    var preparedParams = params
    if protocolEra == .modern {
      var object = params ?? [:]
      var meta = object["_meta"]?.objectValue ?? [:]
      meta["io.modelcontextprotocol/protocolVersion"] = .string(protocolVersion)
      meta["io.modelcontextprotocol/clientCapabilities"] = .object(clientCapabilities)
      meta["io.modelcontextprotocol/clientInfo"] = .object(clientInfo.raw)
      object["_meta"] = .object(meta)
      preparedParams = object
    }
    let headers = try toolRequestHeaders(method: method, params: preparedParams)
    let message = JSONRPCMessage.request(id: .int(messageId), method: method, params: preparedParams)
    let timeout = options?.effectiveTimeout

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[messageId] = continuation
        if let timeout {
          timeouts[messageId] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(messageId, MCPClientError(message: "Request timed out after \(timeout.milliseconds)ms"))
          }
        }
        let transport = transport
        Task { [weak self] in
          do {
            try await transport.send(message, options: MCPTransportSendOptions(headers: headers))
          } catch {
            await self?.fail(messageId, error)
          }
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.fail(messageId, MCPClientError(message: "Request was aborted", cause: CancellationError()))
      }
    }
  }

  private func takePending(_ id: Int) -> CheckedContinuation<JSONObject, any Error>? {
    timeouts.removeValue(forKey: id)?.cancel()
    return pending.removeValue(forKey: id)
  }

  private func fail(_ id: Int, _ error: any Error) {
    takePending(id)?.resume(throwing: error)
  }

  private func parse<T>(_ result: JSONObject, _ parser: (JSONObject) throws -> T) throws -> T {
    do {
      return try parser(result)
    } catch let error as MCPClientError {
      throw error
    } catch {
      throw MCPClientError(message: "Failed to parse server response", cause: error)
    }
  }

  // MARK: Tools

  /// Lists tools. Mirrors upstream `listTools`.
  public func listTools(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListToolsResult {
    let result = try await request(
      method: "tools/list", params: cursor.map { ["cursor": .string($0)] }, options: options)
    return prepareToolDefinitions(try parse(result, MCPListToolsResult.init(json:)), resetHeaderBindings: cursor == nil)
  }

  private func prepareToolDefinitions(_ definitions: MCPListToolsResult, resetHeaderBindings: Bool = false)
    -> MCPListToolsResult
  {
    guard protocolEra == .modern, transport.supportsMcpToolParameterHeaders else { return definitions }
    if resetHeaderBindings { toolHeaderBindings.removeAll() }
    var result = definitions
    result.tools = definitions.tools.filter { definition in
      switch getMCPToolHeaderBindings(.object(definition.inputSchema)) {
      case .success(let bindings):
        toolHeaderBindings[definition.name] = bindings
        return true
      case .failure(let error):
        onError(MCPClientError(message: "Ignoring MCP tool \"\(definition.name)\": \(error.message)"))
        return false
      }
    }
    return result
  }

  private func toolRequestHeaders(method: String, params: JSONObject?) throws -> [String: String]? {
    guard protocolEra == .modern, method == "tools/call", let name = params?["name"]?.stringValue,
      let bindings = toolHeaderBindings[name], !bindings.isEmpty, case .object(let args)? = params?["arguments"]
    else { return nil }
    do {
      return try createMCPToolHeaders(bindings: bindings, args: args)
    } catch {
      throw MCPClientError(message: "Failed to create MCP headers for tool \"\(name)\"", cause: error)
    }
  }

  /// Calls a tool. Transient failures are retried up to `maxRetries`. Mirrors upstream `callTool`.
  public func callTool(name: String, arguments: JSONObject = [:], options: MCPRequestOptions? = nil) async throws
    -> MCPCallToolResult
  {
    let execute: @Sendable () async throws -> MCPCallToolResult = {
      let result = try await self.request(
        method: "tools/call", params: ["name": .string(name), "arguments": .object(arguments)], options: options)
      return try await self.parse(result, MCPCallToolResult.init(json:))
    }
    guard maxRetries > 0 else { return try await execute() }
    return try await RetryWithExponentialBackoff(
      maxRetries: maxRetries, shouldRetry: { isRetryableToolCallError($0) },
      createRetryError: { message, _, errors in MCPClientError(message: message, cause: errors.last) }
    )(execute)
  }

  /// Fetches all tools (following pagination) as SDK tools. Mirrors upstream `tools`.
  ///
  /// - Parameter schemas: `nil` exposes every tool as a dynamic tool with the
  ///   server's JSON schema; otherwise only the named tools, typed by the given schemas.
  public func tools(schemas: [String: MCPToolSchema]? = nil) async throws -> ToolSet {
    var definitions = try await listTools()
    var all = definitions.tools
    while let cursor = definitions.nextCursor {
      definitions = try await listTools(cursor: cursor)
      all += definitions.tools
    }
    return try toolsFromDefinitions(MCPListToolsResult(tools: all, nextCursor: definitions.nextCursor), schemas: schemas)
  }

  /// Creates SDK tools from definitions without fetching them. Mirrors upstream `toolsFromDefinitions`.
  public func toolsFromDefinitions(_ definitions: MCPListToolsResult, schemas: [String: MCPToolSchema]? = nil) throws
    -> ToolSet
  {
    let prepared = prepareToolDefinitions(definitions)
    var entries: [(String, Tool)] = []
    for definition in prepared.tools {
      if let schemas, schemas[definition.name] == nil { continue }
      let title = definition.title ?? definition.annotations?["title"]?.stringValue
      var app: JSONObject?
      if let appMeta = try getMCPAppToolMeta(definition.meta), appMeta["resourceUri"] != nil {
        app = appMeta
        app?["mimeType"] = .string(MCP_APP_MIME_TYPE)
      }
      let metadata = MCPToolMetadata.make(
        clientName: clientInfo.name, toolName: definition.name, title: title, annotations: definition.annotations, app: app)
      let name = definition.name
      let outputSchema = schemas?[name]?.outputSchema
      let execute: Tool.Execute = { [weak self] input, _ in
        try Task.checkCancellation()
        guard let self else { throw MCPClientError(message: "MCP client was deallocated") }
        let result = try await self.callTool(name: name, arguments: input.objectValue ?? [:])
        if result.isError { return .object(result.json) }
        if let outputSchema { return try await self.extractStructuredContent(result, outputSchema, name) }
        return .object(result.json)
      }
      let toModelOutput: @Sendable (ToolModelOutputOptions) async throws -> ToolResultOutput = { mcpToModelOutput($0.output) }

      if let schema = schemas?[name] {
        entries.append(
          (
            name,
            Tool(
              kind: .function, description: definition.description, title: title, inputSchema: schema.inputSchema,
              outputSchema: schema.outputSchema?.jsonSchema, metadata: metadata, execute: execute,
              toModelOutput: toModelOutput)
          ))
      } else {
        var inputSchema = definition.inputSchema
        inputSchema["properties"] = inputSchema["properties"] ?? .object([:])
        inputSchema["additionalProperties"] = false
        entries.append(
          (
            name,
            Tool(
              kind: .dynamic, description: definition.description, title: title,
              inputSchema: jsonSchema(JSONSchema(.object(inputSchema))), metadata: metadata, execute: execute,
              toModelOutput: toModelOutput)
          ))
      }
    }
    return ToolSet(entries)
  }

  private func extractStructuredContent(_ result: MCPCallToolResult, _ schema: Schema<JSONValue>, _ toolName: String)
    async throws -> JSONValue
  {
    if let structured = result.structuredContent, structured != .null {
      do {
        return try schema.validate(structured)
      } catch {
        throw MCPClientError(
          message: "Tool \"\(toolName)\" returned structuredContent that does not match the expected outputSchema",
          cause: error)
      }
    }
    if let text = result.content?.first(where: { $0["type"] == "text" })?["text"]?.stringValue {
      do {
        return try schema.validate(try parseJSON(text))
      } catch {
        throw MCPClientError(
          message: "Tool \"\(toolName)\" returned content that does not match the expected outputSchema", cause: error)
      }
    }
    throw MCPClientError(message: "Tool \"\(toolName)\" did not return structuredContent or parseable text content")
  }

  // MARK: Resources, prompts, completions

  public func listResources(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws
    -> MCPListResourcesResult
  {
    try parse(
      try await request(method: "resources/list", params: cursor.map { ["cursor": .string($0)] }, options: options),
      MCPListResourcesResult.init(json:))
  }

  public func readResource(uri: String, options: MCPRequestOptions? = nil) async throws -> MCPReadResourceResult {
    try parse(
      try await request(method: "resources/read", params: ["uri": .string(uri)], options: options),
      MCPReadResourceResult.init(json:))
  }

  public func listResourceTemplates(options: MCPRequestOptions? = nil) async throws -> MCPListResourceTemplatesResult {
    try parse(
      try await request(method: "resources/templates/list", options: options), MCPListResourceTemplatesResult.init(json:))
  }

  /// Mirrors upstream `experimental_listPrompts`.
  public func listPrompts(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListPromptsResult {
    try parse(
      try await request(method: "prompts/list", params: cursor.map { ["cursor": .string($0)] }, options: options),
      MCPListPromptsResult.init(json:))
  }

  /// Mirrors upstream `experimental_getPrompt`.
  public func getPrompt(name: String, arguments: JSONObject? = nil, options: MCPRequestOptions? = nil) async throws
    -> MCPGetPromptResult
  {
    try parse(
      try await request(
        method: "prompts/get", params: jsonObject(["name": .string(name), "arguments": arguments.map(JSONValue.object)]).objectValue,
        options: options), MCPGetPromptResult.init(json:))
  }

  /// Requests argument completions.
  ///
  /// - Parameters:
  ///   - ref: `{type: "ref/prompt", name}` or `{type: "ref/resource", uri}`.
  ///   - argument: `{name, value}`.
  public func complete(
    ref: JSONObject, argument: JSONObject, context: JSONObject? = nil, options: MCPRequestOptions? = nil
  ) async throws -> MCPCompleteResult {
    try parse(
      try await request(
        method: "completion/complete",
        params: jsonObject([
          "ref": .object(ref), "argument": .object(argument), "context": context.map(JSONValue.object),
        ]).objectValue, options: options), MCPCompleteResult.init(json:))
  }

  /// Handles `elicitation/create` requests from the server. Mirrors upstream `onElicitationRequest`.
  public func onElicitationRequest(_ handler: @escaping @Sendable (MCPElicitationRequest) async throws -> MCPElicitResult) {
    elicitationHandler = handler
  }

  // MARK: Incoming messages

  private func onMessage(_ message: JSONRPCMessage) async {
    switch message {
    case .request(let id, let method, let params):
      await onRequest(id: id, method: method, params: params)
    case .notification:
      onError(MCPClientError(message: "Unsupported message type"))
    case .response(let id, let result):
      onResponse(id: id, result: .success(result), raw: message)
    case .error(let id, let error):
      guard let id else {
        onError(
          MCPClientError(
            message: "Protocol error: Received a response without a message ID: \(message.json.jsonString(sortedKeys: false))"))
        return
      }
      onResponse(
        id: id,
        result: .failure(
          MCPClientError(
            message: error.message, cause: MCPClientError(message: error.message), data: error.data, code: error.code)),
        raw: message)
    }
  }

  private func onResponse(id: JSONRPCID, result: Result<JSONObject, MCPClientError>, raw: JSONRPCMessage) {
    let numericId: Int? =
      switch id {
      case .int(let value): value
      case .string(let value): Int(value)
      }
    guard let numericId, let continuation = takePending(numericId) else {
      onError(
        MCPClientError(
          message: "Protocol error: Received a response for an unknown message ID: \(raw.json.jsonString(sortedKeys: false))"))
      return
    }
    switch result {
    case .failure(let error):
      continuation.resume(throwing: error)
    case .success(let object):
      if protocolEra == .modern, object["resultType"] == nil {
        continuation.resume(throwing: MCPClientError(message: "Modern MCP result is missing resultType"))
      } else if object["resultType"] == "input_required" {
        continuation.resume(
          throwing: MCPClientError(
            message: "Server requested additional input, but multi round-trip requests are not supported yet"))
      } else {
        continuation.resume(returning: object)
      }
    }
  }

  private func respond(_ id: JSONRPCID, result: JSONObject? = nil, error: JSONRPCErrorObject? = nil) async {
    do {
      if let error {
        try await transport.send(.error(id: id, error: error))
      } else {
        try await transport.send(.response(id: id, result: result ?? [:]))
      }
    } catch {
      onError(error)
    }
  }

  private func onRequest(id: JSONRPCID, method: String, params: JSONObject?) async {
    if method == "ping" { return await respond(id, result: [:]) }
    guard method == "elicitation/create" else {
      return await respond(id, error: JSONRPCErrorObject(code: -32601, message: "Unsupported request method: \(method)"))
    }
    guard let elicitationHandler else {
      return await respond(id, error: JSONRPCErrorObject(code: -32601, message: "No elicitation handler registered on client"))
    }
    guard let params, let message = params["message"]?.stringValue, params["_meta"].map({ $0.objectValue != nil }) ?? true
    else {
      return await respond(
        id,
        error: JSONRPCErrorObject(
          code: -32602, message: "Invalid elicitation request: params.message must be a string",
          data: params.map(JSONValue.object)))
    }
    do {
      let result = try await elicitationHandler(
        MCPElicitationRequest(message: message, requestedSchema: params["requestedSchema"], params: params))
      await respond(id, result: result.json)
    } catch {
      await respond(
        id,
        error: JSONRPCErrorObject(
          code: -32603, message: (error as? any AISDKError)?.message ?? error.localizedDescription))
      onError(error)
    }
  }

  private func onClose() {
    if isClosed { return }
    isClosed = true
    let continuations = pending.values
    pending.removeAll()
    for task in timeouts.values { task.cancel() }
    timeouts.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: MCPClientError(message: "Connection closed"))
    }
  }

  private func onError(_ error: any Error) {
    onUncaughtError?(error)
  }
}
