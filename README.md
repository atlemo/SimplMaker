# SimplCAD

A small, native, **parametric** CAD tool for macOS in the spirit of Fusion 360.
You sketch, extrude, fillet and chamfer. Every value is an expression that can use named parameters, and changing any of them rebuilds the whole model.

Status: **early development.** You can sketch on a plane or a face (lines, rectangles, circles, arcs, points), add constraints and dimensions, extrude profiles, then fillet and chamfer edges. Any value can be changed later, and the whole model rebuilds. See [PLAN.md](PLAN.md) for the roadmap.

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
- **Sketch:**
  1. Choose **Sketch → On XY Plane** (or XZ/YZ). Or select a flat face of a body first and choose **On Selected Face**. The view turns to face the sketch plane.
  2. Draw with the tools in the toolbar. Keys: **L** line (click point after point; Esc ends the chain), **R** rectangle, **C** circle, **A** arc (center, start, end), **P** point, **D** dimension, **S** select.
     - Clicking an existing point connects to it.
     - Clicking a curve puts the new point on that curve.
     - Nearly horizontal or vertical lines snap and get a constraint.
  3. **Dimensions:** with **D**, click a line (then empty space) for its length, a circle for its diameter, an arc for its radius, or two points, a point and a line, or two lines. Type a value or an expression such as `width / 2` in the box that appears. Click a dimension label to change it later.
  4. **Constraints:** select entities with **S** (⇧-click to add more), then pick from the **Constrain** menu or the inspector: coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, midpoint, concentric, fix. The inspector lists the constraints; you can delete them there.
  5. With the select tool, drag points, lines or circle rims. The geometry follows as far as the constraints allow. ⌫ deletes the selection.
  6. The status bar shows the degrees of freedom left. Curves turn black when the sketch is fully constrained. Press **Return** or **Finish Sketch** when done.
- **Extrude:** select a sketch in the timeline. Its closed regions (profiles) show shaded; click one or more (⇧-click), then press **Extrude**. Set the distance, operation (new body, join, cut, intersect) and direction in the inspector.
- **Edit a sketch later:** right-click it in the timeline → **Edit Sketch**, or use the inspector. The model is rolled back to that point while you edit.
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
