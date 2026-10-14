---
title: Files and saving
description: How parts are saved, autosave and versions, opening and importing files, and exporting.
---

## Parts are documents

SimplMaker is a normal Mac document app. Each part opens as a **tab** in the same window, and the tab bar shows even when only one part is open. The part's name is in its tab. Use **New** ([[⌘N]]), **Open** ([[⌘O]]), **Open Recent**, **Save** ([[⌘S]]), **Duplicate** and **Revert To** as in any Mac app. The **+** at the right end of the tab bar starts a new part.

To give a part a window of its own, drag its tab out of the tab bar, or choose **Window → Move Tab to New Window**. **Window → Merge All Windows** brings separate windows back together as tabs.

Parts are saved as `.simplmaker` files.

## What is in a file

A `.simplmaker` file stores your **parameters and features**, and nothing else: the list of steps, not the geometry they produce. The geometry is rebuilt every time you open the file. That keeps files small and always consistent.

Reference images and imported STEP and STL files are stored inside the part, so the part opens correctly without the original files.

## Autosave and versions

SimplMaker saves your work automatically and keeps earlier versions. Choose **File → Revert To → Browse All Versions…** to look back and restore one.

## Open example parts

**File → Open Example Parts** opens one of the built-in examples as a new untitled part. See [Examples and the tutorial](doc:start/examples-and-tutorial).

## Copy and paste bodies

Select a body and choose **Edit → Copy** ([[⌘C]]). Then **Edit → Paste** ([[⌘V]]) into the same part, into another part, or into a window of another document. The body travels as a STEP file on the clipboard.

A pasted body arrives as an **Import** body, like any [imported](doc:concepts/files#import) part: its history stays behind, so you can fillet, cut or move it, but you cannot go back into the sketches that made it. The **Move** tool opens at once, so you can slide the copy off the original.

To make a copy that keeps its history, use [Pattern](doc:modify/mirror-pattern) or **File → Duplicate** for the whole part.

## Import

| Command | What it does |
|---|---|
| **File → Import → STEP…** ([[⇧⌘I]]) | Adds a `.step` or `.stp` file as an **Import** feature: one body with every solid in the file, named after the file, in millimetres whatever unit the file uses. You can then fillet, cut, shell, move or rotate it like any other body. |
| **File → Import → STL…** | Adds a `.stl` mesh (binary or ASCII) the same way, read in millimetres. The mesh must be watertight. Its triangles are sewn into a solid and the ones in the same plane are merged into single faces, so a box has six faces. Curved shapes stay faceted. Meshes of more than 30,000 triangles are slow to import, so SimplMaker offers to **reduce** them first (Fine, Medium or Coarse): flat faces and sharp edges stay as they are and curved surfaces get a little coarser. Meshes of more than 100,000 triangles can only be imported reduced. The part keeps the reduced mesh, not the original file. |
| **File → Import → SVG as Sketch…** | Turns an SVG drawing into a sketch. See [Importing SVG](doc:sketch/import-svg). |
| **Create → Canvas (Reference Image)…** | Places a picture to trace over. See [Canvas](doc:create/canvas). |

In the **Import** feature's inspector, **Replace File…** swaps in a new STEP or STL version of the file. Features after it keep their edges and faces as long as the new file lists its faces in the same order.

## Export

| Command | What it does |
|---|---|
| **File → Export STL…** | Writes every body in the part into one `.stl` file, for slicers |
| **File → Export STEP…** | Writes every body into one `.step` file, for other CAD tools |

To export a single body, right-click it in the browser and choose **Export Body → STL…** or **STEP…**.

See [Exporting for printing](doc:print/export) for what to check before you slice.
