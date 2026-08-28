// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QwenCoreAI",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "QwenAgentRuntime", targets: ["QwenAgentRuntime"]),
        .executable(name: "QwenCoreAI", targets: ["QwenCoreAI"]),
        .executable(name: "qwen-canary", targets: ["QwenCoreAICanary"])
    ],
    dependencies: [
        .package(path: "Vendor/coreai-models")
    ],
    targets: [
        .target(name: "QwenAgentRuntime"),
        .executableTarget(
            name: "QwenCoreAI",
            dependencies: [
                "QwenAgentRuntime",
                .product(name: "CoreAILM", package: "coreai-models")
            ],
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        .executableTarget(
            name: "QwenCoreAICanary",
            dependencies: [
                "QwenAgentRuntime",
                .product(name: "CoreAILM", package: "coreai-models")
            ]
        ),
        .testTarget(
            name: "QwenCoreAITests",
            dependencies: ["QwenCoreAI", "QwenAgentRuntime"]
        )
    ]
)
