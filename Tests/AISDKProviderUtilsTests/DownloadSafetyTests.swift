import AISDKTestUtils
import Foundation
import Testing

@testable import AISDKProviderUtils

private let allowedURLs = [
  "https://example.com/image.png",
  "http://example.com/image.png",
  "https://8.8.8.8/file",
  "https://example.com:8080/file",
  "data:text/plain;base64,aGVsbG8=",
  "http://172.15.0.1/file",
  "http://172.32.0.1/file",
  "http://192.0.3.1/file",
  "http://198.51.101.1/file",
  "http://203.0.114.1/file",
  "http://[3fff:1000::1]/file",
  "http://[::ffff:8.8.8.8]/file",
  "https://example.com./image.png",
  "http://[64:ff9b::8.8.8.8]/file",
  "http://[2606:4700::1]/file",
  "http://100.63.0.1/file",
  "http://100.128.0.1/file",
]

private let blockedURLs = [
  "file:///etc/passwd",
  "ftp://example.com/file",
  "javascript:alert(1)",
  "not-a-url",
  "http://localhost/file",
  "http://localhost:3000/file",
  "http://myhost.local/file",
  "http://app.localhost/file",
  "http://127.0.0.1/file",
  "http://127.255.0.1/file",
  "http://10.0.0.1/file",
  "http://172.16.0.1/file",
  "http://172.31.255.255/file",
  "http://192.168.1.1/file",
  "http://169.254.169.254/latest/meta-data/",
  "http://0.0.0.0/file",
  "http://224.0.0.1/file",
  "http://239.255.255.250/file",
  "http://192.0.2.1/file",
  "http://198.51.100.1/file",
  "http://203.0.113.1/file",
  "http://[::1]/file",
  "http://[::]/file",
  "http://[fc00::1]/file",
  "http://[fd12::1]/file",
  "http://[fe80::1]/file",
  "http://[2001:db8::1]/file",
  "http://[3fff::1]/file",
  "http://[3fff:fff::1]/file",
  "http://[::ffff:127.0.0.1]/file",
  "http://[::ffff:10.0.0.1]/file",
  "http://[::ffff:169.254.169.254]/file",
  "http://localhost./file",
  "http://myhost.local./file",
  "http://app.localhost./file",
  "http://2130706433/file",
  "http://0x7f000001/file",
  "http://0177.0.0.1/file",
  "http://[::127.0.0.1]/file",
  "http://[::ffff:0:127.0.0.1]/file",
  "http://[64:ff9b::127.0.0.1]/file",
  "http://[64:ff9b::169.254.169.254]/file",
  "http://[64:ff9b:1::169.254.169.254]/file",
  "http://100.64.0.1/file",
  "http://100.127.255.255/file",
  "http://198.18.0.1/file",
  "http://198.19.255.255/file",
  "http://192.0.0.1/file",
  "http://240.0.0.1/file",
  "http://255.255.255.255/file",
  "http://[fec0::1]/file",
  "http://[ff02::1]/file",
]

@Suite struct ValidateDownloadUrlTests {
  @Test(arguments: allowedURLs)
  func allows(_ url: String) throws {
    try validateDownloadUrl(url)
  }

  @Test(arguments: blockedURLs)
  func blocks(_ url: String) {
    #expect(throws: DownloadError.self) { try validateDownloadUrl(url) }
  }

  @Test func parsesNumericIPv4LikeWHATWG() {
    #expect(parseIPv4Host("2130706433") == [127, 0, 0, 1])
    #expect(parseIPv4Host("0x7f000001") == [127, 0, 0, 1])
    #expect(parseIPv4Host("0177.0.0.1") == [127, 0, 0, 1])
    #expect(parseIPv4Host("127.1") == [127, 0, 0, 1])
    #expect(parseIPv4Host("example.com") == nil)
    #expect(parseIPv4Host("256.0.0.1") == nil)
  }

  @Test func comparesOrigins() {
    #expect(isSameOrigin("https://a.com/x", "https://a.com:443/y"))
    #expect(!isSameOrigin("https://a.com/x", "http://a.com/x"))
    #expect(!isSameOrigin("https://a.com/x", "https://b.a.com/x"))
    #expect(!isSameOrigin("not a url", "https://a.com"))
  }

  @Test func sanitizesHeaders() {
    #expect(
      sanitizeRequestHeaders(["Cookie": "a", "Host": "x", "Authorization": "Bearer t", "X-Forwarded-For": "1"])
        == ["authorization": "Bearer t"])
  }
}

@Suite struct ValidatedFetchTests {
  @Test func followsRedirectsAndValidatesEachHop() async throws {
    let client = MockHTTPClient([
      "https://a.com/start": .empty(statusCode: 302, headers: ["location": "/next"]),
      "https://a.com/next": .empty(statusCode: 301, headers: ["location": "https://b.com/file"]),
      "https://b.com/file": .binary(Data("ok".utf8)),
    ])
    let response = try await fetchWithValidatedRedirects(
      url: "https://a.com/start", headers: ["authorization": "Bearer t", "user-agent": "ua"], httpClient: client)
    #expect(try await response.bodyText() == "ok")
    #expect(client.requests.map(\.url.absoluteString) == ["https://a.com/start", "https://a.com/next", "https://b.com/file"])
    #expect(client.requests.allSatisfy { $0.redirect == .manual })
    #expect(client.requests[1].headers["authorization"] == "Bearer t")
    #expect(client.requests[2].headers == ["user-agent": "ua"])
  }

  @Test func blocksRedirectsToPrivateNetworks() async throws {
    let client = MockHTTPClient([
      "https://a.com/start": .empty(statusCode: 302, headers: ["location": "http://169.254.169.254/latest/meta-data/"])
    ])
    await #expect(throws: DownloadError.self) {
      _ = try await fetchWithValidatedRedirects(url: "https://a.com/start", httpClient: client)
    }
    #expect(client.requests.count == 1)
  }

  @Test func trustsConfiguredOrigin() async throws {
    let client = MockHTTPClient(["http://localhost:8080/x": .binary(Data("local".utf8))])
    let response = try await fetchWithValidatedRedirects(
      url: "http://localhost:8080/x", httpClient: client, trustedOrigin: "http://localhost:8080")
    #expect(try await response.bodyText() == "local")
  }

  @Test func limitsRedirectCount() async throws {
    let client = MockHTTPClient(["https://a.com/loop": .empty(statusCode: 302, headers: ["location": "/loop"])])
    await #expect {
      _ = try await fetchWithValidatedRedirects(url: "https://a.com/loop", maxRedirects: 3, httpClient: client)
    } throws: { error in
      (error as? DownloadError)?.message == "Too many redirects (max 3)"
    }
    #expect(client.requests.count == 4)
  }

  @Test func stripsCredentialHeadersForUntrustedFirstHop() async throws {
    let client = MockHTTPClient(["https://c.com/f": .binary(Data())])
    _ = try await fetchUntrustedUrl(
      url: "https://c.com/f", headers: ["x-api-key": "secret", "accept": "*/*", "mcp-protocol-version": "1"],
      untrustedFirstHopHeaders: ["MCP-Protocol-Version"], httpClient: client)
    #expect(client.lastRequest?.headers == ["accept": "*/*", "mcp-protocol-version": "1"])
    _ = try await fetchUntrustedUrl(
      url: "https://c.com/f", headers: ["x-api-key": "secret"], credentialedOrigin: "https://c.com", httpClient: client)
    #expect(client.lastRequest?.headers == ["x-api-key": "secret"])
  }

  @Test func enforcesSizeLimit() async throws {
    let client = MockHTTPClient([
      "https://a.com/big": .binary(Data(repeating: 1, count: 10)),
      "https://a.com/declared": .binary(Data(), headers: ["content-length": "100"]),
    ])
    await #expect(throws: DownloadError.self) {
      _ = try await readResponseWithSizeLimit(
        try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://a.com/big")!)), url: "big", maxBytes: 5)
    }
    await #expect {
      _ = try await readResponseWithSizeLimit(
        try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://a.com/declared")!)), url: "declared",
        maxBytes: 50)
    } throws: { error in
      (error as? DownloadError)?.message.contains("Content-Length: 100") == true
    }
  }

  @Test func validatesEndpointsAndDisallowsRedirects() async throws {
    let client = MockHTTPClient(["https://auth.example.com/token": .jsonValue(["ok": true])])
    _ = try await fetchWithValidatedEndpoint(
      HTTPRequest(method: "POST", url: URL(string: "https://auth.example.com/token")!), httpClient: client)
    #expect(client.lastRequest?.redirect == .error)
    await #expect(throws: DownloadError.self) {
      _ = try await fetchWithValidatedEndpoint(
        HTTPRequest(method: "POST", url: URL(string: "http://10.0.0.5/token")!), httpClient: client)
    }
  }
}
