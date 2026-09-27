// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacChat",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "MacChat",
      dependencies: [
        .product(name: "AISDK", package: "swift-ai-sdk"),
        .product(name: "AISDKUI", package: "swift-ai-sdk"),
        .product(name: "AISDKDeepSeek", package: "swift-ai-sdk"),
      ]
    )
  ]
)
