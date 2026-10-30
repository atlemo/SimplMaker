---
title: Exporting for printing
description: Export STL or 3MF for your slicer and STEP for other CAD tools. What is exported, in what units, and what to check first.
---

## Export an STL

1. Choose **File → Export…**.
2. Set **Format** to **STL** and choose **All bodies as one single part**. Click **Export…**.
3. Pick a name and a place.
4. Open the file in your slicer, for example PrusaSlicer, Bambu Studio, Cura or OrcaSlicer.

The numbers in the file are **millimetres**, which is what slicers expect. Your part arrives at the size you modelled it.

| Command | What is exported |
|---|---|
| **File → Export…**, *All bodies as one single part* | Every body in the part, in one `.stl`, `.3mf` or `.step` file. Hidden bodies are included. |
| **File → Export…**, *All bodies as individual parts* | One file for each body, named after the body, in a folder you choose. Files already there are never overwritten. |
| Right-click a body in the browser → **Export Body → STL…**, **3MF…** or **STEP…** | Just that body |
| Right-click a folder in the browser → **Export Folder → STL…**, **3MF…** or **STEP…** | Every body in the folder and in the folders inside it, in one file |

The STL is written with a fine surface tolerance (0.02 mm), so curves print smooth.

:::tip
Printing several parts one at a time? Choose **All bodies as individual parts** in the Export dialog, so every STL is ready to print. To write a group of bodies as one file, put them in a folder and use **Export Folder**.
:::

## Export a 3MF

3MF is the format most slicers now prefer. It is a mesh like STL, but it also says the numbers are **millimetres**, keeps each body as a named object in one file, and carries the **colour** you gave each body in [Appearance](doc:modify/appearance), so a multi-colour slicer such as Bambu Studio or PrusaSlicer shows them. Choose **File → Export…** and set **Format** to **3MF**.

## Export a STEP

STEP keeps the real, exact shapes, not a mesh of triangles. Use it to move a part to another CAD tool or to a machine shop. Choose **File → Export…** and set **Format** to **STEP**.

## Before you slice

A quick check before you export:

1. **Everything rebuilt without errors.** Look along the [timeline](doc:concepts/timeline) for red triangles.
2. **One body per part.** The browser's **Bodies** folder should list what you intend to print.
3. **Sizes are right.** Use [Measure](doc:modify/measure) on the walls and the holes that matter.
4. **The part sits flat.** Model it with its bottom on the XY plane (Z is up), so it comes out of the slicer ready to print. Or rotate it in the slicer.

## What is not exported

- **Colours**, except in a 3MF. STL and STEP leave them out.
- **Sketches and construction planes.** Only solid bodies are exported. To cut a flat shape on a laser cutter or CNC router, export the sketch as DXF instead: see [DXF](doc:sketch/dxf).

## Import

To bring other files in, see [Files and saving](doc:concepts/files).
