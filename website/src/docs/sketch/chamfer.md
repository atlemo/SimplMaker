---
title: Sketch chamfer
description: Cut a sketch corner straight across, where two lines meet, and change the size of the cut.
---

The sketch **Chamfer** bevels a corner of a sketch: it cuts the point where two lines meet straight across, with a new line. Press [[H]] for the **Chamfer** tool. It works on the corners of rectangles and polygons, and on any other point where exactly two lines meet.

:::note
This chamfers a *sketch* corner. To bevel the edges of a solid, use [Fillet and chamfer](doc:modify/fillet-chamfer). To round a sketch corner instead of cutting it, use [Round Corner](doc:sketch/edit#round-corner).
:::

## Chamfer a corner

1. Press [[H]].
2. Click the corner point where the two lines meet. SimplMaker cuts the corner at 2 mm by default.
3. The corner is cut across, with a new line between the two cut points.

If the lines are too short for a 2 mm cut, SimplMaker uses 1 mm instead, then 0.5 mm, then 0.2 mm. It picks the largest size that fits.

## Change the size

The cut is sized by its **leg**: the distance from the corner along each of the two lines. The two legs are kept equal, and one dimension sets them. Change that dimension to change the size of the cut, as described in [Dimensions](doc:sketch/dimensions).

## When it can't chamfer

- The corner must be a point where exactly two lines meet. If you click somewhere else, SimplMaker asks you to click the corner point.
- A corner that is already round, such as the arc of a rounded rectangle, can't be chamfered.
- A join that is almost straight, or that folds back almost on itself, can't be chamfered. SimplMaker says the corner can't be chamfered.

## Next

[Project Edge](doc:sketch/project-edge)
