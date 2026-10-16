---
title: Project Edge
description: Bring straight edges of a body into a sketch, so shapes can line up with them and follow the body when it changes.
---

**Project Edge** brings straight edges of a body into the sketch you are drawing. The edge appears in the sketch as a construction line, and its two ends become points that stay where the edge is on the body. Press [[U]] for the **Project Edge** tool.

## Use it

1. Start a sketch on a face or plane. See [Starting a sketch](doc:sketch/start).
2. Press [[U]].
3. Click a straight edge of a body. It is brought into the sketch.
4. Click other edges to bring them in too. Press [[Esc]] when you are done.

## What you get

- The edge is a **construction line**, drawn dashed. It guides the sketch and never makes a solid profile on its own.
- Its two ends are points. Their position is fixed by the body, so you can't drag them. You can still constrain other shapes to them, and dimension to them. For example, a hole can be placed a set distance from a projected edge.
- The edge can come from any face of the body. It is flattened onto the sketch plane, so you see it where it falls in the sketch.

The projection follows the body. When you change a parameter or an earlier feature, the ends move to where the edge is now, and anything tied to them moves too.

:::note
If a later change removes the edge, the rebuild reports that the projected edge is missing. Undo the change, or change the feature that removed the edge.
:::

## Limits

- Only **straight** edges can be projected for now. Click a curved edge and SimplMaker says so.
- An edge that points straight at the sketch plane has no length in the sketch, so it can't be projected. SimplMaker says so.
- An edge that is already projected is not added twice.

## Snapping

Edges of the body that already lie in the sketch plane, such as the outline of the face you are sketching on, are also snapping points while you draw. Projecting an edge keeps a link to it, so the sketch holds onto the edge itself, not just to where it sits now.

## Next

[Dimensions](doc:sketch/dimensions)
