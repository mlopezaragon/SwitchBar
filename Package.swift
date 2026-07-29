// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ClaudeSwitchCore", targets: ["ClaudeSwitchCore"])],
    targets: [
        // Lógica sin UI (perfiles, Llavero, API, política de cambio): testeable y headless.
        .target(
            name: "ClaudeSwitchCore",
            path: "Sources/ClaudeSwitchCore"
        ),
        // Ejecutable delgado (SwiftUI) que enlaza ClaudeSwitchCore.
        .executableTarget(
            name: "ClaudeSwitch",
            dependencies: ["ClaudeSwitchCore"],
            path: "Sources/ClaudeSwitch"
        ),
        .testTarget(
            name: "ClaudeSwitchCoreTests",
            dependencies: ["ClaudeSwitchCore"],
            path: "Tests/ClaudeSwitchCoreTests"
        )
    ]
)
