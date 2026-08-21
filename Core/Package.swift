// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenConnectCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenConnectDSP", targets: ["OpenConnectDSP"]),
        .library(name: "OpenConnectDSPShim", targets: ["OpenConnectDSPShim"]),
    ],
    targets: [
        .target(
            name: "OpenConnectDSP",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("OC_REALTIME_CORE", to: "1"),
                .unsafeFlags(["-fno-exceptions", "-fno-rtti"])
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "OpenConnectDSPShim",
            dependencies: ["OpenConnectDSP"]
        ),
        .testTarget(
            name: "OpenConnectDSPTests",
            dependencies: ["OpenConnectDSPShim"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
