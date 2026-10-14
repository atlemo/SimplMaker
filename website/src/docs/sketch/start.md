---
title: Starting a sketch
description: Choose a plane or a face to draw on, finish and edit sketches later, and how sketch mode looks.
---

A **sketch** is a flat drawing. You use it as the starting point for a solid: extrude it, revolve it, sweep it, loft between sketches, or use its curves as a path.

## Start one

1. Press **Sketch** in the toolbar, or choose **Sketch → New Sketch…**. The three origin planes appear.
2. Click a plane to draw on:
   - **XY**, **XZ** or **YZ**, one of the three origin planes
   - a **flat face** of a body
   - a **construction plane** you made earlier

![Choosing a plane to sketch on.](shot:sketch-plane-pick)

The view turns to face the plane, and the toolbar changes to the sketch tools. [[Esc]] cancels.

:::tip
If a flat face is already selected when you press **Sketch**, the sketch goes straight onto it. **Sketch → New Sketch On** also lets you pick XY, XZ, YZ or the selected face directly.
:::

A sketch drawn on a face is attached to that face by name, so it stays on the face even when you change sizes earlier in the timeline.

## Sketch mode

While you sketch:

- The background is tinted like drafting paper, so you always know where you are. Change the colour in **Settings → Viewport**.
- The toolbar shows the [sketch tools](doc:start/interface), and **Finish Sketch** appears at its right end.
- The status bar says how many **degrees of freedom** the sketch has left. See [Constraints](doc:sketch/constraints).
- The inspector shows the sketch's plane, its status, its curves, constraints and dimensions.

Orbiting works as usual: drag on empty space to turn the view. Hold [[⌥]] while you drag to **roll** the picture round on the paper instead.

Faces are lit evenly while you sketch, so no glare sweeps over a flat wall as you turn the view.

### Slice View

Sometimes the plane you sketch on is hidden behind the rest of the part, for example when you sketch between two walls. **Slice View** cuts away everything that stands between the sketch plane and the camera, so you can reach it.

![A sketch between two walls, with Slice View on.](shot:sketch-slice-view)

It switches on by itself when the plane is hidden, and SimplMaker tells you why the first time. Turn it on or off with **Sketch → Slice View**, or with the **Slice View** switch in the sketch's inspector. It only changes what you see. It does not change the part.

## Finish a sketch

Press **Finish Sketch**, or press [[Return]]. The view goes back to where it was.

Sketches that a feature uses (an extrusion, say) are hidden automatically so they don't get in the way. Show one again with the eye beside it in the browser.

## Edit a sketch later

Double-click the sketch in the timeline or the browser, or choose **Edit Sketch** in its inspector. The model is rolled back to that point while you edit, and rebuilds when you finish.

Right-click a sketch in the browser for more: **Hide Sketch**, **Move or Rotate Sketch**, **Scale Sketch**, **Rename Sketch**, **Suppress** and **Delete**.

## Straighten the axes

A sketch on a face takes its x and y directions from the face. If they are tilted, the inspector offers **Straighten**, which turns the sketch so its x axis runs level and y points up, like new sketches. Everything in it turns with it.

## Next

[Drawing tools](doc:sketch/draw), then [dimensions](doc:sketch/dimensions) and [constraints](doc:sketch/constraints).
