// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lerix_ios",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "Lerix", targets: ["Lerix"])
    ],
    targets: [
        .target(name: "Lerix", path: "Sources/Lerix")
    ]
)
