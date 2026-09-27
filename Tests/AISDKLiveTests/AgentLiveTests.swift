import AISDK
import AISDKDeepSeek
import Foundation
import Testing

@Suite(.enabled(if: liveEnabled), .serialized) struct AgentLiveTests {
  static let dateTool = tool(
    description: "Get today's date in YYYY-MM-DD format.",
    inputSchema: jsonSchema(["type": "object", "properties": [:]])
  ) { _, _ in "2026-09-27" }

  @Test func multiToolAgentChainsCalls() async throws {
    let steps = LiveRecorder()
    let agent = ToolLoopAgent(
      model: deepseek(flash),
      instructions: "You are a weather assistant. Always look up today's date before checking the weather.",
      tools: ["date": Self.dateTool, "weather": weatherTool],
      maxOutputTokens: 2000, reasoning: .low,
      onStepFinish: { steps.append($0.toolCalls.map(\.toolName)) })

    let result = try await agent.generate(prompt: "What's the weather in Hangzhou today? Mention the date.")
    let calledTools = Set(result.toolCalls.map(\.toolName))
    #expect(calledTools == ["date", "weather"])
    #expect(result.text.contains("2026"))
    #expect(steps.count == result.steps.count)
  }

  @Test func structuredOutputAgentStreams() async throws {
    let agent = ToolLoopAgent(
      model: deepseek(flash), tools: ["weather": weatherTool],
      output: .object(
        schema: Schema(
          WeatherReport.self,
          jsonSchema: [
            "type": "object",
            "properties": ["city": ["type": "string"], "celsius": ["type": "integer"]],
            "required": ["city", "celsius"],
          ])),
      maxOutputTokens: 2000, reasoning: .low)
    let result = try await agent.stream(prompt: "Look up the weather in Qingdao and report it as JSON.")
    let report = try await result.output
    #expect(report.celsius == 23)
    #expect(report.city.lowercased().contains("qingdao"))
  }
}

struct WeatherReport: Codable, Sendable {
  var city: String
  var celsius: Int
}

final class LiveRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[String]] = []

  func append(_ value: [String]) { lock.withLock { values.append(value) } }
  var count: Int { lock.withLock { values.count } }
}
