// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let rustArchive = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("rust/biblatex-bridge/target/debug/libtinyrefs_biblatex.a")
    .path

let package = Package(
    name: "TinyRefs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TinyRefs", targets: ["TinyRefs"]),
        .executable(name: "tinyrefs", targets: ["TinyRefsCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CBibLaTeX"),
        .target(
            name: "TinyRefs",
            dependencies: ["CBibLaTeX"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", rustArchive]),
            ],
        ),
        .executableTarget(name: "TinyRefsCLI", dependencies: ["TinyRefs"]),
        .testTarget(
            name: "TinyRefsTests",
            dependencies: ["TinyRefs"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
