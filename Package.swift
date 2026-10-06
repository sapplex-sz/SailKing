// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HaiwangCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "HaiwangCore", targets: ["HaiwangCore"])],
    targets: [
        .target(name: "HaiwangCore"),
        .testTarget(name: "HaiwangCoreTests", dependencies: ["HaiwangCore"])
    ]
)
