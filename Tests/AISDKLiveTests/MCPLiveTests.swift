import AISDK
import AISDKDeepSeek
import AISDKMCP
import Foundation
import Testing

// Live MCP tests: a remote Streamable HTTP server (DeepWiki), the reference
// "everything" server over stdio (needs npx), and DeepSeek calling MCP tools.

private let deepWikiURL = "https://mcp.deepwiki.com/mcp"
private let hasNpx = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"].contains {
  FileManager.default.isExecutableFile(atPath: $0)
}

@Suite(.enabled(if: liveEnabled), .serialized) struct MCPLiveTests {
  @Test func listsAndCallsRemoteHTTPTools() async throws {
    let mcp = try await createMCPClient(try MCPClientConfig(transport: MCPTransportConfig(type: .http, url: deepWikiURL)))
    let definitions = try await mcp.listTools()
    #expect(definitions.tools.contains { $0.name == "read_wiki_structure" })
    let result = try await mcp.callTool(name: "read_wiki_structure", arguments: ["repoName": "vercel/ai"])
    #expect(result.isError == false)
    #expect(result.content?.first?["text"]?.stringValue?.isEmpty == false)
    try await mcp.close()
  }

  @Test(.enabled(if: hasNpx)) func runsReferenceServerOverStdio() async throws {
    let mcp = try await createMCPClient(
      MCPClientConfig(
        transport: MCPStdioTransport(
          MCPStdioConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"], stderr: .discard)),
        initializationOptions: MCPRequestOptions(timeout: .seconds(90))))
    let tools = try await mcp.tools()
    let echo = try #require(tools["echo"])
    let output = try await echo.execute!(["message": "from swift"], ToolExecutionOptions(toolCallId: "1", messages: []))
    #expect(output["content"]?[0]?["text"]?.stringValue?.contains("from swift") == true)
    let resources = try await mcp.listResources()
    #expect(!resources.resources.isEmpty)
    let prompts = try await mcp.listPrompts()
    #expect(!prompts.prompts.isEmpty)
    try await mcp.close()
  }

  @Test func deepSeekUsesRemoteMCPTools() async throws {
    let mcp = try await createMCPClient(try MCPClientConfig(transport: MCPTransportConfig(type: .http, url: deepWikiURL)))
    let tools = try await mcp.tools()
    let structure = try #require(tools["read_wiki_structure"])
    let result = try await generateText(
      model: deepseek(flash),
      prompt: "Use the read_wiki_structure tool for the GitHub repo vercel/ai, then name one documentation topic it lists.",
      tools: ["read_wiki_structure": structure], providerOptions: ["deepseek": ["thinking": ["type": "disabled"]]],
      stopWhen: [.isStepCount(3)])
    #expect(result.steps.first?.toolCalls.first?.toolName == "read_wiki_structure")
    #expect(result.steps.count >= 2)
    #expect(!result.text.isEmpty)
    try await mcp.close()
  }
}
