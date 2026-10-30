---
title: Constraints
description: Tell a sketch how its shapes relate: parallel, equal, tangent and more. How to read degrees of freedom, and fix conflicts.
---

A **constraint** is a rule between shapes: this line is horizontal, those two are equal, this circle touches that line. Constraints make a sketch hold its shape when you change a dimension or drag a point.

## Add a constraint

1. Select the items with the Select tool ([[S]]). [[⇧]]-click adds more.
2. Press **Constrain** in the **Constraints** group and choose one. Or use **Constrain Selection** in the inspector.

Only the constraints that fit the selection are enabled.

| Constraint | What it does | Select |
|---|---|---|
| **Coincident** | Puts two points together, or puts a point on a curve | Two points, or a point and a curve |
| **Horizontal** | Makes lines level | One or more lines |
| **Vertical** | Makes lines upright | One or more lines |
| **Parallel** | Makes two lines parallel | Two lines |
| **Perpendicular** | Makes two lines meet at a right angle | Two lines |
| **Tangent** | Makes shapes touch smoothly | A line and a circle or arc, two circles or arcs, or a line and a spline |
| **Equal** | Gives two lines the same length, or two circles or arcs the same size | Two lines, or two circles or arcs |
| **Midpoint** | Puts a point at the middle of a line | A point and a line |
| **Concentric** | Gives two circles or arcs the same centre | Two circles or arcs |
| **Symmetric** | Mirrors two points (or two centres) across a line | The two points, then the line last |
| **Fix** | Locks points where they are | One or more points |

![Constraint symbols next to the geometry.](shot:sketch-constraints)

## Use the axes as guides

The sketch's **X axis** and **Y axis** (the two lines through the origin) can be selected like any line, and used in a constraint. [[⇧]]-click them along with the other items:

- **Symmetric**: two points (or two circle centres) mirrored across an axis.
- **Coincident**: a point that stays on an axis.
- **Parallel** and **Perpendicular**: a line that stays level or upright, as it is against that axis.
- **Tangent**: a circle or arc that touches an axis.

The axes themselves never move, and can't be deleted.

## Symbols

Small symbols next to the geometry show each constraint: **H**, **V**, **∥**, **⊥**, **T**, **=** and so on. Click one to select it and press [[⌫]] to delete it. The inspector also lists them, each with a button to remove it.

Hide the symbols with **View → Show Constraints**, or in **Settings → Viewport**.

## When constraints fight

A constraint or dimension that can't hold together with the others is refused, and the message names what it fights: *Vertical would over-constrain the sketch: it fights Horizontal, Length l1 = 40 mm*. If a parameter change later makes a saved sketch impossible, the error on the [timeline](doc:concepts/timeline) names the ones that no longer fit.

A constraint that only says what the others already say is **redundant**. It does no harm, but the status line counts it, and the inspector marks it with an **=** sign so you can delete it.

## Automatic constraints

You don't have to add the obvious ones by hand:

- Lines that are nearly level or upright snap and get **Horizontal** or **Vertical**.
- Clicking on an existing point connects to it with **Coincident**.
- Clicking on a curve puts the new point on that curve.
- A rectangle comes with horizontal and vertical sides.

## Degrees of freedom

The **degrees of freedom** (DOF) count how many ways the sketch can still move or change. Each dimension or constraint removes some.

- The status bar and the inspector's **Status** show it, for example *2 DOF* or *Fully constrained*.
- A **fully constrained** sketch can't move or change except through its dimensions. A lock appears on its icon in the browser.
- **You don't have to fully constrain a sketch** to extrude it. But a fully constrained sketch behaves the same way every time, which is what you want for a part you will keep editing.

## When it can't solve

If constraints and dimensions disagree, the sketch is **over-constrained**. The inspector says so, and the sketch reports a conflict. To fix it, remove the constraint or dimension you added last, or change a value so they agree.

## Next

[Text](doc:sketch/text)
