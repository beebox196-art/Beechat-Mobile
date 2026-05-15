// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BeeChatMobile",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "BeeChatMobile",
            targets: ["BeeChatMobile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/exyte/Chat", from: "2.1.0"),
        .package(path: "../../BeeChat-v5"),
    ],
    targets: [
        .target(
            name: "BeeChatMobile",
            dependencies: [
                .product(name: "ExyteChat", package: "Chat"),
                .product(name: "BeeChatPersistence", package: "BeeChat-v5"),
                .product(name: "BeeChatGateway", package: "BeeChat-v5"),
                .product(name: "BeeChatSyncBridge", package: "BeeChat-v5"),
            ],
            path: "Sources/BeeChatMobile"),
    ]
)
