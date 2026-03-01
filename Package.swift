// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Synchro",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "Synchro", targets: ["Synchro"])
    ],
    targets: [
        .executableTarget(
            name: "Synchro",
            path: "Sources/Synchro",
            exclude: ["Synchro.entitlements"],
            resources: [
                .process("Assets.xcassets"),
                .copy("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
