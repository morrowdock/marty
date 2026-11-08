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
        .library(name: "MartyLoop", targets: ["MartyLoop"]),
        .executable(name: "marty", targets: ["marty"]),
    ],
    dependencies: [
        .package(url: "https://github.com/morrowdock/martygraphics.git", revision: "d0e59443916065faaec9a22fd1226dc923fbc3ea"),
    ],
    targets: [
        .target(name: "MartyEngine", dependencies: [.product(name: "MartyGraphics", package: "martygraphics")]),
        .target(name: "MartyMCP", dependencies: ["MartyEngine"]),
        .executableTarget(name: "marty-mcp", dependencies: ["MartyMCP"]),
        .target(name: "MartyLoop", dependencies: ["MartyEngine"]),
        .executableTarget(name: "marty", dependencies: ["MartyLoop"]),
        .testTarget(name: "MartyLoopTests", dependencies: ["MartyLoop", .product(name: "MartyGraphics", package: "martygraphics")]),
        .testTarget(name: "MartyEngineTests", dependencies: ["MartyEngine", .product(name: "MartyGraphics", package: "martygraphics")]),
        .testTarget(name: "MartyMCPTests", dependencies: ["MartyMCP", "marty-mcp"]),
    ],
    swiftLanguageModes: [.v5]
)
