---
title: Editing curves
description: Select and drag, round corners, trim, extend and offset curves in a sketch.
---

## Select and move

Press [[S]] for the **Select** tool.

| Do this | To |
|---|---|
| **Click** a point, a curve or a dimension | Select it. [[⇧]]-click adds more. |
| **Double-click** a curve | Select all the curves joined to it |
| **Drag** a point, a line or a circle's rim | Move it. The geometry follows as far as the constraints allow. |
| [[⌫]] | Delete the selection |

How far things can move depends on the [constraints](doc:sketch/constraints). A free sketch moves freely. A fully constrained one stays put.

## Round Corner

Press [[F]], then click the point where two lines meet. SimplMaker rounds it with an arc. Change the radius with a dimension afterwards.

:::note
This rounds a *sketch* corner. To round the edges of a solid, use [Fillet](doc:modify/fillet-chamfer).
:::

To cut a sketch corner straight across instead, use the [Chamfer](doc:sketch/chamfer) tool.

## Trim

Press [[T]], then click the part of a curve you want to remove. It is cut away up to where other curves cross it.

## Extend

Press [[E]], then click near the end of a line or arc. It grows until it meets the next curve.

## Offset

Offset draws a copy of curves at a set distance from them.

1. Select the curves. Lines, arcs, circles and splines all work.
2. Press **Offset**. The offset shows live beside the originals, with an arrow on it.
3. Drag the arrow to set the distance, or type a number or expression in the field next to it. Drag back through the curve, or type a negative number, to go to the other side.
4. Press [[Return]] or **OK** to keep it. [[Esc]] or **Cancel** takes it back.

A positive distance goes outward on a closed shape, and to the left of an open chain's direction.

Lines and arcs stay linked to their originals by a distance dimension. An offset of a spline is a close fit made of several curves, with no dimension, and it is refused when the distance is more than the curve's tightest bend allows on the inside.

## Construction

Select curves and press **Construction** to toggle them between normal and construction geometry. See [Drawing tools](doc:sketch/draw).
