// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CacaoTransEngine",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CacaoTransEngine", targets: ["CacaoTransEngine"]),
    ],
    dependencies: [
        .package(path: "../CacaoTransCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "CacaoTransEngine",
            dependencies: [
                "CacaoTransCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
