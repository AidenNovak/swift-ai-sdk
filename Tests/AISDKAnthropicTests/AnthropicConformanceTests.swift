import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKAnthropic

private let messagesURL = "https://api.anthropic.com/v1/messages"

/// Cases recorded by running the upstream TypeScript implementation on its
/// recorded API responses (`Tools/conformance/run.sh`).
private let conformanceCases: [JSONValue] = {
  guard
    let url = Bundle.module.url(forResource: "anthropic-conformance", withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url), case .array(let cases)? = try? JSONValue(jsonData: data)
  else { return [] }
  return cases
}()

private func upstreamFixture(_ name: String, _ ext: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/upstream"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func response(fixture: String, stream: Bool) throws -> MockHTTPClient.Response {
  if stream {
    let lines = try upstreamFixture(fixture, "chunks.txt").components(separatedBy: "\n")
    return .streamChunks(lines.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"])
  }
  return .jsonValue(try JSONValue(jsonString: try upstreamFixture(fixture, "json")))
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> String {
    lock.withLock {
      defer { value += 1 }
      return "id-\(value)"
    }
  }
}

/// JSON parse errors quote the platform parser's message, which differs
/// between JavaScript and Foundation; compare everything before it.
private func normalizeParseErrors(_ parts: JSONValue) -> JSONValue {
  guard case .array(let items) = parts else { return parts }
  return .array(
    items.map { part in
      guard case .object(var object) = part, object["type"] == "error", let message = object["message"]?.stringValue,
        message.hasPrefix("JSON parsing failed"), let range = message.range(of: "\nError message:")
      else { return part }
      object["message"] = .string(String(message[..<range.lowerBound]))
      return .object(object)
    })
}

private func caseKey(_ entry: JSONValue) -> String {
  "\(entry["name"]?.stringValue ?? "?")/\(entry["mode"]?.stringValue ?? "?")"
}

private func record(_ differences: [String], _ label: String) {
  guard !differences.isEmpty else { return }
  let details = differences.prefix(15).joined(separator: "\n")
  Issue.record(Comment(rawValue: "\(label): \(differences.count) difference(s)\n\(details)"))
}

@Suite struct AnthropicConformanceTests {
  @Test func loadsRecordedCases() {
    #expect(conformanceCases.count >= 100)
  }

  @Test(arguments: conformanceCases.map(caseKey))
  func matchesUpstream(_ key: String) async throws {
    let entry = try #require(conformanceCases.first { caseKey($0) == key })
    let fixture = try #require(entry["fixture"]?.stringValue)
    let isStream = entry["mode"]?.stringValue == "stream"
    let client = MockHTTPClient([messagesURL: try response(fixture: fixture, stream: isStream)])
    let counter = Counter()
    let model = AnthropicMessagesLanguageModel(
      modelId: entry["modelId"]?.stringValue ?? "",
      config: AnthropicMessagesConfig(
        provider: entry["provider"]?.stringValue ?? "anthropic.messages", baseURL: "https://api.anthropic.com/v1",
        headers: { ["x-api-key": "test-key", "anthropic-version": "2023-06-01"] }, httpClient: client,
        generateId: { counter.next() }))
    let options = try UpstreamConformance.callOptions(entry["options"] ?? [:])

    do {
      if isStream {
        let result = try await model.doStream(options)
        let parts = try await collect(result.stream).map(UpstreamConformance.json)
        record(
          UpstreamConformance.differences(normalizeParseErrors(entry["parts"] ?? []), normalizeParseErrors(.array(parts))),
          "parts")
      } else {
        let result = try await model.doGenerate(options)
        record(UpstreamConformance.differences(entry["content"] ?? [], .array(result.content.map(UpstreamConformance.json))), "content")
        record(UpstreamConformance.differences(entry["finishReason"] ?? .null, UpstreamConformance.json(result.finishReason)), "finishReason")
        record(UpstreamConformance.differences(entry["usage"] ?? .null, UpstreamConformance.json(result.usage)), "usage")
        record(
          UpstreamConformance.differences(
            entry["providerMetadata"] ?? .null,
            result.providerMetadata.map { .object($0.mapValues(JSONValue.object)) } ?? .null),
          "providerMetadata")
        record(
          UpstreamConformance.differences(entry["warnings"] ?? [], .array(result.warnings.map(UpstreamConformance.json))),
          "warnings")
      }
      #expect(entry["error"] == nil, "upstream failed with \(entry["error"] ?? .null)")
    } catch let error as any AISDKError {
      #expect(entry["error"]?["name"]?.stringValue == error.name, "\(error)")
      #expect(entry["error"]?["message"]?.stringValue == error.message)
      return
    }

    if let expectedBody = entry["requestBody"], !expectedBody.isNull {
      let body = try #require(client.lastRequest?.bodyJSON)
      record(UpstreamConformance.differences(expectedBody, body), "requestBody")
      let betas = (client.lastRequest?.headers["anthropic-beta"] ?? "").split(separator: ",").map(String.init).sorted()
      record(UpstreamConformance.differences(entry["betas"] ?? [], .array(betas.map(JSONValue.string))), "betas")
    }
  }
}
