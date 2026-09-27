import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKOpenAI

private let responsesURL = "https://api.openai.com/v1/responses"

/// Cases recorded by running the upstream TypeScript implementation on the
/// same fixtures (`Tools/conformance/run.sh`).
private let conformanceCases: [JSONValue] = {
  guard let text = try? fixture("openai-responses-conformance.json"), case .array(let cases)? = try? JSONValue(jsonString: text)
  else { return [] }
  return cases
}()

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

@Suite struct OpenAIResponsesConformanceTests {
  @Test func loadsRecordedCases() {
    #expect(conformanceCases.count >= 60)
  }

  @Test(arguments: conformanceCases.map(caseKey))
  func matchesUpstream(_ key: String) async throws {
    let entry = try #require(conformanceCases.first { caseKey($0) == key })
    let fixtureName = try #require(entry["fixture"]?.stringValue)
    let isStream = entry["mode"]?.stringValue == "stream"
    let client = MockHTTPClient([
      responsesURL: isStream ? try chunksFixture(fixtureName) : try jsonFixture(fixtureName)
    ])
    let counter = Counter()
    let model = OpenAIResponsesLanguageModel(
      modelId: entry["modelId"]?.stringValue ?? "",
      config: OpenAIConfig(
        provider: "openai", headers: { ["Authorization": "Bearer APIKEY"] },
        url: { "https://api.openai.com/v1\($0)" }, httpClient: client, generateId: { counter.next() },
        fileIdPrefixes: ["file-"]))
    let options = try UpstreamConformance.callOptions(entry["options"] ?? [:])

    do {
      if isStream {
        let result = try await model.doStream(options)
        let parts = try await collect(result.stream).map(UpstreamConformance.json)
        record(
          UpstreamConformance.differences(normalizeParseErrors(entry["parts"] ?? []), normalizeParseErrors(.array(parts))),
          "\(key) parts")
      } else {
        let result = try await model.doGenerate(options)
        record(
          UpstreamConformance.differences(entry["content"] ?? [], .array(result.content.map(UpstreamConformance.json))),
          "\(key) content")
        record(
          UpstreamConformance.differences(entry["finishReason"] ?? .null, UpstreamConformance.json(result.finishReason)),
          "\(key) finishReason")
        record(UpstreamConformance.differences(entry["usage"] ?? .null, UpstreamConformance.json(result.usage)), "\(key) usage")
        record(
          UpstreamConformance.differences(
            entry["providerMetadata"] ?? .null, result.providerMetadata.map { .object($0.mapValues(JSONValue.object)) } ?? .null),
          "\(key) providerMetadata")
        record(
          UpstreamConformance.differences(entry["warnings"] ?? [], .array(result.warnings.map(UpstreamConformance.json))),
          "\(key) warnings")
      }
      #expect(entry["error"] == nil, "\(key): upstream threw \(entry["error"]?.jsonString() ?? "")")
    } catch {
      let expected = try #require(entry["error"], "\(key): unexpected error \(error)")
      let apiError = error as? APICallError
      #expect(apiError?.message == expected["message"]?.stringValue)
      #expect(apiError?.statusCode == expected["statusCode"]?.intValue)
      #expect(apiError?.isRetryable == expected["isRetryable"]?.boolValue)
    }

    record(
      UpstreamConformance.differences(entry["requestBody"] ?? .null, client.lastRequest?.bodyJSON ?? .null),
      "\(key) requestBody")
  }
}
