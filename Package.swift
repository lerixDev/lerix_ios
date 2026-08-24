// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lerix_ios",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Atelerix", targets: ["Atelerix"])
    ],
    targets: [
        .target(name: "Atelerix", path: "Sources/Atelerix")
    ]
)
