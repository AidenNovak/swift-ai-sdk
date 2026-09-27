import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKMCP

private let oauthCases: [JSONValue] = {
  guard let url = Bundle.module.url(forResource: "mcp-oauth-conformance", withExtension: "json", subdirectory: "Fixtures"),
    let data = try? Data(contentsOf: url), case .array(let cases)? = try? JSONValue(jsonData: data)
  else { return [] }
  return cases
}()

/// An in-memory provider matching the recording provider in `Tools/conformance/mcp-oauth.mts`.
final class RecordingOAuthProvider: OAuthClientProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var storedTokens: OAuthTokens?
  private var storedClient: OAuthClientInformation?
  private var storedServerInformation: OAuthAuthorizationServerInformation?
  private var verifier: String?
  private let expectedState: String?
  private let dynamicallyRegistered: Bool
  private let canSaveServerInformation: Bool
  private(set) var calls: [JSONValue] = []

  let redirectURL = "http://127.0.0.1:33418/callback"
  let clientMetadata = OAuthClientMetadata(
    redirectUris: ["http://127.0.0.1:33418/callback"], clientName: "Swift AI SDK", scope: "fallback")

  init(state: JSONObject) throws {
    storedTokens = try state["tokens"].map { try $0.decode(as: OAuthTokens.self) }
    storedClient = try state["clientInformation"].map { try $0.decode(as: OAuthClientInformation.self) }
    verifier = state["codeVerifier"]?.stringValue
    expectedState = state["storedState"]?.stringValue
    dynamicallyRegistered = state["dynamicallyRegistered"]?.boolValue ?? false
    canSaveServerInformation = state["canSaveAuthorizationServerInformation"]?.boolValue ?? false
  }

  private func record(_ method: String, _ value: JSONValue) {
    lock.withLock { calls.append(["method": .string(method), "value": value]) }
  }

  func tokens() async throws -> OAuthTokens? { lock.withLock { storedTokens } }
  func saveTokens(_ tokens: OAuthTokens) async throws {
    record("saveTokens", try JSONValue(encoding: tokens))
    lock.withLock { storedTokens = tokens }
  }
  func redirectToAuthorization(_ authorizationURL: URL) async throws {
    record("redirectToAuthorization", .string(authorizationURL.absoluteString))
  }
  func saveCodeVerifier(_ codeVerifier: String) async throws {
    record("saveCodeVerifier", .string(codeVerifier))
    lock.withLock { verifier = codeVerifier }
  }
  func codeVerifier() async throws -> String { lock.withLock { verifier ?? "" } }
  func clientInformation() async throws -> OAuthClientInformation? { lock.withLock { storedClient } }
  func saveClientInformation(_ clientInformation: OAuthClientInformation) async throws -> Bool {
    record("saveClientInformation", try JSONValue(encoding: clientInformation))
    lock.withLock { storedClient = clientInformation }
    return true
  }
  func invalidateCredentials(_ scope: OAuthCredentialScope) async throws {
    record("invalidateCredentials", .string(scope.rawValue))
    lock.withLock {
      if scope == .tokens || scope == .all { storedTokens = nil }
      if scope == .all || scope == .client { storedClient = nil }
    }
  }
  func isClientInformationDynamicallyRegistered() async throws -> Bool { dynamicallyRegistered }
  func storedState() async throws -> String? { expectedState }
  func authorizationServerInformation() async throws -> OAuthAuthorizationServerInformation? {
    canSaveServerInformation ? lock.withLock { storedServerInformation } : nil
  }
  func saveAuthorizationServerInformation(_ information: OAuthAuthorizationServerInformation) async throws -> Bool {
    guard canSaveServerInformation else { return false }
    record("saveAuthorizationServerInformation", try JSONValue(encoding: information))
    lock.withLock { storedServerInformation = information }
    return true
  }
}

private func mask(_ calls: JSONValue) -> JSONValue {
  guard case .array(let items) = calls else { return calls }
  return .array(
    items.map { call in
      guard case .object(var object) = call else { return call }
      if object["method"] == "saveCodeVerifier" { object["value"] = "<verifier>" }
      if object["method"] == "redirectToAuthorization", let url = object["value"]?.stringValue {
        object["value"] = .string(
          url.replacingOccurrences(of: #"code_challenge=[A-Za-z0-9_-]+"#, with: "code_challenge=<challenge>", options: .regularExpression))
      }
      return .object(object)
    })
}

private func recordedBody(_ request: HTTPRequest) -> JSONValue {
  guard let body = request.body else { return .null }
  if (request.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "").contains("application/json"),
    let json = try? JSONValue(jsonData: body)
  {
    return json
  }
  return .string(String(decoding: body, as: UTF8.self))
}

@Suite struct MCPOAuthConformanceTests {
  @Test func loadsRecordedCases() {
    #expect(oauthCases.count >= 10)
  }

  @Test(arguments: oauthCases.map { $0["name"]?.stringValue ?? "" })
  func matchesUpstream(_ name: String) async throws {
    let entry = try #require(oauthCases.first { $0["name"]?.stringValue == name })
    let responses = Recorder<Int>()
    _ = responses
    let script = entry["responses"]?.objectValue ?? [:]
    let queues = Queues(script)
    let client = MockHTTPClient { request in
      guard let scripted = queues.next("\(request.method) \(request.url.absoluteString)") else {
        return .error(statusCode: 404, body: "not found")
      }
      let status = scripted["status"]?.intValue ?? 200
      if let body = scripted["body"] { return .jsonValue(body, statusCode: status) }
      return .empty(statusCode: status, headers: ["content-type": "application/json"])
    }
    let provider = try RecordingOAuthProvider(state: entry["provider"]?.objectValue ?? [:])
    let options = entry["options"]?.objectValue ?? [:]

    var result: JSONValue
    do {
      let value = try await auth(
        provider,
        OAuthOptions(
          serverURL: entry["serverUrl"]?.stringValue ?? "", authorizationCode: options["authorizationCode"]?.stringValue,
          callbackState: options["callbackState"]?.stringValue, callbackIssuer: options["callbackIssuer"]?.stringValue,
          scope: options["scope"]?.stringValue,
          resourceMetadataURL: options["resourceMetadataUrl"]?.stringValue.flatMap(URL.init(string:)), httpClient: client))
      result = ["value": .string(value.rawValue)]
    } catch {
      result = ["error": .string((error as? any AISDKError)?.message ?? String(describing: error))]
    }

    let requests: [JSONValue] = client.requests.map { request in
      [
        "method": .string(request.method), "url": .string(request.url.absoluteString),
        "headers": .object(
          Dictionary(
            request.headers.filter { $0.key.lowercased() != "user-agent" }.map { ($0.key.lowercased(), JSONValue.string($0.value)) },
            uniquingKeysWith: { _, last in last })),
        "body": recordedBody(request),
      ]
    }

    let expectedResult = entry["result"] ?? .null
    if let upstreamError = expectedResult["error"]?.stringValue, upstreamError.hasPrefix("[") {
      #expect(result["error"] != nil, "\(name): expected a validation error, got \(result.jsonString())")
    } else {
      report(name, "result", UpstreamConformance.differences(expectedResult, result))
    }
    report(name, "requests", UpstreamConformance.differences(entry["requests"] ?? [], .array(requests)))
    report(name, "calls", UpstreamConformance.differences(mask(entry["calls"] ?? []), mask(.array(provider.calls))))
  }

  private func report(_ name: String, _ label: String, _ diff: [String]) {
    guard !diff.isEmpty else { return }
    let details = diff.prefix(15).joined(separator: "\n")
    Issue.record(Comment(rawValue: "\(name) \(label): \(diff.count) difference(s)\n\(details)"))
  }
}

/// Scripted responses keyed by `METHOD URL`; the last response repeats.
private final class Queues: @unchecked Sendable {
  private let lock = NSLock()
  private var queues: [String: [JSONValue]]

  init(_ script: JSONObject) {
    queues = script.mapValues { $0.arrayValue ?? [$0] }
  }

  func next(_ key: String) -> JSONValue? {
    lock.withLock {
      guard var queue = queues[key], let first = queue.first else { return nil }
      if queue.count > 1 {
        queue.removeFirst()
        queues[key] = queue
      }
      return first
    }
  }
}
