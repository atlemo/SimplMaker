# SimplCAD

A small, native, **parametric** CAD tool for macOS in the spirit of Fusion 360.
You sketch, extrude, fillet and chamfer. Every value is an expression that can use named parameters, and changing any of them rebuilds the whole model.

Status: **early development.** The kernel and the timeline regenerator work end to end: sketch → solve → extrude → cut → fillet → chamfer → edit a parameter → rebuild. The app shows the model, lets you edit parameters and feature values, and creates fillets and chamfers on edges you pick. It does not have interactive sketch drawing yet. See [PLAN.md](PLAN.md) for the roadmap.

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 26 or later (Swift 6.2+)
- CMake and Ninja, to build OpenCASCADE once: `brew install cmake ninja`

## Build and run

```sh
scripts/build-occt.sh      # once: builds OpenCASCADE 8.0.1 into ThirdParty/occt (~30–60 min)
swift run SimplCAD         # run the app straight from SwiftPM
swift test                 # unit + integration tests
scripts/test-kernel.sh     # C-level kernel regression test (also runs on Linux)
scripts/bundle-app.sh      # release build → dist/SimplCAD.app
```

You can also open `Package.swift` in Xcode and run the `SimplCAD` scheme.

## Using it

The app opens with a demo part: a plate with a hole, a pin hole cut from a sketch on its top face, two filleted corners and a chamfered edge.

- **Parameters** (left sidebar): edit any expression, e.g. set `width` to `90 mm`, or `thickness` to `1 in`, or `hole_d` to `depth / 3`. Press Return and the model rebuilds.
- **Timeline** (left sidebar): select a feature to edit it in the inspector on the right. Right-click a feature to suppress or delete it. A red triangle means the feature failed; hover over it to see why. The features after it still rebuild.
- **Fillet / Chamfer:**
  1. Click edges in the viewport (⇧-click to add more).
  2. Press **Fillet** or **Chamfer** in the toolbar.
  3. Set the radius or distance in the inspector. It can be an expression like `corner_r / 2`.
- **Navigation:**
  - Trackpad: two-finger scroll orbits, ⇧ + scroll pans, pinch zooms.
  - Mouse: left-drag orbits, right- or middle-drag pans, the wheel zooms.
  - ⌘0 fits the model in view. Esc clears the selection.
- **Files:** ⌘S saves a `.simplcad` file (JSON). It stores only parameters and features; geometry is always rebuilt. ⌘E exports STEP, and there's also Export STL.

## Architecture

| Layer | What | Where |
|---|---|---|
| App | SwiftUI panels, AppKit + Metal viewport with GPU ID-buffer picking | `Sources/SimplCAD` |
| Core | Expressions with units, parameters, sketch model, constraint solver, document model. Pure Swift with no dependencies. | `Sources/CADCore` |
| Kernel (Swift) | Wrappers and the timeline **regenerator** | `Sources/CADKernel` |
| Kernel (C API) | Plain C API over OpenCASCADE, with persistent face/edge naming | `Sources/CKernel` |
| OpenCASCADE 8 | Static, minimal build merged into one `libSimplOCCT.a` | `ThirdParty/occt` (built) |

Faces and edges have **persistent names** built from stable IDs and the kernel's history. For example, an extrusion's top face is `plate.end`, and the edge between two of its sides is `plate.side.L0|plate.side.L1`. Features refer to geometry by these names, so a fillet stays on the right edge when you change the dimensions upstream.

## License

SimplCAD is free software under the **GNU GPL v3.0 or later** (see [LICENSE](LICENSE)). You may use, modify and redistribute it, and derivative works must stay under the same license.

It links [OpenCASCADE Technology](https://dev.opencascade.org), which is LGPL-2.1 with the OCCT exception (GPL-compatible).
