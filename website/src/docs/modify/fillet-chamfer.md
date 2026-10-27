---
title: Fillet and chamfer
description: Round or bevel the edges of a solid, with a size you can type, drag or set from a parameter.
---

**Fillet** rounds an edge. **Chamfer** bevels it. Keys: [[F]] for fillet, [[C]] for chamfer. They are in the **Modify** group.

## Use it

1. Click **edges** in the viewport. [[⇧]]-click to add more. Or click a **face** to treat every edge around it.
2. Press **Fillet** or **Chamfer**. Or press the tool first and pick afterwards, then [[Return]].
3. An arrow and a size field appear. Drag the arrow, or type a **radius** or **distance**, and press [[Return]].

![The fillet handle and its radius field.](shot:fillet-handle)

The size can be an expression such as `corner_r / 2`. While you drag, an edge that can't take that size stops the preview, and the inspector says *Too large for the neighbouring faces*.

## Chamfer types

The small arrow beside the Chamfer button picks how it is measured.

| Type | You set |
|---|---|
| **Equal Distance** | One distance, the same on both faces |
| **Distance and Angle** | A distance on one face, and the angle to it |
| **Two Distance** | A distance on each face |

The last two show an arrow and a size field for each value. [[Tab]] moves between them. **Flip** puts the first distance on the edge's other face. With faces picked, the first distance is on the picked face.

## Inspector

![The fillet inspector.](shot:inspector-fillet)

| Field | What it does |
|---|---|
| **Radius** (fillet) | How round it is |
| **Type**, **Distance**, **Angle** or **Distance 1/2** (chamfer) | As above |
| **Measure on the other face**, **Swap the two faces** | The chamfer's flip switch |
| **Edges** and **Faces** | What is rounded. Remove one with its minus button, or add more selected ones. |

![The chamfer inspector.](shot:inspector-chamfer)

## When it fails

A fillet or chamfer that is too big for its neighbouring faces shows an error. Make it smaller. SimplMaker refuses a round it cannot build correctly, such as a chamfer as big as the radius of a rounded corner, or a fillet wider than its face, instead of showing a wrong shape. A fillet can also fail if a later edit moves the edge it was attached to. See [Troubleshooting](doc:reference/troubleshooting).

If the kernel struggles with a round, SimplMaker tries again in a few other ways before it gives up, and if the kernel itself falters you get an ordinary error and your part stays as it was.

### An outline made of many short lines

A curve drawn as dozens of short straight lines (a traced picture, an imported polyline, a sole drawn point by point) cannot be rounded or chamfered at any size. The kernel takes walls that turn by less than about 6° for one smooth surface, so the whole outline becomes a single chain of almost-smooth edges, and it cannot follow that. The error says so: *the edge is part of an outline of 151 short straight pieces*.

Draw the outline as a **spline** (the [Spline tool](doc:sketch/draw), [[B]]) or as arcs instead. The same outline drawn as a spline rounds without trouble.

## Tips

- To keep a part strong when printing, fillet the inside corners where it carries load.
- Chamfer the bottom edge of a part that sits on the bed, to avoid the "elephant's foot" bulge on the first layer. The size depends on your printer.
