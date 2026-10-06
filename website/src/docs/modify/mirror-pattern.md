---
title: Mirror and pattern
description: Copy bodies across a plane, in a row, or around an axis.
---

Both tools make copies of whole bodies. They are in the **Construct** group, and in the **Modify** menu.

## Mirror

**Mirror** copies bodies across a plane. Key: [[Q]].

1. Press [[Q]] for **Mirror**. The origin planes appear.
2. Click the **bodies** to copy: any face or edge, or pick them in the browser.
3. Click the **plane** to mirror across. An origin plane, or a [construction plane](doc:create/plane).

![Mirror, from the inspector.](shot:inspector-mirror)

| Field | What it does |
|---|---|
| **Across** | The plane the copy is mirrored across |
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

- To repeat shapes *inside a sketch* instead, use [Pattern in a sketch](doc:sketch/transform). It makes sketch curves, not bodies.
- Keep **New body** when each copy needs its own thread or colour.
