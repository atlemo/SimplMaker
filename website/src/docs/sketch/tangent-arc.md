---
title: Tangent Arc
description: Carry a line or arc on with an arc that leaves its end smoothly, and keep going from the new end.
---

A **tangent arc** continues a line or an arc without a kink. It leaves the end of the line smoothly, in the same direction, and curves to the point you choose. Press [[N]] for the **Tangent Arc** tool.

## Draw one

1. Press [[N]].
2. Click the **free end** of a line or arc: the endpoint that nothing else joins. A corner where two lines meet is not a free end.
3. Click where the arc should end. A preview of the arc follows the pointer, so you can see it before you click.
4. The tool carries on from the new end, like a chain of lines. Click again to draw the next arc, or press [[Esc]] to stop.

The arc is tied to the line or arc it continues with a **Tangent** constraint, so the join stays smooth if you move things later. See [Constraints](doc:sketch/constraints).

## Where it can reach

An arc can only reach a point that lies ahead of its start, in the direction the line or arc is heading. A point behind the start, or exactly along the extension of the line, can't be reached with a tangent arc. If you click one, SimplMaker says so and keeps the start point, so click a different end point.

If the first click is not on a free end, SimplMaker asks you to start on one, because the arc has to carry on from an existing line or arc.

## Next

[Ellipse](doc:sketch/ellipse)
