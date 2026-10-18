---
title: Move, rotate and scale
description: Slide and turn bodies and sketches with one manipulator, or type exact values. Scale bodies and sketches by a factor.
---

## Move and rotate

**Move** moves and turns bodies and sketches. Key: [[M]]. It is in the **Modify** group.

1. Press [[M]] for **Move**.
2. Click the **bodies** or **sketches** to move. Pick them in the viewport, or in the browser.
3. A manipulator appears on them. Drag it, or type a value in the field beside it.

![The move manipulator.](shot:move-manipulator)

| Part | Does |
|---|---|
| **Three arrows** | Slide along X, Y or Z |
| **Three squares** | Slide in a plane |
| **The dot in the middle** | Slides across the screen |
| **Three rings** | Turn about X, Y or Z. Drag a ring's dot. |

The part you grabbed last is lit, and its value is in the field beside it. Type a distance or an angle there, or switch between **Move** and **Rotate**, and **X**, **Y**, **Z**, in the panel below. Distances and angles snap to round steps while you drag.

### Inspector

![The move inspector.](shot:inspector-move)

It is one **Move** feature with six values and a pivot:

| Field | What it does |
|---|---|
| **X**, **Y**, **Z** | How far to move |
| **Rotate X**, **Rotate Y**, **Rotate Z** | How far to turn |
| **Pivot** | The point the turns are about |

The turns happen about the pivot, X then Y then Z, before the move. A value that comes from a parameter asks before a drag replaces it with a number.

### Pivot

By default the pivot is the middle of what moves. To turn about another point, open the **Pivot** menu and choose **Origin**, or a centre or corner of what moves, such as **Bottom Centre** or **Lowest Corner**. **Pivot X**, **Pivot Y** and **Pivot Z** appear below it. Type any position there, or a parameter. The manipulator moves to the pivot, so you see where the rings turn. Choose **Middle of What Moves** to go back to the default.

You can also right-click a body or a sketch in the browser and choose **Move or Rotate Body** or **Move or Rotate Sketch**.

## Scale

**Scale** makes bodies and sketches bigger or smaller by one factor, in every direction.

1. Click a face of a body, or a body in the browser. Or select a sketch in the browser, or click one of its profiles or curves.
2. Choose **Scale** in the **Modify** menu, click its button, press [[Z]], or right-click and choose **Scale Body** or **Scale Sketch**.
3. Drag the arrow, or type a **Factor**, for example `1.5` or `width / 40`.

A body grows about the middle of its bounding box, so it stays where it is. Pick several bodies and they scale together about the middle of them all, so the gaps between them scale too. A sketch scales about its own origin, including circles and text, and features built from the sketch afterwards use the scaled version. The sketch itself stays as drawn, so its dimensions still work. The factor can be a parameter.

Scaling keeps a body's faces and edges, so a Fillet or Hole placed after it still finds its place. It suits an imported STL or STEP file that came in at the wrong size. If you want a part to change size from its dimensions instead, change the sketch or the dimensions it is built from.

To move, turn or scale shapes *inside* a sketch, see [Move, scale and pattern](doc:sketch/transform).
