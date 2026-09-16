// swift-tools-version: 6.0
import PackageDescription

// Kept out of Core/Package.swift on purpose: Core is pinned to macOS 14 (see
// its own platforms: comment and the README note on `make test`), but the app
// itself ships back to macOS 13. This package's deployment target has to match
// the app's, or the compiled OpenConnctUpdate.swiftmodule refuses to link into
// it.
let package = Package(
    name: "OpenConnctUpdate",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenConnctUpdate", targets: ["OpenConnctUpdate"]),
    ],
    dependencies: [
        // In-app updates. Pinned exactly, like the driver and DSP code: a
        // silent minor-version change here would change what the running app
        // is allowed to replace itself with.
        .package(url: "https://github.com/mxcl/AppUpdater", exact: "4.1.2"),
    ],
    targets: [
        // A real SwiftPM module the app imports, rather than source compiled
        // in directly like Core/Sources/OpenConnctControl: AppUpdater is a
        // third-party dependency with its own transitive dependency (Version),
        // and vendoring both would mean hand-tracking upstream security fixes.
        // The Makefile builds this target with `swift build` and hands the
        // App's swiftc invocation the resulting module and object files.
        .target(
            name: "OpenConnctUpdate",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater")
            ]
        ),
    ]
)
