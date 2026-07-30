// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SwitchBar",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SwitchBarCore", targets: ["SwitchBarCore"])],
    targets: [
        // Lógica sin UI (perfiles, Llavero, API, política de cambio): testeable y headless.
    .target(
      name: "SwitchBarCore",
      path: "Sources/SwitchBarCore",
      resources: [
        .process("Resources")
      ]
    ),
        // Ejecutable delgado (SwiftUI) que enlaza SwitchBarCore.
        .executableTarget(
            name: "SwitchBar",
            dependencies: ["SwitchBarCore"],
            path: "Sources/SwitchBar"
        ),
        .testTarget(
            name: "SwitchBarCoreTests",
            dependencies: ["SwitchBarCore"],
            path: "Tests/SwitchBarCoreTests"
        )
    ]
)
