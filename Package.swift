// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "zpfssh",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "zpfssh", targets: ["zpfssh"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Pure-Swift SSH/SFTP — replaces system scp/ssh/expect in SFTPService
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "zpfssh",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/zpfssh",
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"])
            ]
        )
    ]
)
