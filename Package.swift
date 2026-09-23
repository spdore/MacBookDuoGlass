// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacBookDuoGlass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacBookDuoGlass", targets: ["MacBookDuoGlass"])
    ],
    targets: [
        .executableTarget(
            name: "MacBookDuoGlass",
            path: "Sources/MacBookDuoGlass",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
