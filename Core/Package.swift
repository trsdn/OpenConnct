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
        // Pure control-side logic, kept out of the app target so it can be
        // tested without a microphone attached. The app build compiles these
        // sources directly (see APP_SRC in the Makefile) rather than importing
        // a module, because the app is built with plain swiftc.
        .target(
            name: "OpenConnctControl"
        ),
        .testTarget(
            name: "OpenConnctDSPTests",
            dependencies: ["OpenConnctDSPShim"]
        ),
        .testTarget(
            name: "OpenConnctControlTests",
            dependencies: ["OpenConnctControl"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
