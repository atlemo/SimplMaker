---
title: Drawing tools
description: Line, rectangle, slot, circle, polygon, arc, tangent arc, ellipse, spline, gear, point and project edge. How to draw them, type exact values and snap.
---

The **Draw** group holds the shapes. The key in brackets picks the tool while you sketch.

![The sketch toolbar.](shot:toolbar-sketch)

| Tool | Key | How to use it |
|---|---|---|
| **Line** | [[L]] | Click points to draw connected lines. [[Esc]] ends the chain. |
| **Rectangle** | [[R]] | **Two corners:** click two opposite corners. **Center:** click the centre, then a corner. **Rounded:** see [Rounded Rectangle](doc:sketch/rounded-rectangle). Press [[R]] again to go on to the next way. |
| **Slot** | [[O]] | **Slot:** click the centre of each end. **Overall Slot:** click the two outside ends. See [Slot](doc:sketch/slot). Press [[O]] again to switch. |
| **Circle** | [[C]] | **Center:** click the centre, then a point on the circle. **2-Point:** click two points on opposite sides. Press [[C]] again to switch. |
| **Polygon** | [[G]] | Click the centre, then a corner. The polygon has six sides until you change it: type a number (3 to 64) or press [[↑]] and [[↓]] before the first click. The sides are always equal. Press [[G]] again for a **Triangle** (three sides). |
| **Arc** | [[A]] | **Center:** click the centre, the start, then the end (counter-clockwise). **3-Point:** click the start, the end, then a point the arc passes through. Press [[A]] again to switch. |
| **Tangent Arc** | [[N]] | Click the free end of a line or arc, then where the arc ends. The arc leaves that end smoothly. See [Tangent Arc](doc:sketch/tangent-arc). |
| **Ellipse** | [[J]] | Click the centre, the end of one axis, then how far the other axis reaches. See [Ellipse](doc:sketch/ellipse). |
| **Spline** | [[B]] | Click points for a smooth curve through them, or press and drag to pull a handle. Click the first point to close the shape. [[Esc]] ends it. |
| **Gear** | [[K]] | Set the teeth, module and the rest, then click where the centre goes. See [Gear](doc:sketch/gear). |
| **Point** | [[P]] | Click to place a point. |
| **Text** | [[X]] | See [Text](doc:sketch/text). |
| **Project Edge** | [[U]] | Click straight body edges to bring them into the sketch. See [Project Edge](doc:sketch/project-edge). |

Some tools share a button. The small arrow beside it picks the way to draw, and the button then keeps using it.

:::note
Arc, Gear and Point are in the Draw group's list rather than on the toolbar by default. Click **Draw** to see all of them, and pin the ones you want. See [The interface](doc:start/interface).
:::

## Type exact values

You don't have to place every point with the mouse. After the first click, small fields appear next to the pointer for the values that make sense for the shape:

| Shape | Fields |
|---|---|
| Line | Length, Angle |
| Rectangle | Width, Height |
| Rounded Rectangle | Width, Height and Radius, after the first click. The Radius can also come before it |
| Slot | Width before the first click, and Length and Width after it |
| Circle | Diameter |
| Polygon, Triangle | Length (of one side) or Diameter (of the circle round the corners). Polygon also has Sides, the number of sides |
| Arc (centre) | Radius after the first click, then Sweep after the second |

![Width and height fields while drawing a rectangle.](shot:draw-typed-values)

- Type a number. Press [[Tab]] to go to the next field.
- Press [[Return]] to place the shape from what you typed.
- Typed values become **dimensions** automatically, so the shape stays that size.

To use a parameter or an expression, finish the shape and then edit its dimension. The typed fields take numbers. See [Dimensions](doc:sketch/dimensions).

## Gears

The **Gear** tool draws spur gears, with its own page: see [Gear](doc:sketch/gear).

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

[Slot](doc:sketch/slot)
