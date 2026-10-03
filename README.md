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
  2. Draw with the tools in the toolbar. Keys: **L** line (click point after point; Esc ends the chain), **B** spline (a smooth curve through the points you click; press and drag to pull a handle, click the first point to close the shape), **R** rectangle, **C** circle, **A** arc (center, start, end), **P** point, **D** distance, **I** dimension, **S** select.
     - **F** fillet: click a corner where two lines meet to round it.
     - **T** trim: click the part of a curve to cut away, up to where other curves cross it.
     - **E** extend: click near the end of a line or arc to extend it to the next curve.
     - **Offset:** select curves, then press **Offset** and enter a distance. A positive distance goes outward.
     - Clicking an existing point connects to it.
     - Clicking a curve puts the new point on that curve.
     - Nearly horizontal or vertical lines snap and get a constraint.
  3. **Dimensions:** with **I**, click a line (then empty space) for its length, a circle for its diameter, an arc for its radius, or two points, a point and a line, or two lines. Type a value or an expression such as `width / 2` in the popover that appears. Click a dimension label to change it later.
     - **Distance:** with **D**, click two items and type the distance between them, for example to put a hole 4 mm from the edge of a rectangle. A point, a line or a circle's center point is measured as usual; a circle or arc is measured from its *edge* (to measure from the middle, click its center point instead). Two points can be measured straight, or only horizontally or vertically, with the buttons in the popover. Two lines must be parallel. The circle moves to keep the distance and keeps its size, and the edge it is measured from stays where it is (likewise the point or line you click second). The distance is drawn with extension lines and arrows; with the Select tool, drag its line to move it out of the way.
  4. **Constraints:** select entities with **S** (⇧-click to add more), then pick from the **Constrain** menu or the inspector: coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, midpoint, concentric, fix. Small symbols next to the geometry show each constraint (**H**, **V**, **∥**, **⊥**, **T**, **=**…). Click one to select it and press ⌫ to delete it. You can hide them under View → Show Constraints.
  5. With the select tool, drag points, lines or circle rims. The geometry follows as far as the constraints allow. ⌫ deletes the selection.
  6. The status bar shows the degrees of freedom left. Curves turn black when the sketch is fully constrained. Press **Return** or **Finish Sketch** when done.
- **Extrude:** select a sketch in the timeline. Its closed regions (profiles) show shaded; click one or more (⇧-click), then press **Extrude**. Drag the orange arrow to set the distance; the model updates as you drag. Or type the distance in the inspector, where you also set the operation (new body, join, cut, intersect) and direction.
- **Edit a sketch later:** right-click it in the timeline → **Edit Sketch**, or use the inspector. The model is rolled back to that point while you edit.
- **Fillet / Chamfer:**
  1. Click edges in the viewport (⇧-click to add more).
  2. Press **Fillet** or **Chamfer** in the toolbar.
  3. Set the radius or distance in the inspector. It can be an expression like `corner_r / 2`.
  - **Chamfer types:** the small arrow beside the Chamfer button picks how it is measured: **Equal Distance Chamfer**, **Distance and Angle Chamfer** (a distance on one face and the angle to it) or **Two Distance Chamfer** (a distance on each face). The button then works that way until you pick another. The last two show an arrow and a size field for each value (Tab moves between them), and a Flip button (or the inspector's switch) puts the first distance on the edge's other face. With faces picked, the first distance is on the picked face.
- **Navigation:**
  - Trackpad: two-finger scroll pans, ⇧ + scroll orbits, pinch zooms, rotate spins the view. You can swap pan and orbit in **Settings** (⌘,).
  - Mouse: drag on empty space orbits, right- or middle-drag pans, the wheel zooms.
  - The **View** menu has Fit All (⌘0), Top/Front/Right/Home views (⌘1–⌘4), Orthographic Projection (⌥⌘O) and Show/Hide Inspector (⌥⌘I). Esc clears the selection.
- **Keys:** the Create and Modify menus show a single letter for each tool: **E** Extrude, **R** Revolve, **W** Sweep, **L** Loft, **B** Rib, **P** Pipe, **X** Box, **Y** Cylinder, **G** Sphere, **U** Torus, **K** Coil, **N** Construction Plane, **V** Canvas, **F** Fillet, **C** Chamfer, **H** Hole, **D** Thread, **S** Shell, **M** Move, **O** Rotate, **Z** Scale, **J** Combine, **I** Mirror, **T** Pattern, and **A** for Appearance. While you sketch, the letters pick sketch tools instead, and in a text field they type as usual.
- **Body colours:** press **A** (or **View → Show Appearance**) to open the Appearance panel. Select bodies in the view (a face or edge counts for its body) or in the panel's body list (⇧-click to add more), then click a colour, or choose any colour with **Custom Colour**. **Default** puts the standard colour back. Right-click a body → **Appearance…** opens the panel for it. Colours are saved in the file, can be undone, and need no rebuild.
- **Light and dark:** the viewport follows light and dark mode, and draws thicker lines when Increase Contrast is on.
- **Files:** documents are `.simplcad` files (JSON). They store only parameters and features; geometry is always rebuilt. **File → Export STEP…/Export STL…** export the bodies.
- **Threads:** **Modify → Thread** (D), or right-click a round face → **Thread…**, then click the side of a shaft or the wall of a hole. It cuts a modeled thread, external on a shaft and internal in a hole, in the size that suits the face: an 8 mm shaft gets M8, a 6.8 mm hole (the M8 tap drill) gets an M8 thread. The inspector picks the standard (ISO Metric, ISO Metric Fine, UNC or UNF) and size, and shows the pitch, diameters and tap drill. The thread runs the full length of the face or a set distance (drag the arrow), from the free end (a shaft's tip, a hole's mouth) or the other end, right- or left-handed. The face is turned or bored to the thread's diameters first, and the thread uses the basic 60° profile, without tolerance classes.
- **Import STEP:** **File → Import STEP…** (⇧⌘I) adds a `.step`/`.stp` file to the timeline as an **Import** feature: one body with all the file's solids, named after the file, in millimetres whatever unit the file uses. The file's contents are stored in the part, so it rebuilds without the original. Fillet, cut, shell, move or rotate it like any other body. **Replace File…** in the inspector swaps in a new version; features after the import keep their edges and faces as long as the new file lists its faces in the same order.
- **Canvas (reference image):** **Create → Canvas (Reference Image)…** (**V**), or **Insert Image…** in the right-click menu of a face or construction plane. Select a flat face or plane first (or click one while the tool waits), then choose a PNG, JPEG, HEIC or TIFF file. The picture lies on that plane at its middle, upright as the view shows the plane, to trace over and measure against. The Inspector sets its **opacity** (a slider; it rebuilds nothing), width (the height follows the picture's proportions), position and turn, all as expressions, and can swap in another file. Clicks and sketching pass through it. The file is kept inside the part, and the browser lists it under Canvases, where the eye hides it.
- **Import SVG:** **File → Import SVG as Sketch…** turns an SVG file into a sketch on the selected flat face or plane (the XY plane when nothing is selected), or adds it to the sketch you are editing. Paths (lines, arcs, cubic and quadratic curves), rectangles, circles, ellipses, polygons and polylines are read, with groups, `transform`s and `<use>` applied, and sized in millimetres from the file's `width`/`height` and `viewBox` (96 px to the inch when it has no size). The drawing's middle goes on the sketch origin. Circles and circular arcs stay exact; closed shapes become profiles you can extrude or cut. Text and images are left out, so convert text to outlines first. The result is plain, unconstrained geometry that you can dimension and edit like anything you drew yourself.
- **Move and Rotate manipulator:** **Move** (M) and **Rotate** (O) put the same manipulator on the bodies or sketches you picked: three arrows slide along X, Y or Z, the three squares slide in a plane, the dot in the middle slides across the screen, and the three rings turn about X, Y or Z (drag a ring's dot). The part you grabbed last is lit, and its value is in the field beside it: type a distance or an angle there, or switch between Move and Rotate and X, Y, Z in the panel below. Distances and angles snap to round steps while you drag. It is one **Move** feature with X, Y, Z and Rotate X, Y, Z values, and the turns happen about the middle of what moves, X then Y then Z, before the move; a value that comes from a parameter asks before a drag replaces it with a number. Rotate features from older files still open, with their single arrow.
- **Scale a sketch:** select a sketch (in the browser, or click one of its profiles or curves), then **Scale** in the Modify group (or **Z**, or right-click the sketch → Scale). It adds a **Scale** feature with a factor you can type, or drag with the arrow. It scales evenly about the sketch's origin, including circles and text, and features built from the sketch after it use the scaled version. The sketch itself stays as drawn, so its dimensions still work, and the factor can be a parameter (`width / 40`).
- **Move, Rotate and Scale inside a sketch:** the sketch toolbar's **Transform** group (also in the **Sketch** menu) works on the curves and points you have selected, or on the whole sketch when nothing is selected. **Move** and **Rotate** put a manipulator in the sketch plane on the selection: drag an arrow to slide along the sketch's x or y, the square or the dot to slide in both, or the ring to turn about the middle of the selection. The sketch follows live; let go to keep it (one undo step), or type an X, Y or angle in the fields under the manipulator and press Return. Pick another selection and it moves to it; Esc or the tool's button again turns it off. **Scale** still opens a box for a factor (about the middle of the selection, or the sketch origin). Circle radii, text height and the dimensions that measure what grows go along when scaling, and a quarter turn swaps horizontal and vertical constraints. A constraint or dimension that would pull the geometry back (a fixed point, or a distance from the origin) puts it back with a message. Text moves, scales and turns (its baseline turns about its anchor, and the angle is saved with it). A new or reopened sketch starts with the Select tool. The **Scale** tool in the Modify group instead adds a Scale feature to the timeline.
- **Pattern inside a sketch:** **Pattern** in the sketch toolbar's Transform group copies the selected curves (or the whole sketch, with nothing selected) in a **Rectangular** grid or a **Circular** run. The copies show live and stay **linked**: they are rebuilt from the originals, so moving, resizing or dimensioning an original, or changing a parameter, moves every copy. For a grid, drag the arrow along x or along y to set the spacing between columns or rows, and type the counts and spacings in the fields (the original counts as one; a negative spacing goes the other way). For a circle, drag the ring to set how far the copies spread (360° goes all the way round, less puts the last copy at the end of the angle), type the count, and click a sketch point to copy around it (the sketch origin to begin with). Counts, spacings and the spread can be expressions or parameters (`n`, `width / 2`); dragging replaces the expression with a number. Return or **OK** keeps the pattern as one undo step; Esc or **Cancel** takes it back. To change a pattern later, click one of its copies with the Select tool; **Delete** (or ⌫) in the panel removes the copies and leaves the originals. The copies are read-only: you can't draw to them, constrain them or drag them, but you can extrude their profiles like any other. A turned copy of text turns with it. A pattern makes at most 400 copies, and curves added to the sketch later are not part of it.

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

It links [OpenCASCADE Technology](https://dev.opencascade.org), which is LGPL-2.1 with the OCCT exception (GPL-compatible). The parts of OCCT that SimplCAD uses include DelaBella (MIT) and flex's `FlexLexer.h` (BSD). The toolbar icons come from [Lucide](https://lucide.dev) (ISC; parts from Feather, MIT). **SimplCAD → About SimplCAD** credits all of them and shows their licence texts; the texts are in `Sources/SimplCAD/LicenseTexts.swift`.
