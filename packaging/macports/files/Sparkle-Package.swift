// swift-tools-version:5.3
// MacPorts-only shim: upstream depends on sparkle-project/Sparkle via SwiftPM,
// whose manifest declares a *remote* binaryTarget (downloads
// Sparkle-for-Swift-Package-Manager.zip at resolve time). The MacPorts build
// sandbox has no network, so the zip is a checksummed distfile instead and this
// local package points the same product name at the extracted xcframework.
import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "Sparkle",
            targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework"
        )
    ]
)
