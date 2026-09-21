// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CacaoTransCore",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "CacaoTransCore", targets: ["CacaoTransCore"]),
    ],
    targets: [
        .target(name: "CacaoTransCore"),
        .testTarget(name: "CacaoTransCoreTests", dependencies: ["CacaoTransCore"]),
    ]
)
