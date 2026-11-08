---
title: Mirror and pattern
description: Copy bodies across a plane or along an axis or edge, in a row, or around an axis, and repeat a projection, cut or hole.
---

Mirror copies whole bodies. Pattern copies bodies, or repeats a feature such as a debossed logo or a cut. Both are in the **Construct** group, and in the **Modify** menu.

## Mirror

**Mirror** copies bodies across a plane, or along an axis or a straight edge. Key: [[Q]].

1. Press [[Q]] for **Mirror**. The origin planes appear.
2. Click the **bodies** to copy: any face, or pick them in the browser.
3. Finish with one more click:
   - the **plane** to mirror across: an origin plane, a [construction plane](doc:create/plane), or a flat face; or
   - a **straight edge** to mirror along.

### Along an edge or an axis

The mirror plane holds the line and stands square to the plane the line lies in, so the copy is a true mirror image, not just a turned copy. For an **edge**, that is the first flat face next to it. Mirror along the bottom edge of a part and the copy lies flat against it. For the **X** and **Y** axes it is the floor: along X swaps front and back, along Y swaps left and right. Along **Z** swaps left and right.

The first click always picks a body, even if it lands on an edge. An edge picked after a body is the line.

In the inspector, **Across** switches between the plane and the X, Y or Z axis, and **Mirror Along the Selected Edge** takes the edge you have selected.

![Mirror, from the inspector.](shot:inspector-mirror)

| Field | What it does |
|---|---|
| **Across** | The plane the copy is mirrored across, or the axis or edge it is mirrored along |
| **Copies** | **Join to the body** makes it one body, or **New body** keeps the copy separate |
| **Bodies** | The bodies being copied |

## Pattern

**Pattern** repeats bodies, or features, in a row or around an axis. Key: [[T]].

The bar at the bottom has two switches while the tool waits: **Bodies | Features** (what to repeat) and **Objects | Axis** (what the next click picks).

1. Press [[T]] for **Pattern**.
2. Pick what to repeat:
   - **Bodies**: click the bodies to copy.
   - **Features**: click a projection, cut, join or hole. Click its face in the model, or the feature in the timeline. Each copy goes in the way the original did: the same cut or join, into the same bodies.
3. Pick the axis. Click an **edge** at any time, or switch to **Axis** and click a **round face**:
   - a **round face** (the wall of a cylinder) or a **circular edge** makes a circular pattern *around* it, wherever it is;
   - a **straight edge** makes a row *along* it.

The pattern is made as soon as something to repeat and an axis are picked. Pick all the bodies or features first. **Return** makes a row along X without an axis. The count and the angle or spacing are then edited in the inspector, with the model rebuilding as you type.

You can also right-click a feature in the timeline or browser and choose **Repeat in a Circle…** or **Repeat in a Row…**.

The copies of a feature are the original cut or projection moved or turned, not projected again. Around the axis of a cylinder that is exact. On a shape that is not round about the axis, the copies do not follow the surface.

![A circular pattern of bolts.](shot:pattern-edit)

### Inspector

![The pattern inspector.](shot:inspector-pattern)

| Field | What it does |
|---|---|
| **Kind** | **Linear** (in a row) or **Circular** (around an axis) |
| **Count** | How many copies in all. It includes the original. |
| **Spacing** (linear) | The distance between copies |
| **Angle** (circular) | How far the copies spread. 360° goes all the way round. |
| **Along** or **Around** | The X, Y or Z axis, a straight or circular edge, or a round face. **Use the selected edge** and **Use the selected round face** pick them. |
| **Copies** | Join to the body, or New body (not for features: they go in as the original did) |
| **Bodies** or **Repeats** | The bodies or features being repeated |

Count, spacing and angle take expressions, so a pattern can follow a parameter, for example `bolt_count`.

## Tips

- To repeat or mirror shapes *inside a sketch* instead, use [Pattern or Mirror in a sketch](doc:sketch/transform). They make sketch curves, not bodies.
- Keep **New body** when each copy needs its own thread or colour.
