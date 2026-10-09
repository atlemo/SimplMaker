---
title: Importing SVG
description: Turn an SVG drawing into a sketch you can extrude, cut and dimension.
---

Bring a logo, outline or drawing into SimplMaker as a sketch.

## Import

1. Select a flat face or a plane, or nothing to use the XY plane. Or open the sketch you want to add the drawing to.
2. Choose **File → Import → SVG as Sketch…** and pick a file.

The drawing's middle goes on the sketch origin. The result is plain, unconstrained geometry that you can dimension and edit like anything you drew yourself.

## What is read

- Paths: lines, arcs, and cubic and quadratic curves
- Rectangles, circles, ellipses, polygons and polylines
- Groups, `transform`s and `<use>` are applied

Circles and circular arcs stay exact. Closed shapes become **profiles** you can extrude or cut.

**Text and images are left out.** Convert text to outlines in your drawing program first.

## Size

The drawing is sized in **millimetres** from the file's `width`/`height` and `viewBox`. A file with no size is read at 96 pixels to the inch.

If it comes in the wrong size, select the sketch and use [Scale](doc:sketch/transform).

:::tip
Export your drawing from the vector program with simple paths and no clipping masks. Fewer curves mean a lighter, more reliable sketch.
:::
