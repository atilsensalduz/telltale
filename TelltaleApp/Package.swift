// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TelltaleApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TelltaleCore"),
    ],
    targets: [
        .executableTarget(
            name: "Telltale",
            dependencies: [.product(name: "TelltaleCore", package: "TelltaleCore")]
        ),
    ]
)
