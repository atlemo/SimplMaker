# SimplCAD

A small, native, **parametric** CAD tool for macOS in the spirit of Fusion 360.
You sketch, extrude, fillet and chamfer. Every value is an expression that can use named parameters, and changing any of them rebuilds the whole model.

Status: **early development.** You can sketch on a plane or a face (lines, rectangles, circles, arcs, points), add constraints and dimensions, extrude profiles, then fillet and chamfer edges. Any value can be changed later, and the whole model rebuilds. See [PLAN.md](PLAN.md) for the roadmap.

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 26 or later (Swift 6.2+)
- CMake and Ninja, to build OpenCASCADE once: `brew install cmake ninja`

## Getting started on a Mac

```sh
brew install cmake ninja
git clone https://github.com/atlemo/SimplCAD.git && cd SimplCAD
git checkout claude/parametric-cad-tool-plan-k6i4ry   # until it's merged
scripts/build-occt.sh   # one time, ~10–20 min
open SimplCAD.xcodeproj
```

In Xcode, choose the **SimplCADApp** scheme and press ⌘R. Edit the project in Xcode as usual. `Sources/SimplCAD` is a synchronized folder, so new Swift files there are part of the app without adding them to the project. The app target links the `CADCore` and `CADKernel` libraries from the Swift package in the same folder. Run the tests with `swift test`, or open `Package.swift` in Xcode and use its test schemes.

## Build and run

```sh
scripts/build-occt.sh      # once: builds OpenCASCADE 8.0.1 into ThirdParty/occt (~30–60 min)
scripts/bundle-app.sh --debug --open   # build dist/SimplCAD.app and launch it
swift test                 # unit + integration tests
scripts/test-kernel.sh     # C-level kernel regression test (also runs on Linux)
scripts/bundle-app.sh      # release build → dist/SimplCAD.app
```

Launch the bundled app rather than using `swift run`. The bundle declares the `.simplcad` document type, which Open Recent, autosave and versions depend on. You can also open `Package.swift` in Xcode.

## Using it

SimplCAD is a normal Mac document app, with New, Open Recent, autosave, versions and one window per part. It opens with a **welcome window** like Xcode's: create a new part, open the demo part, open a file, or pick one of the recent parts listed on the right (double-click or Return). Turn it off with the checkbox at the bottom or in Settings; **Window → Welcome to SimplCAD** (⇧⌘1) brings it back any time. **File → New Demo Part** (⌥⌘N) opens the sample part: a plate with a hole, a pin hole cut from a sketch on its top face, two filleted corners and a chamfered edge.

- **Parameters** (left sidebar): edit any expression, e.g. set `width` to `90 mm`, or `thickness` to `1 in`, or `hole_d` to `depth / 3`. Press Return and the model rebuilds.
- **Timeline** (left sidebar): select a feature to edit it in the inspector on the right. Right-click a feature to suppress or delete it. A red triangle means the feature failed; hover over it to see why. The features after it still rebuild.
- **Sketch:**
  1. Click **Sketch** in the toolbar (or Sketch → New Sketch…). The three origin planes appear at the origin; click **XY**, **XZ** or **YZ**, or click a flat face of a body. Esc cancels. If a flat face is already selected, the sketch goes straight onto it. The view turns to face the sketch plane. (Sketch → New Sketch On still picks a plane directly.)
  2. Draw with the tools in the toolbar. Keys: **L** line (click point after point; Esc ends the chain), **R** rectangle, **C** circle, **A** arc (center, start, end), **P** point, **D** dimension, **S** select.
     - **F** fillet: click a corner where two lines meet to round it.
     - **T** trim: click the part of a curve to cut away, up to where other curves cross it.
     - **E** extend: click near the end of a line or arc to extend it to the next curve.
     - **Offset:** select curves, then press **Offset** and enter a distance. A positive distance goes outward.
     - Clicking an existing point connects to it.
     - Clicking a curve puts the new point on that curve.
     - Nearly horizontal or vertical lines snap and get a constraint.
  3. **Dimensions:** with **D**, click a line (then empty space) for its length, a circle for its diameter, an arc for its radius, or two points, a point and a line, or two lines. Type a value or an expression such as `width / 2` in the popover that appears. Click a dimension label to change it later.
  4. **Constraints:** select entities with **S** (⇧-click to add more), then pick from the **Constrain** menu or the inspector: coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, midpoint, concentric, fix. Small symbols next to the geometry show each constraint (**H**, **V**, **∥**, **⊥**, **T**, **=**…). Click one to select it and press ⌫ to delete it. You can hide them under View → Show Constraints.
  5. With the select tool, drag points, lines or circle rims. The geometry follows as far as the constraints allow. ⌫ deletes the selection.
  6. The status bar shows the degrees of freedom left. Curves turn black when the sketch is fully constrained. Press **Return** or **Finish Sketch** when done.
- **Extrude:** select a sketch in the timeline. Its closed regions (profiles) show shaded; click one or more (⇧-click), then press **Extrude**. Drag the orange arrow to set the distance; the model updates as you drag. Or type the distance in the inspector, where you also set the operation (new body, join, cut, intersect) and direction.
- **Edit a sketch later:** right-click it in the timeline → **Edit Sketch**, or use the inspector. The model is rolled back to that point while you edit.
- **Fillet / Chamfer:**
  1. Click edges in the viewport (⇧-click to add more).
  2. Press **Fillet** or **Chamfer** in the toolbar.
  3. Set the radius or distance in the inspector. It can be an expression like `corner_r / 2`.
- **Navigation:**
  - Trackpad: two-finger scroll pans, ⇧ + scroll orbits, pinch zooms, rotate spins the view. You can swap pan and orbit in **Settings** (⌘,).
  - Mouse: drag on empty space orbits, right- or middle-drag pans, the wheel zooms.
  - The **View** menu has Fit All (⌘0), Top/Front/Right/Home views (⌘1–⌘4), Orthographic Projection (⌥⌘O) and Show/Hide Inspector (⌥⌘I). Esc clears the selection.
- **Appearance:** the viewport follows light and dark mode, and draws thicker lines when Increase Contrast is on.
- **Files:** documents are `.simplcad` files (JSON). They store only parameters and features; geometry is always rebuilt. **File → Export STEP…/Export STL…** export the bodies.
- **Import STEP:** **File → Import STEP…** (⇧⌘I) adds a `.step`/`.stp` file to the timeline as an **Import** feature: one body with all the file's solids, named after the file, in millimetres whatever unit the file uses. The file's contents are stored in the part, so it rebuilds without the original. Fillet, cut, shell, move or rotate it like any other body. **Replace File…** in the inspector swaps in a new version; features after the import keep their edges and faces as long as the new file lists its faces in the same order.

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
