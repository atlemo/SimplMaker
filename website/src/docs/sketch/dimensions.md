---
title: Dimensions
description: Set exact sizes and distances in a sketch, using numbers, expressions or parameters.
---

A **dimension** fixes a size or a distance. It takes a value or an [expression](doc:concepts/parameters), so it can follow a parameter.

## Add a dimension

### Dimension tool

Press [[I]] for the **Dimension** tool, then click:

| Click | You get |
|---|---|
| A **line**, then empty space to place the label | Its length |
| A **circle** | Its diameter |
| An **arc** | Its radius |
| **Two points**, a **point and a line**, or **two lines** | A distance, or an angle between lines |

A small box appears. Type a value or an expression such as `width / 2`, and press [[Return]].

![The dimension box.](shot:sketch-dimension-popover)

### Grey sizes

SimplMaker shows the current size of shapes in grey. **Click any grey size** to turn it into a dimension, then type the value you want. This is the quickest way to dimension a rectangle.

### Distance tool

Press [[D]] for the **Distance** tool, then click two items and type the distance between them. For example, put a hole 4 mm from the edge of a rectangle.

- A point, a line or a circle's centre point is measured as usual.
- A circle or arc is measured from its **edge**. To measure from the middle, click its centre point instead.
- Two points can be measured straight, or only horizontally or vertically, with the buttons in the box.
- Two lines must be parallel.
- The circle moves to keep the distance, and keeps its size. The edge it is measured from stays where it is.

## Change a dimension

- Click its label with the Select tool, type a new value, and press [[Return]].
- Or edit it in the inspector, under **Dimensions**, while the sketch is selected.
- With the Select tool, drag a dimension's line to move it out of the way.

A dimension that uses a parameter shows its name, for example *width = 60 mm*.

## Dimensions and drawing

Values you type while drawing a shape become dimensions as soon as you place it. See [Drawing tools](doc:sketch/draw).

## Next

[Constraints](doc:sketch/constraints)
