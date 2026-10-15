// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ActivityAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ActivityAgent", targets: ["ActivityApp"]), .executable(name: "ActivityMCP", targets: ["ActivityMCP"])],
    targets: [
        .target(name: "CActivity", publicHeadersPath: "include"),
        .target(name: "ActivityCore", dependencies: ["CActivity"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "ActivityApp", dependencies: ["ActivityCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "ActivityMCP", dependencies: ["ActivityCore"], linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "ActivityCoreTests", dependencies: ["ActivityCore"])
    ],
    swiftLanguageModes: [.v5]
)
