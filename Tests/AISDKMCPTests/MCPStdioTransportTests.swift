#if os(macOS) || os(Linux)
  import AISDK
  import AISDKTestUtils
  import Foundation
  import Testing

  @testable import AISDKMCP

  private var productsDirectory: URL { Bundle.module.bundleURL.deletingLastPathComponent() }

  private var testServerPath: String { productsDirectory.appendingPathComponent("MCPTestServer").path }

  @Suite(.serialized) struct MCPStdioTransportTests {
    @Test func runsToolsOverARealProcess() async throws {
      let mcp = try await createMCPClient(
        MCPClientConfig(
          transport: MCPStdioTransport(
            MCPStdioConfig(command: testServerPath, env: ["MCP_TEST_INSTRUCTIONS": "be nice"], stderr: .discard))))
      #expect(await mcp.serverInfo.name == "stdio-test-server")
      #expect(await mcp.instructions == "be nice")

      let tools = try await mcp.tools()
      let echo = try #require(tools["echo"])
      #expect(echo.kind == .dynamic)
      let output = try await echo.execute!(["message": "hello"], ToolExecutionOptions(toolCallId: "1", messages: []))
      #expect(output["content"]?[0]?["text"] == "echo: hello")

      let concurrent = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<10 {
          group.addTask {
            try await mcp.callTool(name: "echo", arguments: ["message": .string("\(index)")]).content?.first?["text"]?
              .stringValue ?? ""
          }
        }
        return try await group.reduce(into: Set<String>()) { $0.insert($1) }
      }
      #expect(concurrent == Set((0..<10).map { "echo: \($0)" }))

      await #expect {
        _ = try await mcp.listResources()
      } throws: { error in
        (error as? MCPClientError)?.message == "Server does not support resources"
      }
      try await mcp.close()
    }

    @Test func failsPendingRequestsWhenTheProcessExits() async throws {
      let mcp = try await createMCPClient(
        MCPClientConfig(transport: MCPStdioTransport(MCPStdioConfig(command: testServerPath, stderr: .discard))))
      await #expect {
        _ = try await mcp.callTool(name: "exit")
      } throws: { error in
        (error as? MCPClientError)?.message == "Connection closed"
      }
    }

    @Test func reportsMissingCommands() async throws {
      await #expect {
        _ = try await createMCPClient(
          MCPClientConfig(transport: MCPStdioTransport(MCPStdioConfig(command: "definitely-not-an-mcp-server-\(UUID())"))))
      } throws: { error in
        (error as? MCPClientError)?.message.hasPrefix("Command not found") == true
      }
    }

    @Test func resolvesCommandsOnPath() {
      #expect(resolveExecutable("sh", path: "/nonexistent:/bin:/usr/bin")?.path.hasSuffix("/sh") == true)
      #expect(resolveExecutable("./local", path: nil)?.path.hasSuffix("local") == true)
    }
  }
#endif
