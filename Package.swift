// swift-tools-version: 6.2
// SimplCAD — a small parametric CAD tool for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PackageDescription

// OpenCASCADE is built by scripts/build-occt.sh into ThirdParty/occt (override with OCCT_ROOT).
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let occt = ProcessInfo.processInfo.environment["OCCT_ROOT"] ?? "\(packageRoot)/ThirdParty/occt"

let package = Package(
    name: "SimplCAD",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SimplCAD", targets: ["SimplCAD"]),
        // Used by the Xcode app project (SimplCAD.xcodeproj).
        .library(name: "CADCore", targets: ["CADCore"]),
        .library(name: "CADKernel", targets: ["CADKernel"]),
    ],
    targets: [
        // C API over OpenCASCADE (C++ inside, plain C header outside).
        .target(
            name: "CKernel",
            path: "Sources/CKernel",
            cxxSettings: [.unsafeFlags(["-I\(occt)/include/opencascade", "-Wno-deprecated-declarations"])],
            linkerSettings: [
                .unsafeFlags(["-L\(occt)/lib"]),
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
            name: "SimplCAD",
            dependencies: ["CADCore", "CADKernel"],
            path: "Sources/SimplCAD"
        ),
        .testTarget(name: "CADCoreTests", dependencies: ["CADCore"], path: "Tests/CADCoreTests"),
        .testTarget(name: "CADKernelTests", dependencies: ["CADCore", "CADKernel"], path: "Tests/CADKernelTests"),
        .testTarget(name: "SimplCADTests", dependencies: ["SimplCAD"], path: "Tests/SimplCADTests"),
    ],
    cxxLanguageStandard: .cxx17
)
