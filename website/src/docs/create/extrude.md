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

## Extrude a face

Select a **flat face** of a body and press [[E]] to pull it out. A negative distance pushes it in. Only flat faces can be extruded.

## Inspector

![The extrude inspector.](shot:inspector-extrude)

| Field | What it does |
|---|---|
| **Extent** | One direction, Two directions, Mirrored, Through all, To face |
| **Distance** | How far. It takes expressions. |
| **Operation** | New Body, Join, Cut or Intersect |
| **Flip direction** | Extrudes the other way |
| **Profiles** | How many profiles are used. **Reselect…** lets you pick them again. |

## Tips

- To cut a hole, sketch it on the face, choose **Cut** and **Through all**.
- Use a **parameter** for the distance (`thickness`) so you can change it later.
