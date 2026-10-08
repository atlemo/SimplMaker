---
title: Drawing tools
description: Line, rectangle, circle, polygon, triangle, arc, spline, gear and point. How to draw them, type exact values and snap.
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
| **Gear** | [[K]] | Set the teeth, module and the rest, then click where the centre goes. See Gears below. |
| **Point** | [[P]] | Click to place a point. |
| **Text** | [[X]] | See [Text](doc:sketch/text). |

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
| Circle | Diameter |
| Polygon, Triangle | Length (of one side) or Diameter (of the circle round the corners). Polygon also has Sides, the number of sides |
| Arc (centre) | Radius after the first click, then Sweep after the second |

![Width and height fields while drawing a rectangle.](shot:draw-typed-values)

- Type a number. Press [[Tab]] to go to the next field.
- Press [[Return]] to place the shape from what you typed.
- Typed values become **dimensions** automatically, so the shape stays that size.

To use a parameter or an expression, finish the shape and then edit its dimension. The typed fields take numbers. See [Dimensions](doc:sketch/dimensions).

## Gears

The **Gear** tool is experimental: it works, but may change. It draws a spur gear: a round wheel with straight teeth, for gears that mesh. Click where the centre goes. A faint outline follows the pointer until you click.

Fields beside the pointer hold the gear's size. Type a number and press [[Tab]] for the next field.

| Field | What it does |
|---|---|
| **Teeth** | How many teeth, 6 to 200. |
| **Module** | The size of the teeth, in mm. The pitch diameter (the circle where two gears touch) is the module times the number of teeth. |
| **Pressure angle** | How steeply the teeth lean. 20° is the usual value. Leave it unless you are matching an existing gear. |
| **Backlash** | How much thinner each tooth is made, in mm. A little (0.1 to 0.2 mm) lets printed gears turn without binding. |
| **Bore** | The diameter of the hole through the middle, in mm. 0 for no hole. |

After you click, the gear is drawn and the same fields change *that* gear: type a new number and it is drawn again at once. [[Return]] keeps the change, and [[Esc]] takes it back. Values can be parameters or expressions, such as `teeth` or `module * 2`, so a gear follows your parameters like any other part of the sketch. See [Parameters and expressions](doc:concepts/parameters).

To change a gear later, choose the Select tool and click it. The Gear tool opens with that gear's fields. [[⌫]] deletes it while it is open.

The gear is a single object. Its teeth are not separate curves, so you can't drag or constrain a tooth. Its centre is an ordinary point: drag it, dimension it, or constrain it, and the gear follows. Click an existing point, such as the sketch origin, to centre the gear on it.

Two gears mesh when they have the same module and pressure angle. Place their centres *(teeth of the first + teeth of the second) × module ÷ 2* apart, for example 32 mm for 12 and 20 teeth at module 2. Turn one gear so a tooth of the first points into a gap of the second.

:::note
The teeth are smooth curves that follow the true tooth shape to within 0.002 mm. The tooth roots are not rounded.
:::

Extrude a gear like any other shape, and the solid follows when you change its values. With a bore, the toothed ring and the hole are separate regions, so extrude the ring.

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
