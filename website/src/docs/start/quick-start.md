---
title: Your first part
description: Model a small plate with a hole from scratch, change a size, and export it for printing. About ten minutes.
---

This walkthrough builds a plate with a hole and rounded edges. You will meet the main ideas: parameters, a sketch, an extrusion, and an export.

:::tip
Prefer to be guided inside the app? Choose **Help → Tutorial: Make a Desk Organizer**. See [Examples and the tutorial](doc:start/examples-and-tutorial).
:::

## 1. Start a part

Open SimplMaker and choose **Create a new part** in the welcome window, or press [[⌘N]].

![A new, empty part.](shot:quick-empty)

## 2. Add parameters

Parameters are named sizes. Everything you build can refer to them, so changing one changes the whole part.

1. In the **Parameters** section of the browser on the left, press **+**. A parameter called `p1` with the value `10 mm` appears.
2. **Double-click** its name and rename it to `width`.
3. Click its value field and type `60 mm`. Press [[Return]].
4. Press **+** three more times. Make them `depth` = `40 mm`, `thickness` = `5 mm` and `hole_d` = `8 mm`.

![Four parameters in the browser.](shot:quick-parameters)

## 3. Sketch the outline

1. Press **Sketch** in the toolbar. The three origin planes appear.

![Choosing a plane to sketch on.](shot:quick-plane)

2. Click the **XY** plane. The view turns to face it and the background tints like drafting paper.
3. Press [[R]] twice to choose the **Center Rectangle** tool. The first press picks the plain rectangle, and the second switches to the centre version.
4. Click the origin to place the centre, then click out to a corner.
5. Press [[Esc]], then [[S]] for the **Select** tool. Click the grey size label at the top of the rectangle. A small box asks for a value. Type `width` and press [[Return]]. The rectangle is now exactly as wide as the parameter.
6. Click the grey size at the side, type `depth` and press [[Return]].

The status bar now says **Fully constrained**: every point is pinned, so nothing can wander.

![A rectangle driven by width and depth.](shot:quick-sketch)

7. Press [[Return]] to finish the sketch.

## 4. Extrude it

1. Press [[E]] for **Extrude**, then click inside the rectangle.
2. An arrow and a size field appear. Type `thickness` and press [[Return]].

You now have a solid plate.

![The extrude arrow and its size field.](shot:extrude-handle)

## 5. Round the top edges

1. Press [[F]] for **Fillet**, click the top face of the plate, then press [[Return]]. Clicking a face rounds every edge around it.
2. The radius starts at `2 mm`. Press [[Return]] to keep it.

## 6. Add a hole

1. Press [[H]] for **Hole** and click the top face. The hole is placed where you clicked.
2. In the inspector on the right, set **Diameter** to `hole_d`, and **X** and **Y** to `0`.
3. Change **Extent** to **Through all**.
4. Press **OK**.

![The finished plate.](shot:quick-done)

## 7. Change a size

Edit `width` in the browser to `90 mm` and press [[Return]]. The sketch, the plate, the fillet and the hole all follow. That is what parametric means.

![The same part with width set to 90 mm.](shot:quick-changed)

## 8. Export for printing

Choose **File → Export STL…**, pick a place, and open the file in your slicer. The numbers in the file are millimetres. See [Exporting for printing](doc:print/export).

## Where next

- [The interface](doc:start/interface), to learn where everything is
- [Sketching](doc:sketch/start), to draw more shapes
- [For 3D printing](doc:print/design-tips), for tolerances and threads
