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
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SimplMaker", targets: ["SimplMaker"]),
        // Used by the Xcode app project (SimplMaker.xcodeproj).
        .library(name: "CADCore", targets: ["CADCore"]),
        .library(name: "CADKernel", targets: ["CADKernel"]),
    ],
    dependencies: [
        // Auto-updates (appcast + EdDSA-signed archives). A binary framework, embedded by scripts/bundle-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
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
            dependencies: ["CADCore", "CADKernel", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SimplMaker",
            // SwiftPM executables only look for frameworks next to the binary; an .app keeps them in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CADCoreTests", dependencies: ["CADCore"], path: "Tests/CADCoreTests"),
        .testTarget(name: "CADKernelTests", dependencies: ["CADCore", "CADKernel"], path: "Tests/CADKernelTests"),
        .testTarget(name: "SimplMakerTests", dependencies: ["SimplMaker"], path: "Tests/SimplMakerTests"),
    ],
    cxxLanguageStandard: .cxx17
)
