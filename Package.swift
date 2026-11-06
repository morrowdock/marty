// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// The engine is pinned to one reviewed commit. Change the pin only in a pull request that
// also updates MartyPin.engineRevision (a test compares the two).
let package = Package(
    name: "Marty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MartyEngine", targets: ["MartyEngine"]),
        .library(name: "MartyMCP", targets: ["MartyMCP"]),
        .executable(name: "marty-mcp", targets: ["marty-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/morrowdock/martygraphics.git", revision: "76104deae44a186ccf29a43db9e091f088f12103"),
    ],
    targets: [
        .target(name: "MartyEngine", dependencies: [.product(name: "MartyGraphics", package: "martygraphics")]),
        .target(name: "MartyMCP", dependencies: ["MartyEngine"]),
        .executableTarget(name: "marty-mcp", dependencies: ["MartyMCP"]),
        .testTarget(name: "MartyEngineTests", dependencies: ["MartyEngine"]),
        .testTarget(name: "MartyMCPTests", dependencies: ["MartyMCP", "marty-mcp"]),
    ],
    swiftLanguageModes: [.v5]
)
