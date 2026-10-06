---
title: Files and saving
description: How parts are saved, autosave and versions, opening and importing files, and exporting.
---

## Parts are documents

SimplMaker is a normal Mac document app. Each part opens in its own window, with **New** ([[⌘N]]), **Open** ([[⌘O]]), **Open Recent**, **Save** ([[⌘S]]), **Duplicate** and **Revert To**. Macs can also group windows as tabs: **Window → Merge All Windows**.

Parts are saved as `.simplmaker` files.

## What is in a file

A `.simplmaker` file stores your **parameters and features**, and nothing else: the list of steps, not the geometry they produce. The geometry is rebuilt every time you open the file. That keeps files small and always consistent.

Reference images and imported STEP files are stored inside the part, so the part opens correctly without the original files.

## Autosave and versions

SimplMaker saves your work automatically and keeps earlier versions. Choose **File → Revert To → Browse All Versions…** to look back and restore one.

## Open example parts

**File → Open Example Parts** opens one of the built-in examples as a new untitled part. See [Examples and the tutorial](doc:start/examples-and-tutorial).

## Import

| Command | What it does |
|---|---|
| **File → Import STEP…** ([[⇧⌘I]]) | Adds a `.step` or `.stp` file as an **Import** feature: one body with every solid in the file, named after the file, in millimetres whatever unit the file uses. You can then fillet, cut, shell, move or rotate it like any other body. |
| **File → Import SVG as Sketch…** | Turns an SVG drawing into a sketch. See [Importing SVG](doc:sketch/import-svg). |
| **Create → Canvas (Reference Image)…** | Places a picture to trace over. See [Canvas](doc:create/canvas). |

In the **Import** feature's inspector, **Replace File…** swaps in a new version of the file. Features after it keep their edges and faces as long as the new file lists its faces in the same order.

## Export

| Command | What it does |
|---|---|
| **File → Export STL…** | Writes every body in the part into one `.stl` file, for slicers |
| **File → Export STEP…** | Writes every body into one `.step` file, for other CAD tools |

To export a single body, right-click it in the browser and choose **Export Body → STL…** or **STEP…**.

See [Exporting for printing](doc:print/export) for what to check before you slice.
