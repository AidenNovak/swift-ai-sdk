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
  ],
  targets: [
    .target(
      name: "AISDKProvider",
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "AISDKProviderTests",
      dependencies: ["AISDKProvider"],
      swiftSettings: swiftSettings
    ),
  ]
)
