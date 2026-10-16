// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lerix_ios",
    defaultLocalization: "en",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "Lerix", targets: ["Lerix"])
    ],
    targets: [
        .target(
            name: "Lerix",
            path: "Sources/Lerix",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LerixTests", dependencies: ["Lerix"], path: "Tests/LerixTests")
    ]
)
