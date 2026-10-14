---
title: Extrude
description: Push a sketch profile or a flat face into a solid, one way, both ways, through everything or up to a face.
---

**Extrude** turns a flat shape into a solid. It is the tool you will use most. Key: [[E]].

## Use it

1. Press [[E]], or choose **Extrude** in the **Create** group. If nothing is selected, the status bar says *Select a profile or a flat face to extrude*.
2. Click a **profile** in a sketch. Its closed shapes show shaded. [[⇧]]-click to pick several.
3. An **arrow** and a **size field** appear in the viewport. Drag the arrow, or type a distance or an expression and press [[Return]].

![The extrude arrow, size field and operation buttons.](shot:extrude-handle)

Beside the field are buttons for what to do with the result:

| Button | Does |
|---|---|
| **New** | Makes a new body |
| **Join** | Adds to the body it touches |
| **Cut** | Removes material from the body |
| **Intersect** | Keeps only where the new shape and the body overlap |

There is also a flip button to reverse the direction, then **Cancel** and **OK**.

## Ways to extrude

The small arrow beside the Extrude button picks how far it reaches. The button then keeps using that way.

| Way | What it does |
|---|---|
| **One Direction** | A distance to one side of the sketch |
| **Two Directions** | A distance to each side, with an arrow and a field for each. [[Tab]] moves between them. |
| **Mirrored** | One length shared evenly, half to each side |

In the inspector, **Extent** also offers:

- **Through all**: goes through every body in its direction. Good for cutting holes.
- **To face**: stops at a flat face you picked that is parallel to the sketch. Select the face, then choose **To face**.

## Start from a face

An extrude normally starts on the plane of its sketch. To start somewhere else, click a **flat face** that is parallel to the sketch (the top of a wall, say), then choose **Start → Start from the Selected Face** in the panel next to the arrow. The profile is carried to that face and extruded from there, and the arrow moves with it. **Start on the Profile's Plane** puts it back.

## Taper the sides

A curved line with a **dot** hangs above the arrow. Drag the dot round the line to lean the sides, in whole degrees, or click it and type an angle (or an expression) in the field that opens beside it. A **negative** angle narrows the shape as it goes, a **positive** one widens it, and 0 makes the sides straight again. It reaches 85° either way.

With Two Directions or Mirrored, the sides lean away from the sketch plane on both sides, so the shape has a ridge there. A taper that would close the shape up before it reaches the end fails with a message, and the last good shape stays on screen.

## Choose which bodies it affects

When the **Operation** is **Join**, **Cut** or **Intersect**, the inspector lists the bodies that exist before the extrude under **Affected bodies**. Tick the ones it should work on.

- **Automatic** is the start. A **Cut** removes material from every body the shape passes through. A **Join** or **Intersect** works on the newest body.
- **Join** with more than one body ticked merges them all into one.
- **Cut** skips a ticked body the shape does not reach.
- Untick everything and the extrude has nothing to work on, so it shows an error.
- **Choose Automatically** goes back to the automatic choice.

![Affected bodies in the extrude inspector.](shot:inspector-extrude-targets)

## Extrude a face

Select a **flat face** of a body and press [[E]] to pull it out. A negative distance pushes it in. Only flat faces can be extruded.

## Inspector

![The extrude inspector.](shot:inspector-extrude)

| Field | What it does |
|---|---|
| **Extent** | One direction, Two directions, Mirrored, Through all, To face |
| **Start** | Where the extrude begins: the profile's plane, or a face you picked. |
| **Distance** | How far. It takes expressions. |
| **Taper** | The angle the sides lean, in degrees. Negative narrows, positive widens. It takes expressions. |
| **Operation** | New Body, Join, Cut or Intersect |
| **Affected bodies** | For Join, Cut and Intersect: which bodies the extrude works on. See above. |
| **Flip direction** | Extrudes the other way |
| **Profiles** | How many profiles are used. **Reselect…** lets you pick them again. |

## Tips

- To cut a hole, sketch it on the face, choose **Cut** and **Through all**.
- Use a **parameter** for the distance (`thickness`) so you can change it later.
