// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wispr-flow-switch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "wispr-flow-switch",
            targets: ["WisprFlowSwitch"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WisprFlowSwitch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
