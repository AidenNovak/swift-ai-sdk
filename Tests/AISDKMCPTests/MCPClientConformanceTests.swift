import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKMCP
@testable import AISDKProviderUtils

private let conformanceCases: [JSONValue] = {
  guard let url = Bundle.module.url(forResource: "mcp-client-conformance", withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url), case .array(let cases)? = try? JSONValue(jsonData: data)
  else { return [] }
  return cases
}()

/// Replies to requests from a script, reusing the last reply per method.
actor ScriptedMCPTransport: MCPTransport {
  nonisolated let supportsProtocolVersionDiscovery: Bool
  nonisolated let supportsMcpToolParameterHeaders: Bool
  private var replies: [String: [JSONValue]]
  private var handler: MCPTransportHandler?
  private(set) var sent: [JSONValue] = []
  private(set) var protocolVersion: String?

  init(replies: JSONObject, modern: Bool) {
    self.replies = replies.mapValues { $0.arrayValue ?? [] }
    supportsProtocolVersionDiscovery = modern
    supportsMcpToolParameterHeaders = modern
  }

  func start(_ handler: MCPTransportHandler) async throws {
    self.handler = handler
  }

  var currentHandler: MCPTransportHandler? { handler }

  func close() async throws {
    await handler?.onClose()
  }

  func setProtocolVersion(_ version: String) async {
    protocolVersion = version
  }

  func send(_ message: JSONRPCMessage, options: MCPTransportSendOptions) async throws {
    var record = message.json.objectValue ?? [:]
    record["jsonrpc"] = nil
    record["id"] = nil
    if let headers = options.headers { record["headers"] = .object(headers.mapValues(JSONValue.string)) }
    sent.append(.object(record))
    guard case .request(let id, let method, _) = message else { return }
    var queue = replies[method] ?? []
    let reply: JSONValue? = queue.count > 1 ? queue.removeFirst() : queue.first
    replies[method] = queue
    let response: JSONRPCMessage
    if let error = reply?["error"]?.objectValue {
      response = .error(
        id: id,
        error: JSONRPCErrorObject(
          code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "", data: error["data"]))
    } else if let result = reply?["result"]?.objectValue {
      response = .response(id: id, result: result)
    } else {
      response = .error(id: id, error: JSONRPCErrorObject(code: -32601, message: "Method not found"))
    }
    let handler = handler
    Task { await handler?.onMessage(response) }
  }
}

private func errorJSON(_ error: any Error) -> JSONObject {
  let mcpError = error as? MCPClientError
  return [
    "error": [
      "message": .string((error as? any AISDKError)?.message ?? String(describing: error)),
      "code": mcpError?.code.map { .number(Double($0)) } ?? .null,
      "data": mcpError?.data ?? .null,
    ]
  ]
}

private func schemas(_ value: JSONValue?) -> [String: MCPToolSchema]? {
  guard case .object(let object)? = value else { return nil }
  return object.mapValues { entry in
    MCPToolSchema(
      inputSchema: jsonSchema(JSONSchema(entry["inputSchema"] ?? ["type": "object"])),
      outputSchema: entry["outputSchema"].map { jsonSchema(JSONSchema($0)) })
  }
}

private func describe(_ name: String, _ tool: Tool) -> JSONValue {
  jsonObject([
    "name": .string(name),
    "type": tool.kind == .dynamic ? "dynamic" : "function",
    "description": .optional(tool.description),
    "title": .optional(tool.title),
    "metadata": tool.metadata.map(JSONValue.object),
    "inputSchema": tool.inputSchema.jsonSchema.value,
  ])
}

private func run(_ operation: JSONValue, client: MCPClient) async throws -> JSONObject {
  let op = operation["op"]?.stringValue ?? ""
  switch op {
  case "tools":
    let tools = try await client.tools(schemas: schemas(operation["schemas"]))
    return ["tools": .array(tools.map { describe($0.0, $0.1) })]
  case "execute":
    let tools = try await client.tools(schemas: schemas(operation["schemas"]))
    let tool = try #require(tools[operation["tool"]?.stringValue ?? ""])
    let input = operation["input"] ?? [:]
    let output = try await tool.execute!(input, ToolExecutionOptions(toolCallId: "call-1", messages: []))
    let modelOutput = try await tool.toModelOutput!(ToolModelOutputOptions(toolCallId: "call-1", input: input, output: output))
    return ["output": output, "modelOutput": modelOutput.json]
  case "callTool":
    return [
      "result": .object(
        try await client.callTool(
          name: operation["name"]?.stringValue ?? "", arguments: operation["arguments"]?.objectValue ?? [:]
        ).json)
    ]
  case "listResources":
    let result = try await client.listResources()
    return ["result": ["resources": .array(result.resources.map { .object($0.raw) })]]
  case "readResource":
    let result = try await client.readResource(uri: operation["uri"]?.stringValue ?? "")
    return ["result": ["contents": .array(result.contents)]]
  case "listResourceTemplates":
    let result = try await client.listResourceTemplates()
    return ["result": ["resourceTemplates": .array(result.resourceTemplates.map(JSONValue.object))]]
  case "listPrompts":
    let result = try await client.listPrompts()
    return ["result": ["prompts": .array(result.prompts.map { .object($0.raw) })]]
  case "getPrompt":
    let result = try await client.getPrompt(
      name: operation["name"]?.stringValue ?? "", arguments: operation["arguments"]?.objectValue)
    return ["result": jsonObject(["description": .optional(result.description), "messages": .array(result.messages.map(JSONValue.object))])]
  case "complete":
    let result = try await client.complete(
      ref: operation["ref"]?.objectValue ?? [:], argument: operation["argument"]?.objectValue ?? [:])
    return [
      "result": [
        "completion": jsonObject([
          "values": .array(result.values.map(JSONValue.string)), "total": .optional(result.total),
          "hasMore": .optional(result.hasMore),
        ])
      ]
    ]
  case "close":
    try await client.close()
    return [:]
  default:
    Issue.record("unknown operation \(op)")
    return [:]
  }
}

@Suite struct MCPClientConformanceTests {
  @Test func loadsRecordedCases() {
    #expect(conformanceCases.count >= 8)
  }

  @Test(arguments: conformanceCases.map { $0["name"]?.stringValue ?? "" })
  func matchesUpstream(_ name: String) async throws {
    let entry = try #require(conformanceCases.first { $0["name"]?.stringValue == name })
    let transport = ScriptedMCPTransport(
      replies: entry["replies"]?.objectValue ?? [:], modern: entry["modernDiscovery"]?.boolValue ?? false)
    let config = entry["config"]?.objectValue ?? [:]
    var results: [JSONValue] = []
    var client: MCPClient?
    do {
      let created = try await createMCPClient(
        MCPClientConfig(
          transport: transport, clientName: config["clientName"]?.stringValue ?? "ai-sdk-mcp-client",
          version: config["version"]?.stringValue ?? "1.0.0", capabilities: config["capabilities"]?.objectValue ?? [:]))
      client = created
      let info = await created.serverInfo
      let instructions = await created.instructions
      let protocolVersion = await created.initializeResult.protocolVersion
      results.append(
        [
          "op": "init", "serverInfo": .object(info.raw), "instructions": instructions.map(JSONValue.string) ?? .null,
          "protocolVersion": .string(protocolVersion),
        ])
    } catch {
      var record = errorJSON(error)
      record["op"] = "init"
      results.append(.object(record))
    }
    if let client {
      for operation in entry["operations"]?.arrayValue ?? [] {
        var record: JSONObject
        do {
          record = try await run(operation, client: client)
        } catch {
          record = errorJSON(error)
        }
        record["op"] = operation["op"]
        results.append(.object(record))
      }
    }
    let sent = await transport.sent
    let resultDiff = UpstreamConformance.differences(entry["results"] ?? [], .array(results))
    let sentDiff = UpstreamConformance.differences(entry["sent"] ?? [], .array(sent))
    for (label, diff) in [("results", resultDiff), ("sent", sentDiff)] where !diff.isEmpty {
      let details = diff.prefix(15).joined(separator: "\n")
      Issue.record(Comment(rawValue: "\(name) \(label): \(diff.count) difference(s)\n\(details)"))
    }
  }
}
