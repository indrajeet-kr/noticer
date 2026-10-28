// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Noticer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NoticerCore", targets: ["NoticerCore"]),
        .library(name: "NoticerAgent", targets: ["NoticerAgent"]),
        .library(name: "NoticerPipeline", targets: ["NoticerPipeline"]),
    ],
    targets: [
        .target(name: "NoticerCore"),
        .target(
            name: "NoticerAgent",
            dependencies: ["NoticerCore"],
            exclude: ["GateG0Main"]
        ),
        .executableTarget(
            name: "noticer-gate-g0",
            dependencies: ["NoticerAgent"],
            path: "Sources/NoticerAgent/GateG0Main"
        ),
        .target(
            name: "NoticerPipeline",
            dependencies: ["NoticerCore", "NoticerAgent"],
            exclude: ["ReplayMain"]
        ),
        .executableTarget(
            name: "noticer-replay",
            dependencies: ["NoticerPipeline", "NoticerCore"],
            path: "Sources/NoticerPipeline/ReplayMain"
        ),
        .testTarget(name: "NoticerCoreTests", dependencies: ["NoticerCore"]),
        .testTarget(name: "NoticerAgentTests", dependencies: ["NoticerAgent"]),
        .testTarget(
            name: "NoticerPipelineTests",
            dependencies: ["NoticerPipeline", "NoticerCore", "NoticerAgent"]
        ),
    ]
)
