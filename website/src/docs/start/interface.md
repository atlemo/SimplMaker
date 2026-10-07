---
title: The interface
description: Where everything is: the toolbar, browser, parameters, viewport, inspector and timeline.
---

Each part opens in its own window with five areas.

![The SimplMaker window: toolbar on top, browser on the left, viewport in the middle, inspector on the right, timeline along the bottom.](shot:interface-overview)

| Area | Where | What it is for |
|---|---|---|
| **Toolbar** | Top | The tools, in groups |
| **Browser** | Left | Your bodies, sketches, planes and images, and the parameters |
| **Viewport** | Middle | The 3D view, where you pick and drag |
| **Inspector** | Right | The settings of the feature you selected |
| **Timeline** | Bottom | Every step, in the order it was built |

Hide the browser, inspector and timeline when you want more room: **View → Hide Browser** ([[⌃⌘S]]), **Hide Inspector** ([[⌥⌘I]]) and **Hide Timeline** ([[⌥⌘T]]). The buttons at the left and right ends of the title bar do the first two.

## The toolbar

The toolbar changes with the mode you are in.

### Design mode

You start in design mode. The tools sit in groups, with the group's name underneath.

![The design toolbar.](shot:toolbar-design)

| Group | Tools |
|---|---|
| **Sketch** | Starts a sketch |
| **Create** | [Extrude](doc:create/extrude), [Revolve](doc:create/revolve), [Sweep](doc:create/sweep), [Loft](doc:create/loft), [Rib](doc:create/rib), [Pipe](doc:create/pipe) |
| **Shapes** | [Box, Cylinder, Sphere, Torus, Coil](doc:create/primitives) |
| **Modify** | [Fillet and Chamfer](doc:modify/fillet-chamfer), [Hole](doc:modify/hole), [Thread](doc:modify/thread), [Shell](doc:modify/shell), [Project](doc:modify/project), [Move](doc:modify/move-scale), [Combine](doc:modify/combine) |
| **Construct** | [Plane](doc:create/plane), [Mirror and Pattern](doc:modify/mirror-pattern), [Canvas](doc:create/canvas) |
| **Inspect** | [Measure](doc:modify/measure) |

**Choose what's on the toolbar.** Click a group's name to see all its tools. Pin the ones you use to the toolbar, or unpin the ones you don't. Right-click a button for the same choices.

A tool with a small arrow beside it, such as Extrude or Chamfer, has several ways of working. The arrow picks one, and the button then keeps using it.

Hover over any button for its name, shortcut and a one-line description.

### Sketch mode

Press **Sketch** and pick a plane or a face to enter sketch mode. The toolbar changes to the sketch tools, and the background tints like drafting paper so you always know where you are.

![The sketch toolbar.](shot:toolbar-sketch)

| Group | Tools |
|---|---|
| **Draw** | Line, Rectangle, Circle, Polygon, Arc, Spline, Point, Text |
| **Modify** | Round Corner, Trim, Extend, Offset |
| **Transform** | Move, Scale, Pattern |
| **Constraints** | Dimension, Distance, Constrain, Construction |

**Select** stands apart at the left. Press **Finish Sketch** at the right end to leave. See [Sketching](doc:sketch/start).

## The browser

The browser lists what is in the part.

![The browser: bodies, sketches, planes and parameters.](shot:browser-panel)

- **Bodies**, **Sketches**, **Planes** and **Canvases** are folders. Planes and Canvases appear once you have some.
- The eye beside a row shows or hides it. The eye on a folder shows or hides everything in it.
- Click a body to select it. **Double-click** to edit the feature that made it. Double-click a sketch to edit the sketch.
- Right-click a row for more: rename, hide, suppress, move, appearance, export and delete.
- Below the folders are the **Parameters**. See [Parameters and expressions](doc:concepts/parameters).

## The viewport

The viewport shows the model. Click faces and edges to pick them. Drag the arrows and handles that appear on tools to change sizes.

- The **view cube** in the corner turns with the camera. Click a face, edge or corner to look from there. Click the house for the home view. See [Navigating the view](doc:start/navigation).
- The **status bar** at the bottom of the viewport says what a tool is waiting for ("Select a profile or a flat face to extrude"), and shows how long the last rebuild took.
- A small card in the middle appears while a slow part is rebuilding.

## The inspector

Select a feature and the inspector shows its settings. Every size is an expression, so you can type `width / 2` as easily as `25`. Changes apply as you type. At the bottom there is **Delete Feature**. See [The timeline](doc:concepts/timeline).

With a body selected, the inspector shows its name, its volume and the feature that made it.

## The timeline

The timeline is the row of icons along the bottom. Each icon is one feature, in the order they were made. It is also your history: you can roll back to an earlier point, edit something there, and roll forward again. See [The timeline](doc:concepts/timeline).
