// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacAgent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macagent", targets: ["macagent"]),
        .executable(name: "MacAgentMenu", targets: ["MacAgentMenu"]),
    ],
    targets: [
        .target(
            name: "MacAgentCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "macagent",
            dependencies: ["MacAgentCore"]
        ),
        .executableTarget(
            name: "MacAgentMenu",
            dependencies: ["MacAgentCore"]
        ),
        .testTarget(
            name: "MacAgentCoreTests",
            dependencies: ["MacAgentCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
