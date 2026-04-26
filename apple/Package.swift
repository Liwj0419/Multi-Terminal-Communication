// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "LocalLink",
  platforms: [
    .iOS(.v17),
    .macOS(.v14)
  ],
  products: [
    .library(name: "LocalLinkCore", targets: ["LocalLinkCore"]),
    .executable(name: "LocalLinkMac", targets: ["LocalLinkMac"]),
    .executable(name: "LocalLinkCoreSmokeTests", targets: ["LocalLinkCoreSmokeTests"])
  ],
  targets: [
    .target(
      name: "LocalLinkCore",
      path: "common/LocalLinkCore"
    ),
    .executableTarget(
      name: "LocalLinkMac",
      dependencies: ["LocalLinkCore"],
      path: "macos",
      exclude: ["Info.plist", "LocalLinkMac.entitlements", "Resources", "build_and_run.sh"]
    ),
    .executableTarget(
      name: "LocalLinkCoreSmokeTests",
      dependencies: ["LocalLinkCore"],
      path: "tests/LocalLinkCoreSmokeTests"
    )
  ]
)
