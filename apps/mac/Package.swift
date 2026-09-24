// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Caret",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "Caret",
      path: "Sources/Caret",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("EventKit"),
        .linkedFramework("ServiceManagement"),
      ]
    )
  ],
  swiftLanguageVersions: [.v5]
)
