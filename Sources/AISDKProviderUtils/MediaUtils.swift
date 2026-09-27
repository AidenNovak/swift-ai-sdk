import Foundation

/// Decodes base64 or base64url text. Mirrors upstream `convertBase64ToUint8Array`.
public func convertBase64ToData(_ base64String: String) -> Data? {
  var normalized = base64String
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  let remainder = normalized.count % 4
  if remainder > 0 {
    normalized += String(repeating: "=", count: 4 - remainder)
  }
  return Data(base64Encoded: normalized)
}

/// Encodes bytes as base64. Mirrors upstream `convertUint8ArrayToBase64`.
public func convertDataToBase64(_ data: Data) -> String {
  data.base64EncodedString()
}

/// Whether the model supports the URL natively for the media type.
/// Mirrors upstream `isUrlSupported`.
///
/// `supportedUrls` maps media type patterns (`*`, `*/*`, `image/*`,
/// `application/pdf`) to regular expression sources.
public func isUrlSupported(mediaType: String, url: String, supportedUrls: [String: [String]]) -> Bool {
  let url = url.lowercased()
  let mediaType = mediaType.lowercased()
  let isTopLevelOnly = !mediaType.contains("/")

  return supportedUrls.contains { key, patterns in
    let key = key.lowercased()
    let prefix: String
    if key == "*" || key == "*/*" {
      prefix = ""
    } else if let star = key.firstIndex(of: "*") {
      prefix = key.replacingCharacters(in: star...star, with: "")
    } else {
      prefix = key
    }

    let mediaTypeMatches: Bool
    if prefix.isEmpty {
      mediaTypeMatches = true
    } else if isTopLevelOnly {
      mediaTypeMatches = "\(mediaType)/" == prefix
    } else if prefix.hasSuffix("/") {
      mediaTypeMatches = mediaType.hasPrefix(prefix)
    } else {
      mediaTypeMatches = mediaType == prefix
    }
    guard mediaTypeMatches else { return false }

    return patterns.contains { pattern in
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
      return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
  }
}
