---
title: Project Edge
description: Bring edges of a body, or where a plane cuts it, into a sketch so shapes can line up with them and follow the body when it changes.
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

## Curves of other sketches

Project Edge also takes curves of **other sketches**: a profile's outline, a centre line, anything drawn in a sketch that comes before this one in the timeline and is shown in the browser. Press [[U]] and click the curve. It is flattened onto the plane you are drawing on and follows its own sketch from then on.

- A **line** comes in as a construction line.
- A **circle or arc** on a plane parallel to yours comes in as itself, with its centre as a point.
- A circle, arc or ellipse seen **edge-on** comes in as the straight stretch it covers. The middle of that line is the circle's centre, which is handy for ending a [loft's path](doc:create/loft) on it.
- A **spline**, and a circle seen at a slant, come in as curves.

A sketch that comes later in the timeline can't be projected, since each would have to wait for the other.

## Limits

- A **circular** edge is projected only when it faces the sketch. A circle seen at a slant is brought in as curves instead.
- An edge that points straight at the sketch plane has no length in the sketch, so it can't be projected. SimplMaker says so.
- An edge that is already projected is not added twice.

## Intersect

**Intersect** brings in the curves where the sketch plane **cuts through a body**. Choose it under **References** in the **Create** list, or press [[Q]]. Then click a body, on any face or edge. Every curve of the cut comes in at once: a cylinder cut across gives a circle, a box gives its outline as lines, a slanted cut gives curves.

- The curves are construction lines, arcs and circles with fixed points, just like a projected edge. Draw on them, constrain to them and dimension to them.
- They **follow the body**. When you change the body, or move the sketch's plane, the cut is made again and each curve moves to where its piece of the cut is now. SimplMaker finds each piece again by the face of the body it lies on.
- The tool stays on for more bodies. [[Esc]] ends it.
- Clicking a body whose cut is already in the sketch changes nothing and says so. If the plane doesn't cut the body, it says that.

If a change makes the plane miss the body, or changes the cut so that a piece is gone, those curves go stale, like a projected edge whose edge was removed. Use **Project Again** or **Clean Up Stale Projections** below.

## Project Again

**Project Again** gives a projected edge a **new edge to follow**, and keeps everything tied to it. It is for a projection that has gone stale, or one you want to move to a different edge. Choose it under **References**, or press [[W]].

1. Select the projected curve first, or press [[W]] and click it. If only one projection is stale, it is taken for you. It is shown selected.
2. Click the new edge: an edge of a body, or a curve of another sketch.

The projection keeps its points and curves, so the shapes, constraints and dimensions that rest on them stay, and now follow the new edge.

- The new edge must be **the same kind**: a straight edge for a straight projection, a circle for a circle, an arc for an arc, a curve for a curve. If it isn't, SimplMaker says what it needs and waits for another edge.
- A straight projection takes the **direction** of the new edge, so its two ends may swap places.
- An edge that is projected already, or that points straight at the sketch, is refused.

A sketch whose projected edge is gone still opens, so you can fix it this way.

## Tidy up projections

Projecting leaves construction lines and fixed points in the sketch. Two commands under **References** in the **Create** list remove them again.

- **Clean Up Projections** removes the projected edges that nothing uses: no drawn shape ends on their points, and no constraint or dimension refers to them. A projection you have drawn from or dimensioned stays.
- **Clean Up Stale Projections** removes the projected edges whose edge is gone from the model, for example after you changed an earlier feature so the edge no longer exists. Whatever was tied to them goes with them, as with any delete.

Both say how many they removed. If there was nothing to remove, they say that instead, and the sketch is left as it was.

## Snapping

Edges of the body that already lie in the sketch plane, such as the outline of the face you are sketching on, are also snapping points while you draw. Projecting an edge keeps a link to it, so the sketch holds onto the edge itself, not just to where it sits now.

## Next

[Dimensions](doc:sketch/dimensions)
