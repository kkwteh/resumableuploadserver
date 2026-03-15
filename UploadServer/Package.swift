// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "UploadServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../BuildingAResumableUploadServerWithSwiftNIO"),
        .package(path: "../BuildingAResumableUploadServerWithSwiftNIO/Dependencies/swift-http-types"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.53.0"),
    ],
    targets: [
        .executableTarget(
            name: "UploadServer",
            dependencies: [
                .product(name: "NIOResumableUpload", package: "BuildingAResumableUploadServerWithSwiftNIO"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesNIO", package: "swift-http-types"),
                .product(name: "HTTPTypesNIOHTTP1", package: "swift-http-types"),
            ]
        ),
    ]
)
