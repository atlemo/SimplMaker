# SimplCAD — plan and feasibility

A simple, native macOS, parametric CAD tool in the spirit of Fusion 360:
**sketch → constrain → extrude → go back and change anything → model regenerates.**

## 1. Verdict: doable, if the scope stays tight

A minimum viable product (MVP) is realistic. By MVP I mean 2D constrained sketches on planes and planar faces, extrude as new body/join/cut, a parameter table with expressions, an editable feature timeline, save/load and STEP/STL export. Two things make it realistic:

1. **We don't write the geometry kernel.** [OpenCASCADE (OCCT)](https://dev.opencascade.org) is a mature, free (LGPL‑2.1 + exception) B‑rep kernel that already does extrusions, booleans, fillets, meshing and STEP I/O, and it builds natively on Apple Silicon. FreeCAD, CadQuery and others are built on it.
2. **The other hard parts are well-understood algorithms.** A sketch constraint solver is nonlinear least squares. Parametric regeneration is replaying a feature list. Rendering is Metal.

The one real research-grade risk is the **topological naming problem**: when you change an upstream sketch, "the top face" that a downstream sketch sits on has to still be found. The spike below shows a strategy that works for extrude/cut. It will need care as more features are added.

Out of reach for a small team (don't aim for these): Fusion parity (assemblies with joints, CAM, surfacing, T‑splines, simulation), and fillets that never fail on arbitrary models.

**Rough effort for the MVP:** about 3–5 months for one experienced developer working full time (see §8).

## 2. Feasibility spike (already done)

`spike/parametric_spike.py` runs the risky core end to end on OCCT 8.0 through its Python bindings. It's throwaway code, but it runs the same kernel calls the Swift/C++ app will make:

| Step | Result |
|---|---|
| Parameters as expressions (`hole_d = depth / 4`) + cycle detection | ✅ |
| Constraint solver (Levenberg–Marquardt) from deliberately bad initial positions | ✅ converges in 2–3 iterations, DOF = 0 reported |
| Profile detection: split the sketch plane by the curves, pick region "bounded by L0–L3 and C0" | ✅ plate-with-hole region found, outside region rejected |
| Extrude with persistent face names (`E1.end`, `E1.side.L2`, …) | ✅ all 8 faces named |
| Sketch 2 placed on face `E1.end`, cut-extrude through | ✅ |
| Names carried through the boolean using OCCT history | ✅ |
| **Edit width/depth/height → full regeneration** | ✅ volumes match the analytic value exactly; `E1.end` now resolves at z = 25 |
| Tessellation per face (for rendering and picking) | ✅ 356 triangles |
| Full regenerate + mesh time | **~20 ms** |

Lesson learned: my first version fell back to *geometric* matching to name faces. It silently gave two side faces the wrong name, because adjacent edges touch at corners. **Naming must come from kernel history, not geometry.** Geometry is only a tie-breaker (§6.1).

To run it: `pip install cadquery-ocp numpy && python3 spike/parametric_spike.py`

## 3. MVP scope

**In**
- Sketch on the XY/XZ/YZ origin planes or on a planar face of a body.
- Sketch entities: line, rectangle (2-point, center), circle, 3-point and center arcs, point, construction geometry.
- Constraints: coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, midpoint, point‑on‑curve, concentric, symmetric, fix.
- Dimensions: distance, horizontal/vertical distance, radius/diameter, angle. Every dimension value is an expression.
- Solver UX: live drag, under-, fully and over-constrained coloring, conflict reporting, auto-constraints while drawing.
- Extrude: one side, symmetric or two-sided distance; New Body, Join, Cut and Intersect; multiple profiles.
- Parameter table: user parameters with units and expressions. Dimension parameters (`d1`, `d2` …) are created automatically, like Fusion.
- Timeline: edit any feature, roll back, suppress, reorder (with validation). Features that break show an error and don't crash.
- Undo/redo, document save/load, export STEP and STL.

**Next, after MVP:** revolve, fillet, chamfer, construction planes/axes, shell, rectangular and circular patterns, mirror, project/include geometry into a sketch, sketch trim/extend/offset, measure tool, 3MF export, DXF import.

**Later / maybe never:** assemblies, drawings, sweeps/lofts, sheet metal.

## 4. Architecture

```
┌──────────────────────────────── SimplCAD.app (Swift) ────────────────────────────────┐
│  UI (SwiftUI)          toolbar · browser/feature tree · timeline · inspector ·        │
│                        parameter table · feature dialogs                              │
│  Viewport (AppKit+Metal) MTKView · camera · shading · edges · sketch overlay · picking │
│  Interaction           tools as state machines (LineTool, ExtrudeTool, …) · snapping  │
├───────────────────────────────────────────────────────────────────────────────────────┤
│  CADModel (pure Swift, no UI, no OCCT → unit-testable, even on Linux CI)              │
│   Document ─ Parameters (expression parser, units, dependency graph)                  │
│            ─ Sketches (entities w/ UUIDs, constraints, dimensions)                    │
│            ─ Features (ordered timeline: Sketch, Extrude, …)                          │
│            ─ References (persistent names: "E1.side.<curveUUID>")                     │
│   SketchSolver (LM / Gauss-Newton, DOF + conflict analysis, uses Accelerate)          │
│   Regenerator (replays features, caches per-feature results, runs off-main-thread)    │
├───────────────────────────────────────────────────────────────────────────────────────┤
│  CADKernel — thin C++ facade (≈ 20–40 functions), imported via Swift C++ interop      │
│   makeSketchEdges · findRegions · extrude · boolean(+history) · faceFrame ·           │
│   tessellate · exportSTEP/STL · volume/bbox                                           │
├───────────────────────────────────────────────────────────────────────────────────────┤
│  OpenCASCADE (dynamic frameworks bundled in the .app)                                 │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### Key technology choices

| Concern | Choice | Why / alternatives |
|---|---|---|
| Language | **Swift 6** for the app and model. A **small C++ facade** over OCCT. | Native and modern. OCCT headers never reach Swift: they are heavy and template-laden, and Swift's C++ importer handles a small, plain facade much better. Fallback is an Objective‑C++ wrapper. |
| Geometry kernel | **OpenCASCADE 8.x** | Parasolid/ACIS cost too much. Own mesh kernel ([Manifold](https://github.com/elalish/manifold)) has robust, fast booleans but no exact faces, fillets or STEP. Keep Manifold in mind only if OCCT booleans become a problem. |
| Constraint solver | **Own solver in Swift** (LM + analytic Jacobians, rank analysis with Accelerate/LAPACK) | Small (the spike's is ~60 lines), and gives full control over drag behavior and error messages. Drop-in alternatives: FreeCAD's PlaneGCS (LGPL, C++/Eigen) or SolveSpace's `libslvs` (**GPLv3**, which only works if SimplCAD is GPL). |
| Rendering | **Metal** via `MTKView` | SceneKit was soft-deprecated in 2025 and is weak at CAD needs (crisp edges, ID picking). RealityKit is built for AR. |
| UI | **SwiftUI** panels, **AppKit** `NSView` for the viewport (via `NSViewRepresentable`) | SwiftUI is fast to build panels in. AppKit gives precise mouse, trackpad, modifier-key and cursor control. |
| Document | SwiftUI `DocumentGroup` (or `NSDocument`), JSON via `Codable` | Autosave, versions and iCloud come for free. |
| Minimum OS / arch | macOS 15+, Apple Silicon (arm64) only | Halves the OCCT build and test matrix. Intel could be added later with universal builds. |

## 5. Data model (the "parametric" part)

The document stores **intent, never geometry**. Geometry is always rebuilt by replaying the timeline.

```swift
struct Document: Codable {
  var parameters: [Parameter]          // name, expression ("depth / 4"), unit, comment
  var timeline:   [Feature]            // ordered history
  var rollbackIndex: Int?              // timeline marker, as in Fusion
}

enum Feature: Codable {
  case sketch(SketchFeature)           // id, plane: PlaneRef, entities, constraints, dimensions
  case extrude(ExtrudeFeature)         // id, profiles: [ProfileRef], extent, operation, targetBodies
  // later: revolve, fillet, chamfer, plane, pattern, …
}

enum PlaneRef: Codable { case origin(OriginPlane); case face(FaceRef) }
struct FaceRef: Codable { var name: String; var hint: GeometricSignature }  // "E1.end" + normal/centroid
struct ProfileRef: Codable { var sketch: UUID; var boundingCurves: Set<UUID>; var hint: Point2D }
struct Dimension: Codable { var id: UUID; var kind: DimKind; var refs: [UUID]; var expression: String; var parameterName: String }
```

- Sketch entities and features have **UUIDs** that never change. Most persistent names are built from these IDs, which keeps them stable across edits.
- A dimension *is* a parameter (`d3 = width / 2`). Editing it in the sketch or in the parameter table is the same operation.
- Undo/redo: the document is a small value type, so each edit stores a snapshot on `UndoManager`. This is trivially correct.

## 6. Regeneration pipeline

1. **Evaluate parameters.** Parse expressions, sort by dependencies, detect cycles, convert units (store in mm and radians).
2. **Replay features in order**, up to the rollback marker:
   - **Sketch:** resolve its plane (origin plane or `FaceRef` → face → frame), push parameter values into dimensions, solve, then build OCCT edges and regions.
   - **Extrude:** resolve `ProfileRef`s to regions, run the prism, then apply the boolean against the target bodies. Record face names from the kernel history.
3. **Cache** each feature's output, keyed by a hash of its definition, the parameter values it used and the upstream hash. Editing feature *k* re-runs only *k…n*. (A full regenerate of the spike's model takes ~20 ms, so this is headroom, not a necessity.)
4. **Run off the main thread** on a single serial "kernel" actor. The UI keeps showing the last good model, and stale jobs are cancelled when the user keeps dragging.
5. **Handle failures gracefully.** If a reference can't be resolved or an operation fails, mark that feature red in the timeline, skip whatever depends on it, and keep the rest. The user fixes it by re-picking. This is how Fusion behaves.
6. **Tessellate** the changed bodies (`BRepMesh`) and upload them to Metal with per-face and per-edge IDs.

### 6.1 Topological naming strategy (the hard part)

- **Generated names:** extrude creates `‹feat›.start`, `‹feat›.end` and `‹feat›.side.‹curveUUID›` from `BRepPrimAPI_MakePrism::FirstShape/LastShape/Generated`. The spike showed this works.
- **Propagation:** booleans pass names forward with `Modified`/`Generated`/`IsDeleted` history (`BRepAlgoAPI_*`). Faces from the tool body keep the tool's names.
- **Splits:** if one face becomes several (a cut splits the top face in two), the pieces get a deterministic sub-index. The `FaceRef` also stores a geometric signature (normal and centroid), which picks the intended piece and warns if the match is weak.
- **Edges** (needed for fillets later) are named by their two adjacent face names.
- **Geometry is never the primary key.** The spike demonstrated that geometric matching fails silently.
- FreeCAD 1.0's TNP mitigation, and OCCT's own `TNaming` in OCAF, are prior art to borrow from if this outgrows the simple scheme.

## 7. Viewport and interaction details

- **Rendering passes:**
  - shaded faces with 4× MSAA
  - screen-space thick lines for B-rep edges, silhouettes and sketch curves
  - sketch overlay: points, constraint glyphs, dimensions
  - infinite grid
  - later, a view cube
- **Picking:** each face, edge and sketch entity ID is rendered into an `R32Uint` offscreen texture. Hover reads back one pixel, which is fast and exact.
- **Camera:** orbit/pan/zoom with both mouse (middle-drag, Fusion-style) and trackpad gestures (scroll pans, pinch zooms, ⌥-drag orbits). Orthographic and perspective. Reversed-Z depth. "Look at" the sketch plane when a sketch opens.
- **Dimension labels:** AppKit/SwiftUI text overlays positioned by projecting 3D anchors to the screen. This is much easier than GPU text, and it makes the labels editable inline (double-click → text field that accepts an expression).
- **Tools** are explicit state machines (`idle → firstPoint → rubberBand → commit`). Each one emits document edits and never mutates geometry directly.

## 8. Milestones

Estimates assume one experienced developer working full time.

| # | Milestone | Deliverable | Est. |
|---|---|---|---|
| M0 | Foundations | Xcode project, OCCT build script (dynamic `.framework`s, only the needed toolkits), C++ facade "make box → tessellate", Metal viewport showing it | 1–2 wk |
| M1 | Viewport | Camera, shading, edges, grid, ID-buffer picking, hover/selection highlight | 1–2 wk |
| M2 | Sketch geometry | Create a sketch on an origin plane; draw line, rectangle, circle and arc with snapping; select and delete | 2–3 wk |
| M3 | Constraint solver | Constraints and dimensions, drag-solve, DOF coloring, conflict detection, auto-constraints | 3–4 wk |
| M4 | Parameters | Expression parser with units, parameter table UI, dimensions as parameters | 1 wk |
| M5 | Extrude + timeline | Profile detection and picking, extrude with New/Join/Cut/Intersect, timeline, edit-feature, rollback, error states | 2–3 wk |
| M6 | Sketch on face | `FaceRef` persistent naming, propagation through booleans, re-pick flow | 2–3 wk |
| M7 | Persistence | Save/load (versioned JSON), undo/redo, STEP/STL export | 1–2 wk |
| | **MVP** | | **~3–5 months** |

M0 is the go/no-go checkpoint for the native stack: OCCT built, Swift calling the facade, and the Metal viewport all working on macOS. If Swift C++ interop gives trouble there, switch the facade to Objective‑C++. That costs about a day.

Testing: `CADModel` (parameters, solver, serialization) is pure Swift with a wide unit-test suite. Kernel tests are golden-model regressions: build a document, regenerate, assert volume, face count and that references resolve (exactly what the spike does). CI runs on GitHub Actions macOS runners.

## 9. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Topological naming breaks references on bigger edits | Medium | History-based names (§6.1), clear red timeline errors and a re-pick flow. Keep the feature set small until naming is solid. |
| Solver UX feels "jumpy" when dragging or on over-constrained sketches | Medium | Weight the dragged point, minimize movement relative to the previous solution, rank analysis to name the conflicting constraints. Budget time for tuning in M3. |
| OCCT build/packaging friction on macOS | Low–Med | Build once with a script and cache the result as frameworks. `brew install opencascade` works for early development. |
| OCCT boolean or fillet failures on edge cases | Medium (fillets) / Low (extrude+booleans) | `ShapeFix` healing, fuzzy booleans (`SetFuzzyValue`), surface failures as feature errors rather than crashes. |
| Swift ↔ C++ interop rough edges | Low | Keep the facade small and plain (opaque handles, POD structs). Objective‑C++ fallback. |
| Licensing | Low | OCCT is LGPL: ship it as dynamic frameworks inside the app so it can be relinked. Avoid GPL components (libslvs) unless SimplCAD is itself GPL. |
| Scope creep toward Fusion parity | High | This document's MVP list is the contract. |

## 10. Decisions needed from you

1. **License / distribution:** open source (which license?), closed source, or Mac App Store? This decides whether GPL components like the SolveSpace solver are allowed, and how OCCT gets packaged.
2. **Target:** OK with macOS 15+ and Apple Silicon only?
3. **Next step:** start M0 (Xcode project + OCCT build + first Metal viewport)?
