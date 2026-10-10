// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "volai_sdk",
    platforms: [.iOS("15.0")],
    products: [.library(name: "volai-sdk", targets: ["volai_sdk"])],
    targets: [
        .target(name: "volai_sdk", dependencies: [], path: "Sources/volai_sdk")
    ]
)
