import Testing

@testable import AISDKProviderUtils

@Suite struct IsUrlSupportedTests {
  @Test func noSupportedUrls() {
    #expect(!isUrlSupported(mediaType: "text/plain", url: "https://example.com", supportedUrls: [:]))
  }

  @Test(arguments: ["image/png-not-supported", "image/png+invalid", "image/png;invalid"])
  func doesNotMatchSimilarMediaTypes(mediaType: String) {
    #expect(
      !isUrlSupported(
        mediaType: mediaType, url: "gs://example-bucket/image", supportedUrls: ["image/png": ["^gs://"]]))
  }

  @Test func exactMediaTypeMatches() {
    let supported = ["image/png": [#"https://images\.example\.com/.+"#, #"https://another\.com/img\.png"#]]
    #expect(isUrlSupported(mediaType: "image/png", url: "https://images.example.com/cat.png", supportedUrls: supported))
    #expect(isUrlSupported(mediaType: "image/png", url: "https://another.com/img.png", supportedUrls: supported))
    #expect(!isUrlSupported(mediaType: "image/png", url: "https://other.com", supportedUrls: supported))
    #expect(!isUrlSupported(mediaType: "text/plain", url: "https://another.com/img.png", supportedUrls: supported))
  }

  @Test func wildcardAndSpecificTogether() {
    let supported = ["text/plain": [#"https://text\.com"#], "*": [#"https://any\.com"#]]
    #expect(isUrlSupported(mediaType: "text/plain", url: "https://text.com", supportedUrls: supported))
    #expect(isUrlSupported(mediaType: "text/plain", url: "https://any.com", supportedUrls: supported))
    #expect(isUrlSupported(mediaType: "image/png", url: "https://any.com", supportedUrls: supported))
    #expect(!isUrlSupported(mediaType: "text/plain", url: "https://other.com", supportedUrls: supported))
    #expect(!isUrlSupported(mediaType: "image/png", url: "https://other.com", supportedUrls: supported))
  }

  @Test func emptyUrls() {
    #expect(isUrlSupported(mediaType: "text/plain", url: "", supportedUrls: ["text/plain": [".*"]]))
    #expect(!isUrlSupported(mediaType: "text/plain", url: "", supportedUrls: ["text/plain": ["https://.+"]]))
  }

  @Test func caseInsensitivity() {
    let supported = ["text/plain": [#"https://example\.com/path"#]]
    #expect(isUrlSupported(mediaType: "TEXT/PLAIN", url: "https://example.com/path", supportedUrls: supported))
    #expect(isUrlSupported(mediaType: "text/plain", url: "https://EXAMPLE.com/path", supportedUrls: supported))
    #expect(isUrlSupported(mediaType: "text/plain", url: "https://example.com/PATH", supportedUrls: supported))
  }

  @Test func wildcardSubtypes() {
    #expect(isUrlSupported(mediaType: "image/png", url: "https://example.com", supportedUrls: ["image/*": [#"https://example\.com"#]]))
    #expect(
      isUrlSupported(
        mediaType: "image/png", url: "https://any.com",
        supportedUrls: ["image/*": [#"https://images\.com"#], "*": [#"https://any\.com"#]]))
  }

  @Test func topLevelOnlyMediaTypes() {
    #expect(isUrlSupported(mediaType: "image", url: "https://example.com/cat.png", supportedUrls: ["image/*": [#"https://example\.com/.+"#]]))
    #expect(isUrlSupported(mediaType: "image", url: "https://example.com", supportedUrls: ["*": [#"https://example\.com"#]]))
    #expect(!isUrlSupported(mediaType: "image", url: "https://example.com/cat.png", supportedUrls: ["image/png": [#"https://example\.com/.+"#]]))
    #expect(!isUrlSupported(mediaType: "image", url: "https://example.com/a.mp3", supportedUrls: ["audio/*": [#"https://example\.com/.+"#]]))
  }

  @Test func emptyPatternArrays() {
    #expect(!isUrlSupported(mediaType: "text/plain", url: "https://example.com", supportedUrls: ["text/plain": []]))
    #expect(isUrlSupported(mediaType: "text/plain", url: "https://any.com", supportedUrls: ["text/plain": [], "*": [#"https://any\.com"#]]))
    #expect(!isUrlSupported(mediaType: "text/plain", url: "https://another.com", supportedUrls: ["text/plain": [], "*": [#"https://any\.com"#]]))
  }
}
