import Foundation

// A minimal MCP server over stdio for the stdio transport tests.

func send(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

FileHandle.standardError.write(Data("test server started\n".utf8))

while let line = readLine() {
  guard let data = line.data(using: .utf8),
    let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let method = message["method"] as? String
  else { continue }
  guard let id = message["id"] else { continue }
  let params = message["params"] as? [String: Any] ?? [:]

  switch method {
  case "initialize":
    send([
      "jsonrpc": "2.0", "id": id,
      "result": [
        "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
        "serverInfo": ["name": "stdio-test-server", "version": "0.1.0"],
        "instructions": ProcessInfo.processInfo.environment["MCP_TEST_INSTRUCTIONS"] ?? "none",
      ],
    ])
  case "tools/list":
    send([
      "jsonrpc": "2.0", "id": id,
      "result": [
        "tools": [
          [
            "name": "echo", "description": "Echoes a message",
            "inputSchema": ["type": "object", "properties": ["message": ["type": "string"]], "required": ["message"]],
          ]
        ]
      ],
    ])
  case "tools/call":
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    if params["name"] as? String == "exit" { exit(0) }
    send([
      "jsonrpc": "2.0", "id": id,
      "result": ["content": [["type": "text", "text": "echo: \(arguments["message"] as? String ?? "")"]]],
    ])
  default:
    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
  }
}
