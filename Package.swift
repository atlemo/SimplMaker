// swift-tools-version: 6.2
// SimplMaker — a small parametric CAD tool for macOS.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import PackageDescription

// OpenCASCADE is built by scripts/build-occt.sh into ThirdParty/occt (override with OCCT_ROOT).
// On macOS it is linked as lib/libSimplOCCT.dylib (LGPL: the user must be able to replace it); the rpath
// below finds it in a development build, and bundle-app.sh copies it into the app and drops that rpath.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let occt = ProcessInfo.processInfo.environment["OCCT_ROOT"] ?? "\(packageRoot)/ThirdParty/occt"

let package = Package(
    name: "SimplMaker",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "SimplMaker", targets: ["SimplMaker"]),
        // The stdio relay for MCP clients that start servers as programs (Claude Desktop); bundle-app.sh puts it in the app.
        .executable(name: "simplmaker-mcp", targets: ["SimplMakerMCP"]),
        // The Quick Look extensions for .simplmaker files (Finder's thumbnails and space-bar preview); bundle-app.sh makes them
        // into .appex bundles in the app's PlugIns.
        .executable(name: "SimplMakerThumbnail", targets: ["SimplMakerThumbnail"]),
        .executable(name: "SimplMakerPreview", targets: ["SimplMakerPreview"]),
        // Used by the Xcode app project (SimplMaker.xcodeproj).
        .library(name: "CADCore", targets: ["CADCore"]),
        .library(name: "CADKernel", targets: ["CADKernel"]),
    ],
    dependencies: [
        // Auto-updates (appcast + EdDSA-signed archives). A binary framework, embedded by scripts/bundle-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // Anonymous usage statistics (TelemetryDeck); can be turned off in Settings.
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.14.0"),
    ],
    targets: [
        // C API over OpenCASCADE (C++ inside, plain C header outside).
        .target(
            name: "CKernel",
            path: "Sources/CKernel",
            cxxSettings: [.unsafeFlags(["-I\(occt)/include/opencascade", "-Wno-deprecated-declarations"])],
            linkerSettings: [
                .unsafeFlags(["-L\(occt)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(occt)/lib"]),
                .linkedLibrary("SimplOCCT"),
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
            ]
        ),
        // Pure Swift: parameters, expressions, sketches, solver, document model. No UI, no kernel.
        .target(name: "CADCore", path: "Sources/CADCore"),
        // Swift wrapper over CKernel + the timeline regenerator.
        .target(name: "CADKernel", dependencies: ["CADCore", "CKernel"], path: "Sources/CADKernel"),
        // The macOS app (SwiftUI + Metal).
        .executableTarget(
            name: "SimplMaker",
            dependencies: ["CADCore", "CADKernel", .product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "TelemetryDeck", package: "SwiftSDK")],
            path: "Sources/SimplMaker",
            // SwiftPM executables only look for frameworks next to the binary; an .app keeps them in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Plain Foundation: forwards MCP messages from standard input to the running app. No CAD, no UI.
        .executableTarget(name: "SimplMakerMCP", path: "Sources/SimplMakerMCP"),
        // App extensions: they start at NSExtensionMain, not main, and read only the picture stored in the file.
        .executableTarget(name: "SimplMakerThumbnail", path: "Sources/SimplMakerThumbnail",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .executableTarget(name: "SimplMakerPreview", path: "Sources/SimplMakerPreview",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "CADCoreTests", dependencies: ["CADCore"], path: "Tests/CADCoreTests"),
        .testTarget(name: "CADKernelTests", dependencies: ["CADCore", "CADKernel"], path: "Tests/CADKernelTests"),
        .testTarget(name: "SimplMakerMCPTests", dependencies: ["SimplMakerMCP"], path: "Tests/SimplMakerMCPTests"),
        // SimplMakerMCP is a dependency only so that the relay program is built before the tests that start it.
        .testTarget(name: "SimplMakerTests", dependencies: ["SimplMaker", "SimplMakerMCP"], path: "Tests/SimplMakerTests"),
    ],
    cxxLanguageStandard: .cxx17
)
