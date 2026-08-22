// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenConnctCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenConnctDSP", targets: ["OpenConnctDSP"]),
        .library(name: "OpenConnctDSPShim", targets: ["OpenConnctDSPShim"]),
    ],
    targets: [
        .target(
            name: "OpenConnctDSP",
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
            name: "OpenConnctDSPShim",
            dependencies: ["OpenConnctDSP"]
        ),
        .testTarget(
            name: "OpenConnctDSPTests",
            dependencies: ["OpenConnctDSPShim"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
