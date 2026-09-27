import Testing

@testable import AISDKProvider

@Test func upstreamCommitIsFullSHA() {
  #expect(AISDKProviderInfo.upstreamCommit.count == 40)
}
