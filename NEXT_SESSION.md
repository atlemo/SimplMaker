# SimplCAD: handoff for the next session

_Last updated 2026-09-25. All work is on branch `claude/parametric-cad-tool-plan-k6i4ry`, not merged to `main` yet._

## Where things stand

- **CI is green on the latest commit:** macOS 26 build, all Swift tests, the C kernel tests, an Xcode build of the generated project, and the app bundle. The Linux kernel tests pass too.
- **Nobody has used the app by hand yet.** CI proves it compiles, the logic is right and the Metal shaders compile. It says nothing about how dragging, snapping, popovers, cursors or glyph placement feel. Expect rough edges on first use.

### What exists

| Area | What's there |
|---|---|
| Kernel (`Sources/CKernel`) | C API over OpenCASCADE 8.0.1 (static): sketch regions, extrude, booleans, fillet, chamfer, persistent face/edge names, tessellation, STEP/STL export, edge drag-handle frames |
| Core (`Sources/CADCore`) | Expressions with units, parameters, sketch model, Levenberg–Marquardt solver with drag solving, trim/extend/offset/corner fillet, Codable document |
| Regeneration (`Sources/CADKernel`) | Swift wrappers; the timeline regenerator (per-feature errors, fillet input bodies for handles) |
| App (`Sources/SimplCAD`) | Document-based SwiftUI app. Metal viewport with ID-buffer picking, dark mode, sketch mode with tools and constraint glyphs, dimension popovers, drag handles (extrude, fillet, chamfer) with live preview, Settings, View menu, icon |
| Build | `SimplCAD.xcodeproj`, `scripts/build-occt.sh`, `scripts/bundle-app.sh`, CI in `.github/workflows/ci.yml` |

See `README.md` for usage and `PLAN.md` for architecture and the milestone table.

## Start here next time (on the Mac)

```sh
brew install cmake ninja
mkdir -p ~/Developer && cd ~/Developer
git clone https://github.com/atlemo/SimplCAD.git && cd SimplCAD
git checkout claude/parametric-cad-tool-plan-k6i4ry
scripts/build-occt.sh          # one time, ~10–20 min
open SimplCAD.xcodeproj
```

In Xcode, run the **SimplCADApp** scheme (⌘R), then File → New Demo Part (⌥⌘N).

## Next steps (in order)

1. **First hands-on test.** Try each area, and note anything that looks or feels wrong (screenshot plus one sentence):
   - creating a sketch: the Sketch button shows the origin planes with a "Select a plane or planar face" prompt; click a plane or a flat face, Esc cancels
   - sketch: line, rectangle, circle and arc; dimensions; constraints; dragging; trim, extend, offset, corner fillet
   - extrude by picking a profile and dragging the arrow
   - fillet and chamfer: pick edges, then drag the handle, including dragging past the maximum
   - editing parameters in the demo part
   - save, reopen and undo
   - dark mode, trackpad navigation, orthographic projection and the standard views

   Fix what comes up before adding features.
2. **Merge to `main`** through a pull request once the first test pass looks OK.
3. **Liquid Glass icon (optional):** in Icon Composer, build `Packaging/AppIcon.icon` from `Packaging/AppIcon.png`, then add it to the app target in Xcode so macOS 26 stops framing the icon.
4. **Next modelling features.** Revolve and construction planes first; together they add the most capability.
   - revolve
   - construction planes (offset/angled) and axes
   - mirror and pattern (linear, circular)
   - shell
   - "through all" / "to face" extents
   - picking body edges into a sketch (projection)
5. **Remaining UX items:**
   - accept decimal commas in number fields (matters for a Norwegian locale)
   - VoiceOver descriptions for the viewport and selection
   - customizable toolbar
   - restore window, camera and inspector state
   - colour sketch geometry by how constrained each part is
   - name the conflicting constraints when a sketch is over-constrained
6. **Robustness:**
   - when an edit removes a referenced face or edge, offer to re-pick it instead of only showing an error
   - a visible rollback marker in the timeline
   - reordering features

## Open questions

- Should documents always use mm, or have a per-document unit setting like Fusion?
- Should navigation copy Fusion 360 exactly? Right now trackpad scroll pans (Apple style) with orbit as an option in Settings.

## Things to know

- `SimplCAD.xcodeproj` is committed and edited in Xcode. `Sources/SimplCAD` is a synchronized folder, so new files there join the app target automatically.
- The core, kernel and C++ code live in the Swift package. The Xcode app target links the package's `CADCore` and `CADKernel` libraries.
- Dragging a handle on a value that comes from a parameter asks before replacing the expression with a number.
- In CI, Swift Testing's `#expect` can't wrap a `mutating` call or an `inout` argument. Assign the result to a `let` first.
- `download.swift.org` is blocked in the cloud environment, so Swift can't be compiled there; the cloud relies on GitHub Actions CI for macOS builds. To change that, allow the host in the environment's network settings.
