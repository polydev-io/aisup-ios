// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AISUPSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AISUPSDK",
            targets: ["AISUPSDK"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", .upToNextMinor(from: "16.1.0")),
    ],
    targets: [
        .target(
            name: "AISUPSDK",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ],
            path: "Sources/AISUPSDK"
        ),
        .testTarget(
            name: "AISUPSDKTests",
            dependencies: ["AISUPSDK"],
            path: "Tests/AISUPSDKTests"
        ),
    ]
)
