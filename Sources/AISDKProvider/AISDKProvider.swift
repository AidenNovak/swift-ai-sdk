/// The provider specification layer of swift-ai-sdk.
///
/// Every model provider implements the protocols in this module. It depends on
/// nothing but Foundation so that it can stay stable across releases.
public enum AISDKProviderInfo {
  /// Upstream `vercel/ai` commit this port tracks.
  public static let upstreamCommit = "18b2b32deeea8982bd252996b0616fd1d9730b83"
}
