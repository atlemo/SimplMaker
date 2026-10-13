---
title: Mirror and pattern
description: Copy bodies across a plane or along an axis or edge, in a row, or around an axis.
---

Both tools make copies of whole bodies. They are in the **Construct** group, and in the **Modify** menu.

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

**Pattern** repeats bodies in a row or around an axis. Key: [[T]].

1. Press [[T]] for **Pattern**.
2. Click the **bodies** to copy.
3. Optionally click a **straight edge** to set the direction. Press [[Return]] to make the pattern.

![A circular pattern of bolts.](shot:pattern-edit)

### Inspector

![The pattern inspector.](shot:inspector-pattern)

| Field | What it does |
|---|---|
| **Kind** | **Linear** (in a row) or **Circular** (around an axis) |
| **Count** | How many copies in all. It includes the original. |
| **Spacing** (linear) | The distance between copies |
| **Angle** (circular) | How far the copies spread. 360° goes all the way round. |
| **Along** or **Around** | The X, Y or Z axis, or a straight edge. **Use the selected edge** picks an edge. |
| **Copies** | Join to the body, or New body |
| **Bodies** | The bodies being copied |

Count, spacing and angle take expressions, so a pattern can follow a parameter, for example `bolt_count`.

## Tips

- To repeat or mirror shapes *inside a sketch* instead, use [Pattern or Mirror in a sketch](doc:sketch/transform). They make sketch curves, not bodies.
- Keep **New body** when each copy needs its own thread or colour.
