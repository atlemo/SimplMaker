---
title: Box, cylinder, sphere, torus and coil
description: Place ready-made shapes on a plane or a face, then change their sizes.
---

The **Shapes** group places a ready-made solid in one step. They are quicker than a sketch when the shape is simple.

| Tool | Key | Makes |
|---|---|---|
| **Box** | [[X]] | A rectangular block |
| **Cylinder** | [[Y]] | A round post or a disc |
| **Sphere** | [[G]] | A ball |
| **Torus** | [[U]] | A ring, like a doughnut |
| **Coil** | [[K]] | A spring |

## Place one

1. Press the tool's key, or choose it in the **Shapes** group.
2. Click an **origin plane** or a **flat face**. The shape appears where you clicked, at a size that suits the model (20 mm, or about a fifth of the model).
3. Drag the arrow, or type a size in the field next to it, and press [[Return]].

![A box being placed, with its size field.](shot:primitive-box)

If a flat face is already selected, the shape goes straight onto it, at the face's centre.

Placed on the empty planes, it makes a **new body**. Placed on a face of a body, it **joins** that body. Use the buttons beside the field to choose **Cut** instead, to make a pocket, or **Intersect**.

## Inspector

![The box inspector.](shot:inspector-box)

| Shape | Fields |
|---|---|
| **Box** | Width, Length, Height |
| **Cylinder** | Diameter, Height |
| **Sphere** | Diameter |
| **Torus** | Diameter, Tube Ø |
| **Coil** | Diameter, Section Ø, Pitch, Turns |

Every shape also has an **Operation** (New Body, Join, Cut or Intersect) and a **Position** (X and Y) on the plane or face it sits on. All sizes take expressions.

For a coil, **Diameter** is the size across the coil, **Section Ø** is the thickness of the wire, **Pitch** is the distance from one turn to the next, and **Turns** is how many turns.

## Tips

- A cylinder with the **Cut** operation makes a clean round pocket or a through-hole.
- A box cut into another box makes a slot. Use [Combine](doc:modify/combine) to cut one existing body from another.
