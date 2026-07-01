// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QoderAgentRunner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "QoderRunnerApp", targets: ["QoderRunnerApp"]),
        .executable(name: "qoder-run", targets: ["QoderRunCLI"])
    ],
    targets: [
        .target(name: "QoderCore"),
        .executableTarget(
            name: "QoderRunCLI",
            dependencies: ["QoderCore"]
        ),
        .executableTarget(
            name: "QoderRunnerApp",
            dependencies: ["QoderCore"]
        )
    ]
)
