// swift-tools-version:5.9
// VolaiSDK — iOS client for the Volai SDK contract (docs/voice-ws-protocol.md).
// The manifest lives at the repository root so Swift Package Manager can
// resolve `https://github.com/Globitel/volai-sdk`; the sources are under ios/.
import PackageDescription

let package = Package(
    name: "VolaiSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "VolaiSDK", targets: ["VolaiSDK"]),
    ],
    targets: [
        .target(
            name: "VolaiSDK",
            path: "ios/Sources/VolaiSDK"
        ),
        .testTarget(
            name: "VolaiSDKTests",
            dependencies: ["VolaiSDK"],
            path: "ios/Tests/VolaiSDKTests"
        ),
    ]
)
