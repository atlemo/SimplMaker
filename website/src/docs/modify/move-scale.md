---
title: Move, rotate and scale
description: Slide and turn bodies and sketches with one manipulator, or type exact values. Scale sketches by a factor.
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

It is one **Move** feature with six values:

| Field | What it does |
|---|---|
| **X**, **Y**, **Z** | How far to move |
| **Rotate X**, **Rotate Y**, **Rotate Z** | How far to turn |

The turns happen about the middle of what moves, X then Y then Z, before the move. A value that comes from a parameter asks before a drag replaces it with a number.

You can also right-click a body or a sketch in the browser and choose **Move or Rotate Body** or **Move or Rotate Sketch**.

## Scale

**Scale** makes sketches bigger or smaller, about their origins.

1. Select a sketch in the browser, or click one of its profiles or curves.
2. Choose **Scale** in the **Modify** menu, press [[Z]], or right-click the sketch and choose **Scale Sketch**.
3. Drag the arrow, or type a **Factor**, for example `1.5` or `width / 40`.

It scales evenly, including circles and text, and features built from the sketch afterwards use the scaled version. The sketch itself stays as drawn, so its dimensions still work. The factor can be a parameter.

:::note
Scale works on sketches. To resize a solid, change the sketch or the dimensions it is built from.
:::

To move, turn or scale shapes *inside* a sketch, see [Move, scale and pattern](doc:sketch/transform).
