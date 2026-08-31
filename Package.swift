// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CoreAIAgent",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CoreAIAgentRuntime", targets: ["CoreAIAgentRuntime"]),
        .executable(name: "CoreAIAgent", targets: ["CoreAIAgent"]),
        .executable(name: "coreai-agent-canary", targets: ["CoreAIAgentCanary"])
    ],
    dependencies: [
        .package(path: "Vendor/coreai-models")
    ],
    targets: [
        .target(name: "CoreAIAgentRuntime"),
        .executableTarget(
            name: "CoreAIAgent",
            dependencies: [
                "CoreAIAgentRuntime",
                .product(name: "CoreAILM", package: "coreai-models")
            ],
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        .executableTarget(
            name: "CoreAIAgentCanary",
            dependencies: [
                "CoreAIAgentRuntime",
                .product(name: "CoreAILM", package: "coreai-models")
            ]
        ),
        .testTarget(
            name: "CoreAIAgentTests",
            dependencies: ["CoreAIAgent", "CoreAIAgentRuntime"]
        )
    ]
)
