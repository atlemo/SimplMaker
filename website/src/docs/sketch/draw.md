---
title: Drawing tools
description: Line, rectangle, circle, polygon, triangle, arc, spline and point. How to draw them, type exact values and snap.
---

The **Draw** group holds the shapes. The key in brackets picks the tool while you sketch.

![The sketch toolbar.](shot:toolbar-sketch)

| Tool | Key | How to use it |
|---|---|---|
| **Line** | [[L]] | Click points to draw connected lines. [[Esc]] ends the chain. |
| **Rectangle** | [[R]] | **Two corners:** click two opposite corners. **Center:** click the centre, then a corner. Press [[R]] again to switch between the two. |
| **Circle** | [[C]] | **Center:** click the centre, then a point on the circle. **2-Point:** click two points on opposite sides. Press [[C]] again to switch. |
| **Polygon** | [[G]] | Click the centre, then a corner. The polygon has six sides until you change it: type a number (3 to 64) or press [[↑]] and [[↓]] before the first click. The sides are always equal. Press [[G]] again for a **Triangle** (three sides). |
| **Arc** | [[A]] | **Center:** click the centre, the start, then the end (counter-clockwise). **3-Point:** click the start, the end, then a point the arc passes through. Press [[A]] again to switch. |
| **Spline** | [[B]] | Click points for a smooth curve through them, or press and drag to pull a handle. Click the first point to close the shape. [[Esc]] ends it. |
| **Point** | [[P]] | Click to place a point. |
| **Text** | [[X]] | See [Text](doc:sketch/text). |

Some tools share a button. The small arrow beside it picks the way to draw, and the button then keeps using it.

:::note
Arc and Point are in the Draw group's list rather than on the toolbar by default. Click **Draw** to see all of them, and pin the ones you want. See [The interface](doc:start/interface).
:::

## Type exact values

You don't have to place every point with the mouse. After the first click, small fields appear next to the pointer for the values that make sense for the shape:

| Shape | Fields |
|---|---|
| Line | Length, Angle |
| Rectangle | Width, Height |
| Circle | Diameter |
| Polygon, Triangle | Length (of one side) or Diameter (of the circle round the corners). Polygon also has Sides, the number of sides |
| Arc (centre) | Radius after the first click, then Sweep after the second |

![Width and height fields while drawing a rectangle.](shot:draw-typed-values)

- Type a number. Press [[Tab]] to go to the next field.
- Press [[Return]] to place the shape from what you typed.
- Typed values become **dimensions** automatically, so the shape stays that size.

To use a parameter or an expression, finish the shape and then edit its dimension. The typed fields take numbers. See [Dimensions](doc:sketch/dimensions).

## Snapping

Points snap to useful places as you move.

- **Existing points.** Clicking one connects to it.
- **Curves.** Clicking on a curve puts the new point on that curve.
- **Shape centres.** Circles, arcs and rectangles snap to their centres.
- **The grid.** The status bar says what you are snapping to, for example *Snap: Grid 2 mm*. Turn grid snapping off with **View → Snap to Grid** ([[⌘']]), and choose the grid size in **Settings → Viewport**.
- **Horizontal and vertical.** Lines that are nearly level or upright snap and get a constraint.

Hold [[⌥]] to switch all snapping off while you click.

## Construction geometry

Select curves and press **Construction** in the **Constraints** group to turn them into construction lines. They are drawn dashed, and they never make solid profiles. Use them as guides, and as axes for [Revolve](doc:create/revolve).

## Next

[Editing curves](doc:sketch/edit)
