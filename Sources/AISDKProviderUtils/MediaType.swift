import Foundation

/// Whether the media type has a subtype (`image/png`), as opposed to only a
/// top-level segment (`image`). Mirrors upstream `isFullMediaType`.
public func isFullMediaType(_ mediaType: String) -> Bool {
  let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
  return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && parts[1] != "*"
}

/// The top-level segment of a media type (`image` for `image/png`).
/// Mirrors upstream `getTopLevelMediaType`.
public func getTopLevelMediaType(_ mediaType: String) -> String {
  String(mediaType.split(separator: "/", maxSplits: 1).first ?? Substring(mediaType)).lowercased()
}

private struct MediaTypeSignature {
  let mediaType: String
  let bytesPrefix: [UInt8?]
}

private let imageSignatures: [MediaTypeSignature] = [
  .init(mediaType: "image/gif", bytesPrefix: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]),
  .init(mediaType: "image/gif", bytesPrefix: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
  .init(mediaType: "image/png", bytesPrefix: [0x89, 0x50, 0x4E, 0x47]),
  .init(mediaType: "image/jpeg", bytesPrefix: [0xFF, 0xD8]),
  .init(mediaType: "image/webp", bytesPrefix: [0x52, 0x49, 0x46, 0x46, nil, nil, nil, nil, 0x57, 0x45, 0x42, 0x50]),
  .init(mediaType: "image/bmp", bytesPrefix: [0x42, 0x4D, nil, nil, nil, nil, 0x00, 0x00, 0x00, 0x00]),
  .init(mediaType: "image/tiff", bytesPrefix: [0x49, 0x49, 0x2A, 0x00]),
  .init(mediaType: "image/tiff", bytesPrefix: [0x4D, 0x4D, 0x00, 0x2A]),
  .init(
    mediaType: "image/avif", bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66]),
  .init(
    mediaType: "image/heic", bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]),
]

private let documentSignatures: [MediaTypeSignature] = [
  .init(mediaType: "application/pdf", bytesPrefix: [0x25, 0x50, 0x44, 0x46])
]

private let audioSignatures: [MediaTypeSignature] = [
  .init(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF0]),
  .init(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF1]),
  .init(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF8]),
  .init(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF9]),
  .init(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xFB]),
  .init(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xFA]),
  .init(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xF3]),
  .init(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xF2]),
  .init(mediaType: "audio/mpeg", bytesPrefix: [0x49, 0x44, 0x33]),
  .init(mediaType: "audio/wav", bytesPrefix: [0x52, 0x49, 0x46, 0x46, nil, nil, nil, nil, 0x57, 0x41, 0x56, 0x45]),
  .init(mediaType: "audio/ogg", bytesPrefix: [0x4F, 0x67, 0x67, 0x53]),
  .init(mediaType: "audio/flac", bytesPrefix: [0x66, 0x4C, 0x61, 0x43]),
  .init(mediaType: "audio/webm", bytesPrefix: [0x1A, 0x45, 0xDF, 0xA3]),
]

/// Detects a media type from the leading bytes. Mirrors upstream `detectMediaType`.
///
/// - Parameter topLevelType: Restricts detection to `image`, `audio` or
///   `application` signatures; `nil` checks all of them.
public func detectMediaType(data: Data, topLevelType: String? = nil) -> String? {
  let signatures: [MediaTypeSignature] =
    switch topLevelType {
    case "image": imageSignatures
    case "audio": audioSignatures
    case "application": documentSignatures
    default: imageSignatures + documentSignatures + audioSignatures
    }
  let bytes = [UInt8](data.prefix(16))
  for signature in signatures where bytes.count >= signature.bytesPrefix.count {
    let matches = signature.bytesPrefix.enumerated().allSatisfy { index, byte in
      byte == nil || bytes[index] == byte
    }
    if matches { return signature.mediaType }
  }
  return nil
}

/// Detects a media type from base64 text by decoding its first bytes.
public func detectMediaType(base64: String, topLevelType: String? = nil) -> String? {
  let prefix = String(base64.prefix(24))
  guard let data = convertBase64ToData(prefix) else { return nil }
  return detectMediaType(data: data, topLevelType: topLevelType)
}
