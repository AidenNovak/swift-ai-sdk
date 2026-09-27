import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKMCP

@Suite struct MCPPrimitiveTests {
  @Test func sha256MatchesKnownVectors() {
    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    #expect(hex(sha256(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(hex(sha256(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
    #expect(hex(sha256(long)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(hex(sha256(Data(repeating: 0x61, count: 1_000))) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
  }

  @Test func pkceMatchesRFC7636Example() {
    #expect(
      PKCEChallenge.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let generated = PKCEChallenge.generate()
    #expect(generated.codeVerifier.count == 43)
    #expect(PKCEChallenge.challenge(for: generated.codeVerifier) == generated.codeChallenge)
  }

  @Test func validatesJSONRPCMessages() throws {
    #expect(
      try validateJSONRPCMessage(["jsonrpc": "2.0", "id": 1, "method": "ping"]) == .request(id: .int(1), method: "ping"))
    #expect(try validateJSONRPCMessage(["jsonrpc": "2.0", "method": "notifications/x"]) == .notification(method: "notifications/x"))
    #expect(try validateJSONRPCMessage(["jsonrpc": "2.0", "id": "a", "result": [:]]) == .response(id: .string("a"), result: [:]))
    #expect(
      try validateJSONRPCMessage(["jsonrpc": "2.0", "error": ["code": -32700, "message": "Parse error"]])
        == .error(id: nil, error: JSONRPCErrorObject(code: -32700, message: "Parse error")))
    #expect(throws: MCPClientError.self) { try validateJSONRPCMessage(["jsonrpc": "1.0", "id": 1, "method": "x"]) }
    #expect(throws: MCPClientError.self) { try validateJSONRPCMessage(["jsonrpc": "2.0", "id": 1, "method": "x", "extra": 1]) }
    #expect(throws: MCPClientError.self) { try validateJSONRPCMessage(["jsonrpc": "2.0", "id": 1.5, "result": [:]]) }
    #expect(throws: MCPClientError.self) { try validateJSONRPCMessage(["jsonrpc": "2.0", "id": 1, "result": 3]) }
  }

  @Test func buildsToolParameterHeaders() throws {
    let schema: JSONValue = [
      "type": "object",
      "properties": [
        "region": ["type": "string", "x-mcp-header": "Region"],
        "nested": ["type": "object", "properties": ["flag": ["type": "boolean", "x-mcp-header": "Flag"]]],
        "count": ["type": "integer", "x-mcp-header": "Count"],
      ],
    ]
    let bindings = try getMCPToolHeaderBindings(schema).get()
    let headers = try createMCPToolHeaders(
      bindings: bindings, args: ["region": "東京", "nested": ["flag": true], "count": 3])
    #expect(headers["Mcp-Param-Region"] == "=?base64?5p2x5Lqs?=")
    #expect(headers["Mcp-Param-Flag"] == "true")
    #expect(headers["Mcp-Param-Count"] == "3")
    #expect(throws: MCPClientError.self) {
      try createMCPToolHeaders(bindings: bindings, args: ["count": 1.5])
    }
    let invalid: JSONValue = ["type": "object", "anyOf": [["properties": ["a": ["type": "string", "x-mcp-header": "A"]]]]]
    if case .success = getMCPToolHeaderBindings(invalid) { Issue.record("expected unreachable header error") }
    #expect(encodeMCPHeaderValue("plain") == "plain")
    #expect(encodeMCPHeaderValue(" padded") == "=?base64?IHBhZGRlZA==?=")
  }

  @Test func splitsMCPAppTools() throws {
    let tools = MCPListToolsResult(tools: [
      MCPToolDefinition(name: "both", meta: ["ui": ["resourceUri": "ui://a", "visibility": ["model", "app"]]]),
      MCPToolDefinition(name: "app-only", meta: ["ui": ["resourceUri": "ui://b", "visibility": ["app"]]]),
      MCPToolDefinition(name: "plain"),
      MCPToolDefinition(name: "legacy", meta: ["ui/resourceUri": "ui://a"]),
    ])
    let (model, app) = try splitMCPAppTools(tools)
    #expect(model.tools.map(\.name) == ["both", "plain", "legacy"])
    #expect(app.tools.map(\.name) == ["both", "app-only"])
    #expect(try getMCPAppResourceUris(tools) == ["ui://a", "ui://b"])
    #expect(throws: MCPClientError.self) { try getMCPAppToolMeta(["ui": ["resourceUri": "https://x"]]) }

    let resource = try getMCPAppResource(
      uri: "ui://a",
      from: MCPReadResourceResult(
        json: [
          "contents": [
            [
              "uri": "ui://a", "mimeType": .string(MCP_APP_MIME_TYPE), "text": "<p>hi</p>",
              "_meta": ["ui": ["prefersBorder": true, "csp": ["connectDomains": ["a.com", 1]]]],
            ]
          ]
        ]))
    #expect(resource.html == "<p>hi</p>")
    #expect(resource.meta?["csp"] == ["connectDomains": ["a.com"]])
    #expect(fingerprintMCPAppResource(resource) == fingerprintMCPAppResource(resource))
  }

  @Test func inheritsOnlySafeEnvironment() {
    #if os(macOS) || os(Linux)
      let env = mcpStdioEnvironment(["FOO": "bar", "PATH": "/custom"], base: ["PATH": "/usr/bin", "HOME": "/home/me", "SECRET": "x", "SHELL": "() { :; }"])
      #expect(env == ["FOO": "bar", "PATH": "/custom", "HOME": "/home/me"])
    #endif
  }

  @Test func parsesWWWAuthenticate() {
    let (url, scope) = extractWWWAuthenticateParams([
      "www-authenticate": #"Bearer realm="mcp", resource_metadata="https://a.com/.well-known/oauth-protected-resource", scope="read write""#
    ])
    #expect(url?.absoluteString == "https://a.com/.well-known/oauth-protected-resource")
    #expect(scope == "read write")
    #expect(extractWWWAuthenticateParams(["www-authenticate": "Basic realm=x"]).resourceMetadataURL == nil)
  }

  @Test func checksResourceURLs() {
    #expect(checkResourceAllowed(requested: "https://a.com/mcp/sub", configured: "https://a.com/mcp"))
    #expect(!checkResourceAllowed(requested: "https://a.com/mcpx", configured: "https://a.com/mcp"))
    #expect(!checkResourceAllowed(requested: "https://b.com/mcp", configured: "https://a.com/mcp"))
    #expect(resourceURLStripSlash("https://a.com/") == "https://a.com")
    #expect(resourceURLFromServerURL("https://a.com/mcp#frag") == "https://a.com/mcp")
  }
}

private let serverURL = "https://mcp.example.com/mcp"

private func rpcResult(_ request: HTTPRequest, _ result: JSONObject) -> MockHTTPClient.Response {
  let id = request.bodyJSON?["id"] ?? .null
  return .jsonValue(["jsonrpc": "2.0", "id": id, "result": .object(result)])
}

private let legacyInitialize: JSONObject = [
  "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]], "serverInfo": ["name": "s", "version": "1"],
]

@Suite struct MCPHTTPTransportTests {
  @Test func runsModernDiscoveryWithStandardHeaders() async throws {
    let client = MockHTTPClient { request in
      switch request.bodyJSON?["method"]?.stringValue {
      case "server/discover":
        return rpcResult(
          request, ["resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]]])
      case "tools/call":
        return .streamChunks([
          #"data: {"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[{"type":"text","text":"hi"}]}}"# + "\n\n"
        ])
      default:
        return .error(statusCode: 500, body: "unexpected")
      }
    }
    let mcp = try await createMCPClient(
      try MCPClientConfig(transport: MCPTransportConfig(type: .http, url: serverURL, headers: ["X-App": "1"], httpClient: client)))
    let result = try await mcp.callTool(name: "search", arguments: ["q": "swift"])
    #expect(result.content?.first?["text"] == "hi")

    let call = try #require(client.requests.last)
    #expect(call.headers["mcp-method"] == "tools/call")
    #expect(call.headers["mcp-name"] == "search")
    #expect(call.headers["mcp-protocol-version"] == "2026-07-28")
    #expect(call.headers["x-app"] == "1")
    #expect(call.headers["accept"] == "application/json, text/event-stream")
    #expect(call.headers["user-agent"]?.contains("ai-sdk/") == true)
    #expect(call.redirect == .error)
    #expect(client.requests.allSatisfy { $0.method == "POST" })
  }

  @Test func handlesLegacySessionsAndJSONBatches() async throws {
    let sessions = Recorder<String>()
    let client = MockHTTPClient { request in
      if request.method == "GET" { return .empty(statusCode: 405) }
      if request.method == "DELETE" { return .empty(statusCode: 200) }
      switch request.bodyJSON?["method"]?.stringValue {
      case "server/discover": return .error(statusCode: 400, body: "unknown")
      case "initialize":
        return .jsonValue(
          ["jsonrpc": "2.0", "id": request.bodyJSON?["id"] ?? .null, "result": .object(legacyInitialize)],
          headers: ["mcp-session-id": "session-1"])
      case "notifications/initialized": return .empty(statusCode: 202)
      case "tools/list":
        return .jsonValue([["jsonrpc": "2.0", "id": request.bodyJSON?["id"] ?? .null, "result": ["tools": []]]])
      default: return .error(statusCode: 404, body: "gone")
      }
    }
    let mcp = try await createMCPClient(
      try MCPClientConfig(
        transport: MCPTransportConfig(
          type: .http, url: serverURL, onSessionIdChange: { sessions.append($0 ?? "nil") },
          onSessionExpired: { sessions.append("expired:\($0)") }, httpClient: client)))
    #expect(try await mcp.listTools().tools.isEmpty)
    let listRequest = try #require(client.requests.last { $0.bodyJSON?["method"] == "tools/list" })
    #expect(listRequest.headers["mcp-session-id"] == "session-1")
    #expect(listRequest.headers["mcp-protocol-version"] == "2025-11-25")

    await #expect {
      _ = try await mcp.callTool(name: "x")
    } throws: { error in
      (error as? MCPClientError)?.message.contains("The MCP session expired") == true
    }
    #expect(sessions.values == ["session-1", "nil", "expired:session-1"])
    try await mcp.close()
  }

  @Test func deliversJSONRPCErrorBodiesFromHTTPErrors() async throws {
    let client = MockHTTPClient { request in
      switch request.bodyJSON?["method"]?.stringValue {
      case "server/discover":
        return rpcResult(
          request, ["resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]]])
      default:
        return .jsonValue(
          ["jsonrpc": "2.0", "error": ["code": -32602, "message": "Bad arguments"]], statusCode: 400)
      }
    }
    let mcp = try await createMCPClient(try MCPClientConfig(transport: MCPTransportConfig(type: .http, url: serverURL, httpClient: client)))
    await #expect {
      _ = try await mcp.callTool(name: "x")
    } throws: { error in
      (error as? MCPClientError)?.code == -32602 && (error as? MCPClientError)?.message == "Bad arguments"
    }
  }

  @Test func retriesTransientToolCallFailures() async throws {
    let attempts = Recorder<Int>()
    let client = MockHTTPClient { request in
      switch request.bodyJSON?["method"]?.stringValue {
      case "server/discover":
        return rpcResult(
          request, ["resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]]])
      default:
        attempts.append(1)
        if attempts.values.count < 2 { return .error(statusCode: 503, body: "busy") }
        return rpcResult(request, ["resultType": "complete", "content": [["type": "text", "text": "ok"]]])
      }
    }
    let mcp = try await createMCPClient(
      try MCPClientConfig(transport: MCPTransportConfig(type: .http, url: serverURL, httpClient: client), maxRetries: 1))
    let result = try await mcp.callTool(name: "x")
    #expect(result.content?.first?["text"] == "ok")
    #expect(attempts.values.count == 2)
  }

  @Test func timesOutRequests() async throws {
    let transport = ScriptedMCPTransport(
      replies: ["initialize": [["result": .object(legacyInitialize)]]], modern: false)
    let mcp = try await createMCPClient(MCPClientConfig(transport: transport))
    let silent = SilentTransport()
    _ = mcp
    let slow = try await createMCPClient(
      MCPClientConfig(transport: silent, initialInitializeResult: try MCPInitializeResult(json: legacyInitialize)))
    await #expect {
      _ = try await slow.callTool(name: "x", options: MCPRequestOptions(timeout: .milliseconds(50)))
    } throws: { error in
      (error as? MCPClientError)?.message == "Request timed out after 50ms"
    }
    let task = Task { try await slow.callTool(name: "x") }
    try await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    await #expect {
      _ = try await task.value
    } throws: { error in
      (error as? MCPClientError)?.message == "Request was aborted"
    }
    try await slow.close()
    await #expect {
      _ = try await slow.callTool(name: "x")
    } throws: { error in
      (error as? MCPClientError)?.message == "Attempted to send a request from a closed client"
    }
  }

  @Test func answersPingAndElicitation() async throws {
    let transport = ScriptedMCPTransport(replies: ["initialize": [["result": .object(legacyInitialize)]]], modern: false)
    let mcp = try await createMCPClient(MCPClientConfig(transport: transport))
    await mcp.onElicitationRequest { request in
      MCPElicitResult(action: .accept, content: ["name": .string(request.message)])
    }
    await transport.deliver(.request(id: .string("p1"), method: "ping"))
    await transport.deliver(.request(id: .string("e1"), method: "elicitation/create", params: ["message": "Your name?", "requestedSchema": [:]]))
    await transport.deliver(.request(id: .string("u1"), method: "sampling/createMessage"))
    try await Task.sleep(nanoseconds: 50_000_000)
    let sent = await transport.sent
    #expect(sent.contains(["result": [:]]))
    #expect(sent.contains(["result": ["action": "accept", "content": ["name": "Your name?"]]]))
    #expect(sent.contains(["error": ["code": -32601, "message": "Unsupported request method: sampling/createMessage"]]))
  }
}

/// Never answers; used to exercise timeouts and cancellation.
actor SilentTransport: MCPTransport {
  private var handler: MCPTransportHandler?
  func start(_ handler: MCPTransportHandler) async throws { self.handler = handler }
  func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws {}
  func close() async throws { await handler?.onClose() }
}

extension ScriptedMCPTransport {
  func deliver(_ message: JSONRPCMessage) async {
    await currentHandler?.onMessage(message)
  }
}

@Suite struct MCPSSETransportTests {
  @Test func connectsThroughEndpointEvent() async throws {
    let (events, feed) = HTTPBodyStream.makeStream()
    feed.yield(Data("event: endpoint\ndata: /messages?session=abc\n\n".utf8))
    let client = MockHTTPClient { request in
      if request.method == "GET" { return .stream(events) }
      guard let body = request.bodyJSON, let id = body["id"] else { return .empty(statusCode: 202) }
      let result: JSONValue =
        body["method"] == "initialize"
        ? .object(legacyInitialize) : ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]]
      let message: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
      feed.yield(Data("event: message\ndata: \(message.jsonString())\n\n".utf8))
      return .empty(statusCode: 202)
    }
    let mcp = try await createMCPClient(try MCPClientConfig(transport: MCPTransportConfig(type: .sse, url: serverURL, httpClient: client)))
    #expect(try await mcp.listTools().tools.map(\.name) == ["echo"])
    let post = try #require(client.requests.last { $0.method == "POST" })
    #expect(post.url.absoluteString == "https://mcp.example.com/messages?session=abc")
    try await mcp.close()
    feed.finish()
  }

  @Test func rejectsCrossOriginEndpoint() async throws {
    let client = MockHTTPClient { _ in
      .streamChunks(["event: endpoint\ndata: https://evil.example.com/messages\n\n"])
    }
    await #expect {
      _ = try await createMCPClient(try MCPClientConfig(transport: MCPTransportConfig(type: .sse, url: serverURL, httpClient: client)))
    } throws: { error in
      (error as? MCPClientError)?.message.contains("Endpoint origin does not match") == true
    }
  }
}
