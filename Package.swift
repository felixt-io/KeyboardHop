// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyboardHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeyboardHop",
            path: "Sources/KeyboardHop",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        )
    ]
)
