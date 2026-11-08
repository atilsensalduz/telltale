// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TelltaleCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TelltaleCore", targets: ["TelltaleCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "TelltaleCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "telltale-cli", dependencies: ["TelltaleCore"]),
        .testTarget(
            name: "TelltaleCoreTests",
            dependencies: ["TelltaleCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
