# Make a Mold: plan and where it stands

Written 2026-11-19 at the end of the session that built the workspaces and the ribbon. Read this first when you start the Mold work.

## What we are making

A **rigid, printed two-part mold**: the user has a body, prints the two halves, and casts silicone (or resin) in them to get copies. Not the other kind (a silicone mold poured around a printed master): that can follow later and reuses most of the code.

## Decisions already made

- **Mold is a workspace, not a timeline feature.** The window's workspaces are Start | Design | Mold | Render (`Workspace.swift`). Mold is linked to a body of the part but its settings live apart from the part's history: they must follow the part when it changes, and do not belong in rollback or the feature list.
- **Storage:** `Document.molds` (an optional Codable list, like `folders` and `parameterFolders`, so old files are untouched). One mold per source body to start with, several molds per part allowed.
- **Building:** a `MoldBuilder` that runs after the regenerator on the same background thread, from the source body's latest shape, with a cache keyed by the setup and the body. The halves are derived bodies, not features. They are shown in the Mold workspace and exported from it; a later "Place in Design" button may add them as normal bodies.
- **Mold is only offered while unfinished:** `defaults write com.simplmaker.SimplMaker moldWorkspace -bool YES`, or a debug run with `SIMPLMAKER_MOLD=1`. Remove the gate when v1 is good.
- **Rigid resin should block undercuts, silicone should only warn** (my reasoning: a flexible part can be peeled out of mild undercuts; not from a source).

## What other tools do (research, 2026-11-19)

Every tool follows the same steps: pick the pull direction and parting line (SolidWorks and Onshape run draft and undercut analysis first), make a block around the part and subtract the part, split at the parting plane, add registration keys, add a pour hole and air vents, then seal and clamp. Blender add-ons (MoldForge, MoldMaker) do all of it in one button, with 2–4 part splits, clamp wings, funnels and a silicone volume estimate.

- Parting line and keys: [MatterHackers](https://matterhackers.com/articles/how-to-use-3d-printing-to-make-two-part-silicone-molds), [Bucknell Makers](https://bucknellmakers.dozuki.com/Guide/Mold+Design/323)
- Draft and undercut analysis: [SolidWorks](https://help.solidworks.com/2019/English/SolidWorks/Sldworks/c_mold_tools_undercut_analysis.htm), [Onshape](https://cad.onshape.com/help/Content/View/draft_analysis.htm)
- Silicone draft is forgiving, about 1–2°: [Schroer](https://schroer.ca/2024/01/06/silicone-molds), [rysilicone](https://rysilicone.com/?p=10466)
- Printed halves leak; tongue-and-groove plus clamps: [All3DP](https://all3dp.com/2/3d-printed-molds-all-you-need-to-know-to-diy/?critical=1)
- One-button add-ons for comparison: [MoldForge](https://extensions.blender.org/add-ons/moldforge/), [MoldMaker](https://moldmaker.pages.dev/)
- A user's lessons: vents exactly on the parting line made slots that did not work, and keys can collide with vents ([Substack](https://gearsofresistance.substack.com/p/when-pretty-renders-lie)).
- Gaps in the sources: no reliable numbers for key clearance or gate sizing. Treat any defaults for those as ours to test.

## Geometry plan

Inputs: the body, the parting plane (an origin plane, construction plane or flat face), and the pour direction ("up"). The parting plane and the pour direction are separate: a vertical parting plane is still poured from the top.

Order inside the builder: box around the body (wall and margin) → subtract the body → cut the gate and the vents (cylinders along "up", **before** the split, so a hole on the parting plane becomes two half-channels) → add the cone keys and the seal lip → split at the plane → output `mold~<id>~top` / `~bottom` named like split pieces, shown in a folder so Export Folder sends both.

What already exists to build on: kernel calls `sk_boolean`, `sk_split`, `sk_body_section` (the part's exact outline at a plane, for placing keys in the margin ring), `sk_body_bounds`, `sk_body_volume`; `BodySlicer` (pure geometry on tessellation, for an undercut check and for finding vent positions at the cavity's high points); Draft, Pattern, Lay on Floor, Exploded View (to open the halves), Section Analysis (to inspect the cavity), Print Preview, browser folders with Export Folder, `check_design` and the MCP tools. No undercut or pull-direction analysis exists yet.

Risk to test first: OCCT subtracting a heavy body (an imported STL, 30k faces) from a block may be slow or fail. That may limit v1 to proper B-rep parts.

## UI plan (the Mold workspace, inside the ribbon that exists)

- The ribbon is the top bar. In Mold it shows the workspace button, then tool groups: **Parting · Gate & Vents · Keys · Seal & Clamp · Check · Export**, as live sections (not a locked wizard), each with a Lucide glyph from `IconGlyphs.swift`.
- The left panel lists the molds and their halves (instead of the part's browser); the inspector shows the settings of the active step; the timeline bar is hidden.
- The viewport shows the part ghosted inside the halves; the Exploded View slider opens them. Colour the faces by pull direction (OK / undercut / can't be released).
- Numbers: silicone volume (cavity plus gate), a thin-wall and small-gate warning, shrinkage scale for resin.
- Entry: the workspace button, right-click a body → "Make a Mold…", ⌘K.

## Phases

0. **Spike:** a test target that builds a mold by hand with the kernel (box minus part, then split) on two or three real parts and an imported STL. Timings and OCCT failures before any UI.
1. **Mold v1:** `Document.molds`, `MoldBuilder`, the studio screen: parting plane, wall, cone keys with clearance (asymmetric layout so the halves cannot go together wrong), a pour gate at the highest point along "up", manual vents, halves laid on the floor, export. Docs, an MCP `create_mold` tool and a design-guide topic.
2. **Guidance:** pull-direction colouring, undercut check, automatic vents, volume readout, warnings.
3. **Sealing and handling:** tongue-and-groove seam, clamp ears or bolt holes, shrinkage scale.
4. **Later:** several parts in one mold, 3–4 piece molds, a curved parting surface, cores for hollow parts, thin printed shells, the silicone-from-master box.

## Where the code is (branch `island-toolbar`)

- `Sources/SimplMaker/Workspace.swift`: the `Workspace` enum (`start`, `design`, `mold`, `render`), `hasTools`, `setWorkspace`, `ensureDesignWorkspace`, the `moldWorkspace` preference.
- `Sources/SimplMaker/Ribbon.swift`: `RibbonBar`, `WorkspaceButton`, `WorkspaceList`, `UndoRedoButtons`, and **`MoldToolbar`, the placeholder tool row to replace**; the glyph, colour, summary and contents of each workspace are in `Workspace`'s Mac extension.
- `Sources/SimplMaker/ContentView.swift`: `toolRow(_:)` switches on the workspace; the ribbon overlay and tab row; `chromeTop` / `barHeight`.
- `Sources/SimplMaker/DocumentModel.swift`: `workspace`.
- `Sources/CADCore/Document.swift` (add `molds` here), `Sources/CADKernel/Regenerator.swift` (where the builder runs).
- Docs: `docs/FEATURE-NOTES.md` (the end of it describes everything built in the last session: ribbon, Start page, tabs, traffic lights, launch behaviour), `website/src/docs/start/interface.md`.

## What the branch contains and what is not verified

`island-toolbar` is 11 commits ahead of `main`, not pushed, not merged: the ribbon as the window's top bar, the workspace button and list, Start and Render as workspaces, the full-window Start page, tabs drawn by the app (system tab bar hidden), parts opened as tabs, the launch fix (no system Open panel), traffic-light placement, the Mold placeholder. All `SimplMakerTests` pass except the known-flaky camera-animation test.

Not verified: the **iPad** build (the shared files should compile; `RecentParts.swift` is on its exclude list in `iPad/project.yml`); **macOS 15** (the old titlebar strip is gone, nothing seen there); window resize, full screen and the UI-hidden state with the new traffic-light placement; the Dock-icon reopen case; dragging the window by the ribbon; the tutorial's spotlight over the new ribbon; narrow windows (the tool row trims by `RibbonBar.chrome`); Sketch mode's tint was only seen with `SIMPLMAKER_FORCE_TINT=1`.

## Working rules and recipes that cost time to find

- **Spacing:** 6 pt between elements (`DS.Spacing.space3`); panels keep `Panel.inset` (8). `GridLayoutTests` fails on a bare number that is not a step of `DS.Spacing.scale`, including `-120` in a padding: use named constants.
- **Native macOS look,** following the platform's guidelines (traffic lights where Finder has them, etc.), but grouped like a ribbon, not as many bubbles.
- **Never kill the user's running SimplMaker** (it shares the bundle id with every dist copy). Stop only PIDs you started. A second copy of the same app may exit on its own.
- **Seeing the app:** copy `dist/SimplMaker.app`, set another `CFBundleIdentifier`, delete `Contents/PlugIns`, ad-hoc sign, run the binary with `SIMPLMAKER_MOLD=1` (`SIMPLMAKER_FORCE_TINT=1` for the sketch tint); grant computer-use for that new id only; `screencapture -l <window id>` takes one window and nothing else of the screen. A test copy that is not the active app has no key window and inactive traffic lights.
- **Crash traps found:** AppKit window queries off the main thread (the DocumentGroup `newDocument:` closure runs on an operation queue: use `OpenParts`); `titlebarAccessoryViewControllers` throws on non-titled windows; `value(forKey:)` with an unknown key; reading `UndoManager.canUndo` posts the checkpoint notification (never refresh on it).
- **Tabs:** `toggleTabBar` does nothing with several tabs and is one shared setting; the system tab bar is hidden by hiding its titlebar accessory. SwiftUI's `newDocument`/`openDocument` make separate windows: go through `PartWindows`.
- **Style of the user's feedback:** screenshots with arrows and short notes; wants it checked in the real window; likes things grouped and calm; says what to remove as much as what to add.

## Open questions for the Mold work

1. Illustrations: the workspace list uses an icon on a coloured tile. Should each workspace get a small drawn scene?
2. Should the mold's settings be undoable (own undo steps) like everything else? Probably yes: `Document.molds` through `mutate`.
3. Where do the halves appear in the Design browser, if at all?
4. Several bodies in one mold (multi-cavity) in v1 or later?
5. Which numbers to default for wall, key size and clearance (no reliable sources found; decide by test prints).

## Phase 0 results (2026-11-19, branch `mold-studio`)

Spike: `Tests/CADKernelTests/MoldSpikeTests.swift`, off by default. Run `SIMPLMAKER_MOLD_SPIKE=1 swift test --filter MoldSpike` (add `SIMPLMAKER_MOLD_SPIKE_ALL=1` for the big meshes; one of them takes minutes). Each case prints `MOLDSPIKE` lines with the time of every step and the volume checks. The STL cases read OCCT's sample meshes from `.build-occt/.../data/stl` (override with `SIMPLMAKER_SPIKE_STL_DIR`).

**Recipe that worked:** block (bbox + wall) → gate and vents fused into one tool → keys (cone pegs on one half, sockets with clearance in the other, each set fused first so it is one boolean) → part subtracted. Volumes always add up: block − part − channels = front + back − net key volume, to the mm³.

| Case | Faces | Cut part first (A) | Cheap order (B) |
|---|---|---|---|
| bracket, bottle, mug, figurine (B-rep) | 4–32 | 0.05–0.14 s | 0.03–0.04 s |
| STL shape (169 faces) | | 0.08 s | 0.05 s |
| STL sh1 (1438) | | 0.36 s | 0.16 s |
| STL sh2 (4089), propeller (6351) | | | 0.5–0.65 s |
| STL TR12J (15574) | | 4.3 s | 1.9 s |

Order B = `block − channels`, split the plain block, add keys to the plain halves, then subtract the part from each half. About 2× faster on heavy parts and every step on the plain block is free. Use B.

**Failures to design for:**
1. **A plane through a sphere's or revolve's seam gives invalid halves** (`isValid` false, no error): the figurine (spheres made by the kernel have the seam in the xz plane) split at y = 0. Nudging the plane by 0.05 mm fixes it; x = 0 (a different meridian) was fine. The builder must check `isValid` on both halves and retry with a tiny offset along the normal (and say so).
2. **A plane lying in a flat face of the part works** (bracket at the plate's top and underside): valid, volumes right.
3. **Imported STLs can be invalid solids.** `motor.stl` imports "successfully" but `isValid` is false; the part subtraction then took 48 s and the halves were wrong (volumes off by 240 000 mm³, one half in 3 solids). The builder must refuse a part that is not `isValid` ("fix the part first") before any boolean.
4. **STL import is the slow and fragile step, not the mold:** `bearing.stl` (24.7k triangles) and `TR12J_OCC64K.stl` (67.5k) are "not watertight" (the second after 78 s), `video_part.stl` too. `head.stl` is over the 100k limit. Mold needs no change for this, only a clear message.
5. The test parts are all CAD-like meshes with big flat faces; scanned organic meshes with 50k+ tiny faces are untested and likely the real worst case (v1 should say "B-rep and cleaned STL").

**Open numbers** (no sources, decide by test print): wall 8 mm, key radius 3 / height 3 / clearance 0.3, gate Ø 8, vent Ø 2 were used here only as spike defaults.

**Not covered by the spike:** the pour direction other than z (gate along a tilted "up" is the same rod, untested), keys that hit the cavity (keys sit in the margin ring, a part that fills the block's width would collide with them: the builder must clamp keys to the ring), a gate that misses the cavity (the spike starts it at the bbox middle; Phase 1 needs the highest point of the part along "up"), the tongue-and-groove seam.
