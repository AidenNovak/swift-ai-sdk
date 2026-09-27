import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Downloading a file failed. Mirrors upstream `DownloadError`.
public struct DownloadError: AISDKError {
  public let name = "AI_DownloadError"
  public let message: String
  public let url: String
  public let statusCode: Int?
  public let statusText: String?
  public let cause: (any Error)?

  public init(
    url: String, statusCode: Int? = nil, statusText: String? = nil, cause: (any Error)? = nil,
    message: String? = nil
  ) {
    self.url = url
    self.statusCode = statusCode
    self.statusText = statusText
    self.cause = cause
    if let message {
      self.message = message
    } else if cause == nil, let statusCode {
      self.message = "Failed to download \(url): \(statusCode) \(statusText ?? "")"
    } else {
      self.message = "Failed to download \(url): \(getErrorMessage(cause))"
    }
  }
}

/// The default download size limit (2 GiB). Mirrors upstream `DEFAULT_MAX_DOWNLOAD_SIZE`.
public let DEFAULT_MAX_DOWNLOAD_SIZE = 2 * 1024 * 1024 * 1024

private let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

private let blockedRequestHeaders: Set<String> = [
  "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade", "host", "forwarded",
  "proxy-authorization", "via", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip", "metadata",
  "metadata-flavor", "x-aws-ec2-metadata-token", "x-metadata-token", "cookie", "set-cookie",
]

private let safeUntrustedFirstHopHeaders: Set<String> = [
  "accept", "accept-language", "baggage", "cache-control", "idempotency-key", "if-match", "if-modified-since",
  "if-none-match", "if-range", "if-unmodified-since", "pragma", "range", "traceparent", "tracestate", "user-agent",
  "x-correlation-id", "x-request-id",
]

/// The `scheme://host[:port]` origin of a URL, with default ports omitted, or
/// `nil` when the URL has no host.
public func urlOrigin(_ url: String) -> String? {
  guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
    let host = components.host?.lowercased(), !host.isEmpty
  else { return nil }
  let port = components.port.flatMap { port -> Int? in
    (scheme == "http" && port == 80) || (scheme == "https" && port == 443) ? nil : port
  }
  let hostText = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
  return "\(scheme)://\(hostText)\(port.map { ":\($0)" } ?? "")"
}

/// Whether two URLs share an origin. Mirrors upstream `isSameOrigin`.
public func isSameOrigin(_ url: String, _ baseURL: String) -> Bool {
  guard let origin = urlOrigin(url) else { return false }
  return origin == urlOrigin(baseURL)
}

/// Drops hop-by-hop, proxy, cloud-metadata and cookie headers. Mirrors upstream `sanitizeRequestHeaders`.
public func sanitizeRequestHeaders(_ headers: [String: String]) -> [String: String] {
  var sanitized: [String: String] = [:]
  for (name, value) in headers where !blockedRequestHeaders.contains(name.lowercased()) {
    sanitized[name.lowercased()] = value
  }
  return sanitized
}

/// Parses an IPv4 host the way the WHATWG URL parser (and `inet_aton`) does,
/// accepting 1-4 dotted parts in decimal, octal (`0` prefix) or hex (`0x`).
func parseIPv4Host(_ host: String) -> [Int]? {
  var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
  if parts.last == "" { parts.removeLast() }
  guard (1...4).contains(parts.count) else { return nil }
  var numbers: [Int] = []
  for part in parts {
    guard !part.isEmpty else { return nil }
    let value: Int?
    if part.lowercased().hasPrefix("0x") {
      value = part.count == 2 ? 0 : Int(part.dropFirst(2), radix: 16)
    } else if part.count > 1, part.hasPrefix("0") {
      value = Int(part.dropFirst(), radix: 8)
    } else {
      value = Int(part, radix: 10)
    }
    guard let value, value >= 0 else { return nil }
    numbers.append(value)
  }
  let last = numbers.removeLast()
  guard numbers.allSatisfy({ $0 <= 255 }) else { return nil }
  let remainingBytes = 4 - numbers.count
  guard last < 1 << (8 * remainingBytes) else { return nil }
  var bytes = numbers
  for shift in stride(from: 8 * (remainingBytes - 1), through: 0, by: -8) {
    bytes.append((last >> shift) & 0xFF)
  }
  return bytes
}

private func isPrivateIPv4(_ bytes: [Int]) -> Bool {
  let (a, b, c) = (bytes[0], bytes[1], bytes[2])
  if a == 0 || a == 10 || a == 127 || a >= 224 { return true }
  if a == 100 && (64...127).contains(b) { return true }
  if a == 169 && b == 254 { return true }
  if a == 172 && (16...31).contains(b) { return true }
  if a == 192 && b == 0 && (c == 0 || c == 2) { return true }
  if a == 192 && b == 168 { return true }
  if a == 198 && (b == 18 || b == 19) { return true }
  if a == 198 && b == 51 && c == 100 { return true }
  if a == 203 && b == 0 && c == 113 { return true }
  return false
}

private func parseIPv6(_ ip: String) -> [Int]? {
  var address = ip.lowercased()
  if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
  let halves = address.components(separatedBy: "::")
  guard halves.count <= 2 else { return nil }

  func groups(_ segment: String) -> [Int]? {
    if segment.isEmpty { return [] }
    let parts = segment.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    var result: [Int] = []
    for (index, part) in parts.enumerated() {
      if part.contains(".") {
        guard index == parts.count - 1, let bytes = parseIPv4Host(part), part.split(separator: ".").count == 4 else {
          return nil
        }
        result.append(bytes[0] << 8 | bytes[1])
        result.append(bytes[2] << 8 | bytes[3])
        continue
      }
      guard (1...4).contains(part.count), let value = Int(part, radix: 16) else { return nil }
      result.append(value)
    }
    return result
  }

  guard let head = groups(halves[0]) else { return nil }
  if halves.count == 2 {
    guard let tail = groups(halves[1]) else { return nil }
    let fill = 8 - head.count - tail.count
    guard fill >= 0 else { return nil }
    return head + Array(repeating: 0, count: fill) + tail
  }
  return head.count == 8 ? head : nil
}

private func isPrivateIPv6(_ ip: String) -> Bool {
  guard let groups = parseIPv6(ip) else { return true }
  func topZero(_ count: Int) -> Bool { groups.prefix(count).allSatisfy { $0 == 0 } }
  if topZero(7) && (groups[7] == 0 || groups[7] == 1) { return true }
  if groups[0] & 0xFE00 == 0xFC00 { return true }
  if groups[0] & 0xFFC0 == 0xFE80 { return true }
  if groups[0] & 0xFFC0 == 0xFEC0 { return true }
  if groups[0] & 0xFF00 == 0xFF00 { return true }
  if groups[0] == 0x2001 && groups[1] == 0x0DB8 { return true }
  if groups[0] == 0x3FFF && groups[1] & 0xF000 == 0 { return true }
  let embedsIPv4 =
    topZero(6) || (topZero(5) && groups[5] == 0xFFFF) || (topZero(4) && groups[4] == 0xFFFF && groups[5] == 0)
    || (groups[0] == 0x0064 && groups[1] == 0xFF9B && groups[2...5].allSatisfy { $0 == 0 })
    || (groups[0] == 0x0064 && groups[1] == 0xFF9B && groups[2] == 0x0001)
  if embedsIPv4 {
    return isPrivateIPv4([groups[6] >> 8 & 0xFF, groups[6] & 0xFF, groups[7] >> 8 & 0xFF, groups[7] & 0xFF])
  }
  return false
}

/// Rejects URLs that could reach local or private networks (SSRF). Mirrors
/// upstream `validateDownloadUrl`; numeric IPv4 hosts are normalized first.
///
/// - Throws: `DownloadError` for disallowed URLs.
public func validateDownloadUrl(_ url: String) throws {
  guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else {
    throw DownloadError(url: url, message: "Invalid URL: \(url)")
  }
  if scheme == "data" { return }
  guard scheme == "http" || scheme == "https" else {
    throw DownloadError(url: url, message: "URL scheme must be http, https, or data, got \(scheme):")
  }
  var hostname = (components.host ?? "").lowercased()
  while hostname.hasSuffix(".") { hostname.removeLast() }
  guard !hostname.isEmpty else { throw DownloadError(url: url, message: "URL must have a hostname") }
  if hostname == "localhost" || hostname.hasSuffix(".local") || hostname.hasSuffix(".localhost") {
    throw DownloadError(url: url, message: "URL with hostname \(hostname) is not allowed")
  }
  let bare = hostname.hasPrefix("[") && hostname.hasSuffix("]") ? String(hostname.dropFirst().dropLast()) : hostname
  if bare.contains(":") {
    if isPrivateIPv6(bare) {
      throw DownloadError(url: url, message: "URL with IPv6 address [\(bare)] is not allowed")
    }
    return
  }
  if let bytes = parseIPv4Host(bare), isPrivateIPv4(bytes) {
    throw DownloadError(url: url, message: "URL with IP address \(hostname) is not allowed")
  }
}

/// Fetches a URL, validating every redirect hop against `validateDownloadUrl`
/// and dropping caller headers (except `user-agent`) on cross-origin hops.
/// Mirrors upstream `fetchWithValidatedRedirects`.
///
/// - Parameter trustedOrigin: The developer-configured origin, exempt from validation.
public func fetchWithValidatedRedirects(
  url: String, headers: [String: String]? = nil, maxRedirects: Int = 10,
  httpClient: (any HTTPClient)? = nil, trustedOrigin: String? = nil
) async throws -> HTTPResponse {
  var currentHeaders = headers.map(sanitizeRequestHeaders)
  var currentURL = url
  for _ in 0...maxRedirects {
    let isTrustedHop = trustedOrigin.map { isSameOrigin(currentURL, $0) } ?? false
    if !isTrustedHop { try validateDownloadUrl(currentURL) }
    guard let requestURL = URL(string: currentURL) else {
      throw DownloadError(url: currentURL, message: "Invalid URL: \(currentURL)")
    }
    let response = try await (httpClient ?? defaultHTTPClient).send(
      HTTPRequest(method: "GET", url: requestURL, headers: currentHeaders ?? [:], redirect: .manual))
    guard redirectStatusCodes.contains(response.statusCode), let location = response.headers["location"],
      let nextURL = URL(string: location, relativeTo: requestURL)?.absoluteString
    else { return response }
    if currentHeaders != nil, !isSameOrigin(nextURL, currentURL) {
      currentHeaders = currentHeaders?["user-agent"].map { ["user-agent": $0] } ?? [:]
    }
    currentURL = nextURL
  }
  throw DownloadError(url: url, message: "Too many redirects (max \(maxRedirects))")
}

/// Fetches an untrusted URL, forwarding only non-credential headers unless
/// the URL is on `credentialedOrigin` (or `trustedOrigin`). Mirrors upstream `fetchUntrustedUrl`.
public func fetchUntrustedUrl(
  url: String, headers: [String: String]? = nil, credentialedOrigin: String? = nil,
  untrustedFirstHopHeaders: [String] = [], trustedOrigin: String? = nil, httpClient: (any HTTPClient)? = nil
) async throws -> HTTPResponse {
  var firstHopHeaders = headers.map(sanitizeRequestHeaders)
  if let current = firstHopHeaders {
    let origin = credentialedOrigin ?? trustedOrigin
    if origin == nil || !isSameOrigin(url, origin ?? "") {
      let allowed = safeUntrustedFirstHopHeaders.union(untrustedFirstHopHeaders.map { $0.lowercased() })
      firstHopHeaders = current.filter { allowed.contains($0.key) }
    }
  }
  return try await fetchWithValidatedRedirects(
    url: url, headers: firstHopHeaders, httpClient: httpClient, trustedOrigin: trustedOrigin)
}

/// Sends a request to an endpoint derived from untrusted metadata, validating
/// it unless it is on `trustedOrigin`, and never following redirects.
/// Mirrors upstream `fetchWithValidatedEndpoint`.
public func fetchWithValidatedEndpoint(
  _ request: HTTPRequest, httpClient: (any HTTPClient)? = nil, trustedOrigin: String? = nil,
  redirect: HTTPRedirectMode = .error
) async throws -> HTTPResponse {
  let urlText = request.url.absoluteString
  if !(trustedOrigin.map { isSameOrigin(urlText, $0) } ?? false) {
    try validateDownloadUrl(urlText)
  }
  var request = request
  request.redirect = redirect
  return try await (httpClient ?? defaultHTTPClient).send(request)
}

/// Reads a response body, failing once it exceeds `maxBytes`. Mirrors upstream `readResponseWithSizeLimit`.
public func readResponseWithSizeLimit(
  _ response: HTTPResponse, url: String, maxBytes: Int = DEFAULT_MAX_DOWNLOAD_SIZE
) async throws -> Data {
  if let length = response.headers["content-length"].flatMap({ Int($0) }), length > maxBytes {
    throw DownloadError(
      url: url, message: "Download of \(url) exceeded maximum size of \(maxBytes) bytes (Content-Length: \(length)).")
  }
  var data = Data()
  for try await chunk in response.body {
    data.append(chunk)
    if data.count > maxBytes {
      throw DownloadError(url: url, message: "Download of \(url) exceeded maximum size of \(maxBytes) bytes.")
    }
  }
  return data
}
