---
title: Exporting for printing
description: Export STL for your slicer and STEP for other CAD tools. What is exported, in what units, and what to check first.
---

## Export an STL

1. Choose **File → Export STL…**.
2. Pick a name and a place.
3. Open the file in your slicer, for example PrusaSlicer, Bambu Studio, Cura or OrcaSlicer.

The numbers in the file are **millimetres**, which is what slicers expect. Your part arrives at the size you modelled it.

| Command | What is exported |
|---|---|
| **File → Export STL…** | Every body in the part, in one `.stl` file. Hidden bodies are included. |
| **File → Export STEP…** | Every body in the part, in one `.step` file |
| Right-click a body in the browser → **Export Body → STL…** or **STEP…** | Just that body |
| Right-click a folder in the browser → **Export Folder → STL…** or **STEP…** | Every body in the folder and in the folders inside it, in one file |

The STL is written with a fine surface tolerance (0.02 mm), so curves print smooth.

:::tip
Making several parts in one file? Give each its own body, and use **Export Body** to write them one at a time. That keeps every STL ready to print. To write a group of bodies as one file, put them in a folder and use **Export Folder**.
:::

## Export a STEP

STEP keeps the real, exact shapes, not a mesh of triangles. Use it to move a part to another CAD tool or to a machine shop. Choose **File → Export STEP…**.

## Before you slice

A quick check before you export:

1. **Everything rebuilt without errors.** Look along the [timeline](doc:concepts/timeline) for red triangles.
2. **One body per part.** The browser's **Bodies** folder should list what you intend to print.
3. **Sizes are right.** Use [Measure](doc:modify/measure) on the walls and the holes that matter.
4. **The part sits flat.** Model it with its bottom on the XY plane (Z is up), so it comes out of the slicer ready to print. Or rotate it in the slicer.

## What is not exported

- **Colours.** They are only for the viewport.
- **Sketches and construction planes.** Only solid bodies are exported.
- SimplMaker exports STL and STEP. **3MF** is not available.

## Import

To bring other files in, see [Files and saving](doc:concepts/files).
