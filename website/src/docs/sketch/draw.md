---
title: Drawing tools
description: Line, rectangle, slot, circle, polygon, arc, tangent arc, ellipse, spline, gear, point and project edge, with every way to draw each. How to draw them, type exact values and snap.
---

The **Create** group holds the shapes. The key in brackets picks the tool while you sketch.

![The sketch toolbar.](shot:toolbar-sketch)

| Tool | Key | How to use it |
|---|---|---|
| **Line** | [[L]] | **Line:** click points to draw connected lines. [[Esc]] ends the chain. **Midpoint Line:** click the middle of the line, then one end. The other end mirrors it, so the middle stays in the middle when you resize. Press [[L]] again to switch. |
| **Rectangle** | [[R]] | **Two corners:** click two opposite corners. **Center:** click the centre, then a corner. **3-Point:** click the two ends of one side, at any angle, then how far the rectangle reaches. **Rounded** and **Center Rounded:** see [Rounded Rectangle](doc:sketch/rounded-rectangle). Press [[R]] again to go on to the next way. |
| **Slot** | [[O]] | **Slot:** click the centre of each end. **Overall Slot:** click the two outside ends. **Center Point**, **3-Point Arc** and **Center Arc** slots too. See [Slot](doc:sketch/slot). Press [[O]] again to switch. |
| **Circle** | [[C]] | **Center:** click the centre, then a point on the circle. **2-Point:** click two points on opposite sides. **3-Point:** click three points the circle passes through. **2-Tangent:** click two lines, circles or arcs, then move to choose which circle touches both and click to place it. **3-Tangent:** click three lines, circles or arcs. Press [[C]] again to switch. |
| **Polygon** | [[G]] | **Inscribed:** click the centre, then a corner, so the corners sit on the circle. **Circumscribed:** click the centre, then the middle of a side, so the sides touch the circle. **Edge:** click the two ends of one side, and the polygon grows to the left of the way you went. The polygon has six sides until you change it: type a number (3 to 64) or press [[↑]] and [[↓]] before the first click. The sides are always equal. Press [[G]] again to go through the ways, ending with a **Triangle** (three sides). |
| **Arc** | [[A]] | **Center:** click the centre, the start, then the end (counter-clockwise). **3-Point:** click the start, the end, then a point the arc passes through. Press [[A]] again to switch. |
| **Tangent Arc** | [[N]] | Click the free end of a line or arc, then where the arc ends. The arc leaves that end smoothly. See [Tangent Arc](doc:sketch/tangent-arc). |
| **Ellipse** | [[J]] | Click the centre, the end of one axis, then how far the other axis reaches. See [Ellipse](doc:sketch/ellipse). |
| **Spline** | [[B]] | **Fit Point:** click points for a smooth curve through them, or press and drag to pull a handle. Click the first point to close the shape. [[Esc]] ends it. **Control Point:** click control points: the curve starts at the first, ends at the last and is pulled toward the ones between. [[Return]] or a double-click finishes it, [[Esc]] cancels. Press [[B]] again to switch. |
| **Gear** | [[K]] | Set the teeth, module and the rest, then click where the centre goes. See [Gear](doc:sketch/gear). |
| **Point** | [[P]] | Click to place a point. |
| **Text** | [[X]] | See [Text](doc:sketch/text). |
| **Project Edge** | [[U]] | Click body edges to bring them into the sketch. See [Project Edge](doc:sketch/project-edge). |
| **Intersect** | [[Q]] | Click a body to bring in the curves where the sketch plane cuts it. See [Intersect](doc:sketch/project-edge). |
| **Project Again** | [[W]] | Click a projected curve, then a new edge for it to follow. See [Project Again](doc:sketch/project-edge). |

Some tools share a button. The small arrow beside it picks the way to draw, and the button then keeps using it. In the list under **Create**, rest the pointer on a name such as **Rectangles** and its ways to draw open beside it. The pin beside a name, or beside a single way, puts that button on the toolbar.

:::note
Arc, Gear, Text, Patterns and References are in the Create group's list rather than on the toolbar by default. Click **Create** to see all of them, and pin the ones you want. See [The interface](doc:start/interface).
:::

## The shortcuts panel

Press [[Space]] while you sketch and a small panel floats up with the tools you use most. Click one to pick it. The search field at the bottom finds any sketch tool, and [[Return]] picks the first match.

- **Customize** shows every sketch tool: click a tool to add it to the panel or take it off, and **Reset to Default** puts the first set back.
- Drag the panel wherever you like by its title or the gaps between the tools. It remembers where you left it.
- [[Space]], [[Esc]] or a click outside closes it. In **Settings → Shortcuts** the key can be changed: it is *Sketch Shortcuts Panel*, under *While Sketching*.

## Type exact values

You don't have to place every point with the mouse. After the first click, small fields appear next to the pointer for the values that make sense for the shape:

| Shape | Fields |
|---|---|
| Line, Midpoint Line | Length, Angle |
| Rectangle | Width, Height |
| 3-Point Rectangle | Length and Angle of the first side, then Height |
| Rounded Rectangle | Width, Height and Radius, after the first click. The Radius can also come before it |
| Slot | Width before the first click, and Length and Width after it |
| Arc slots | Width |
| Circle | Diameter. The 2-Tangent circle takes a Radius |
| Polygon, Triangle | Length (of one side) or Diameter (of the circle round the corners). Polygon also has Sides, the number of sides. Circumscribed and Edge polygons take Sides too |
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
