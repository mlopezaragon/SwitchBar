// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SwitchBar",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SwitchBarCore", targets: ["SwitchBarCore"])],
    dependencies: [
        // Actualizaciones automáticas. Binario oficial firmado por el
        // proyecto Sparkle; el framework se embebe en la app al ensamblar.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.6.0"
        )
    ],
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
            dependencies: [
                "SwitchBarCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SwitchBar"
        ),
        .testTarget(
            name: "SwitchBarCoreTests",
            dependencies: ["SwitchBarCore"],
            path: "Tests/SwitchBarCoreTests"
        )
    ]
)
