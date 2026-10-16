---
title: Slot
description: Draw a bar with round ends, centre to centre or by its overall length, with a width you set.
---

A **slot** is a bar with round ends. Use one for a screw slot, a channel for a cable, or a hole that a bolt can slide along. Press [[O]] for the **Slot** tool. The Slot button holds two ways of drawing one, and [[O]] again switches between them.

| Way | Click | The length is |
|---|---|---|
| **Slot** (Center) | The centre of one end, then the centre of the other | Centre to centre |
| **Overall Slot** | The two outside ends of the slot | End to end |

## Draw one

1. Press [[O]]. Press it again if you want **Overall Slot**.
2. Click the two points that set the slot, as in the table above.
3. The slot is drawn with its width. Press [[Esc]] to leave the tool.

Before the first click, or after it, type a **Width** in the field beside the pointer. The first click fixes the centre, or the first outside end, and the second click sets the other end. For a slot in the **Slot** mode, the length field appears after the first click, so you can type a length there instead of clicking the second point.

:::note
The width is remembered from one slot to the next, so a row of slots comes out the same width. The first one starts at 10 mm.
:::

## Length and width

- **Width** is always a dimension, so the ends stay round when you change it.
- **Length** is a dimension only when you type it. Otherwise the slot's length follows the two points you clicked.
- In **Overall Slot**, a typed length is the **overall** length, from end to end. SimplMaker keeps the distance between the centres as the overall length less the width, so changing the width keeps the ends where the overall length puts them.

To change a size later, edit its dimension, as described in [Dimensions](doc:sketch/dimensions).

## Shape

A slot is two round ends of the same size, joined by two straight sides that are parallel and touch both ends. Because the ends are equal, they stay round when you resize the slot. Extrude it like any other closed shape.

:::note
In **Overall Slot**, the overall length must be longer than the width. If you click two points closer together than that, nothing is drawn and SimplMaker says so.
:::

## Next

[Rounded Rectangle](doc:sketch/rounded-rectangle)
