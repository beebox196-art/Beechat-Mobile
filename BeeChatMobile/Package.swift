// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BeeChatMobile",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "BeeChatMobileKit",
            targets: ["BeeChatMobileKit"]),
        .library(
            name: "BeeChatUI",
            targets: ["BeeChatUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/exyte/Chat", exact: "2.7.10"),
        .package(path: "../../BeeChat-v5"),
    ],
    targets: [
        .target(
            name: "BeeChatMobileKit",
            dependencies: [
                .product(name: "BeeChatPersistence", package: "BeeChat-v5"),
                .product(name: "BeeChatGateway", package: "BeeChat-v5"),
                .product(name: "BeeChatSyncBridge", package: "BeeChat-v5"),
            ],
            path: "Sources/BeeChatMobileKit",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .target(
            name: "BeeChatUI",
            dependencies: [
                .product(name: "ExyteChat", package: "Chat"),
                .target(name: "BeeChatMobileKit"),
            ],
            path: "Sources/BeeChatUI",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
    ]
)
