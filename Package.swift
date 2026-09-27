// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
  name: "swift-ai-sdk",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "AISDKProvider", targets: ["AISDKProvider"]),
    .library(name: "AISDKProviderUtils", targets: ["AISDKProviderUtils"]),
    .library(name: "AISDKTestUtils", targets: ["AISDKTestUtils"]),
    .library(name: "AISDK", targets: ["AISDK"]),
    .library(name: "AISDKDeepSeek", targets: ["AISDKDeepSeek"]),
    .library(name: "AISDKAnthropic", targets: ["AISDKAnthropic"]),
  ],
  targets: [
    .target(
      name: "AISDKProvider",
      swiftSettings: swiftSettings
    ),
    .target(
      name: "AISDKProviderUtils",
      dependencies: ["AISDKProvider"],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "AISDKTestUtils",
      dependencies: ["AISDKProviderUtils"],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "AISDK",
      dependencies: ["AISDKProviderUtils"],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "AISDKDeepSeek",
      dependencies: ["AISDKProviderUtils"],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "AISDKAnthropic",
      dependencies: ["AISDKProviderUtils"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKAnthropicTests",
      dependencies: ["AISDKAnthropic", "AISDK", "AISDKTestUtils"],
      resources: [.copy("Fixtures")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKLiveTests",
      dependencies: ["AISDK", "AISDKDeepSeek", "AISDKAnthropic", "AISDKTestUtils"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKDeepSeekTests",
      dependencies: ["AISDKDeepSeek", "AISDK", "AISDKTestUtils"],
      resources: [.copy("Fixtures")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKTests",
      dependencies: ["AISDK", "AISDKTestUtils"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKProviderTests",
      dependencies: ["AISDKProvider"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKProviderUtilsTests",
      dependencies: ["AISDKProviderUtils", "AISDKTestUtils"],
      swiftSettings: swiftSettings
    ),
  ]
)
