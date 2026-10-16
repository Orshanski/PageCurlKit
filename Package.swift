// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageCurlKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PageCurlKit", targets: ["PageCurlKit"])
    ],
    targets: [
        .target(name: "PageCurlKit"),
        .testTarget(name: "PageCurlKitTests", dependencies: ["PageCurlKit"]),
    ]
)
