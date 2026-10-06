---
title: Hole
description: Drill simple, counterbored or countersunk holes in a flat face, with exact size and position.
---

**Hole** drills into a flat face. Key: [[H]]. It is in the **Modify** group.

## Use it

1. Press [[H]] for **Hole**.
2. Click a **flat face** where the hole should go. It is placed where you clicked, and snaps to the centre of the face (or of a line through it) when you click close to it.
3. Set the size in the inspector, and press **OK**.

If a flat face is already selected, the hole goes at the face's centre.

![A hole being placed, with its diameter and depth fields.](shot:hole-handle)

## Inspector

![The hole inspector.](shot:inspector-hole)

| Field | What it does |
|---|---|
| **Type** | **Simple**, **Counterbore** or **Countersink** |
| **Diameter** | The hole's diameter |
| **Extent** | **Distance** (a set depth) or **Through all** |
| **Depth** | How deep, when the extent is a distance |
| **Drill point** | The angle of the drill tip at the bottom of a blind hole. It starts at `118 deg`. |
| **Counterbore Ø** and **Counterbore depth** | The wider recess for a screw head |
| **Countersink Ø** and **Countersink angle** | The cone for a flat-head screw |
| **Position X** and **Y** | Where the hole is on the face, measured from the face's own origin |

All values take expressions.

## Hole types

- **Simple:** a plain round hole.
- **Counterbore:** a hole with a wider, flat-bottomed recess at the top, so a cap screw sits below the surface.
- **Countersink:** a hole with a cone at the top, for a flat-head screw.

## Make a hole for a screw

1. Look up the screw's size. An M3 screw needs a clearance hole of about 3.4 mm in most prints. Add a small amount for printing. See [Designing for printing](doc:print/design-tips).
2. Store it as a parameter: `screw_hole = 3.4 mm`.
3. Use that parameter for **Diameter**.

To make **threads** in a hole, see [Thread](doc:modify/thread).
