---
title: The interface
description: Where everything is: the toolbar, browser, parameters, viewport, inspector and timeline.
---

Each part opens as a tab. The tabs show in the toolbar beside the mode selector as soon as you have a second part open (⌘N, **File → New**, or **New Part** on the Start page); until then the toolbar has no tab bar. The **+** opens another part, and a right-click on a tab offers **Close Other Tabs** and **Move Tab to New Window**. The window has five areas.

![The SimplMaker window: toolbar on top, browser on the left, viewport in the middle, inspector on the right, timeline along the bottom.](shot:interface-overview)

| Area | Where | What it is for |
|---|---|---|
| **Toolbar** | Top | The tools, in groups, each on a floating island |
| **Browser** | Left | Your bodies, sketches, planes and images, and the parameters |
| **Viewport** | Middle | The 3D view, where you pick and drag |
| **Inspector** | Right | The settings of the feature you selected |
| **Timeline** | Bottom | Every step, in the order it was built |

Hide the browser, inspector and timeline when you want more room: **View → Hide Browser** ([[⌃⌘S]]), **Hide Inspector** ([[⌥⌘I]]) and **Hide Timeline** ([[⌥⌘T]]). The buttons at the left and right ends of the title bar do the first two. Choose **Render** in the mode selector for the [Render view](doc:modify/render).

## The toolbar

The top of the window has two parts. The title bar holds a few buttons: the browser button with **Undo** and **Redo**, and at the right end the Hide UI and Inspector buttons. Under it floats the **ribbon**, one panel with the **workspace button** at its left and the tools of that workspace next to it, in groups divided by thin lines, each group with its name underneath.

### Workspaces

The big button at the left of the ribbon shows where you are: its picture, its name and the word **Workspace**. Click it for the list of workspaces, each with a picture, a line on what it is for and what is in it. It is there in every workspace, so you can always move on.

- **Start** is a page as big as the window: new and recent parts, and the ways to begin this part (a sketch, a box, a cylinder, the tutorial). A new, empty part opens on it. It makes way for Design as soon as you start something. **Window → Start** ([[⇧⌘1]]) comes back to it.
- **Design** is where you model. Its tools are below.
- **Render** shows the part on a floor with a light you set. See [Render view](doc:modify/render).
- **Mold** is being built, and shows only when it is switched on.

Switching finishes a sketch you were drawing. Every workspace works on the same part and its history; only the tools and panels change.

Each part opens as a tab. The tabs show in the title bar as soon as you have a second part open (⌘N, **File → New**, or **New Part** on the Start page); until then there is no tab bar. The **+** opens another part, and a right-click on a tab offers **Close Other Tabs** and **Move Tab to New Window**.

### Design mode

You start in design mode. The tools sit in groups, with the group's name underneath.

![The design toolbar.](shot:toolbar-design)

| Group | Tools |
|---|---|
| **Sketch** | Starts a sketch |
| **Create** | [Extrude](doc:create/extrude), [Revolve](doc:create/revolve), [Sweep](doc:create/sweep), [Twist Sweep](doc:create/twist-sweep), [Loft](doc:create/loft), [Rib](doc:create/rib), [Pipe](doc:create/pipe) |
| **Shapes** | [Box, Cylinder, Sphere, Torus, Coil](doc:create/primitives) |
| **Modify** | [Fillet and Chamfer](doc:modify/fillet-chamfer), [Hole](doc:modify/hole), [Thread](doc:modify/thread), [Shell](doc:modify/shell), [Draft](doc:modify/draft), [Project](doc:modify/project), [Move and Scale](doc:modify/move-scale), [Lay on Floor](doc:modify/lay-on-floor), [Combine](doc:modify/combine), [Split Body](doc:modify/split) |
| **Construct** | [Plane](doc:create/plane), [Mirror and Pattern](doc:modify/mirror-pattern), [Canvas](doc:create/canvas) |
| **Inspect** | [Measure](doc:modify/measure), [Section Analysis](doc:modify/section-analysis) |

**Choose what's on the toolbar.** Click a group's name to see all its tools. Pin the ones you use to the toolbar, or unpin the ones you don't. Right-click a button for the same choices.

A tool with a small arrow beside it, such as Extrude or Chamfer, has several ways of working. The arrow picks one, and the button then keeps using it.

Hover over any button for its name, shortcut and a one-line description.

### Sketch mode

Press **Sketch** and pick a plane or a face to enter sketch mode. The toolbar changes to the sketch tools, and the background tints like drafting paper so you always know where you are.

![The sketch toolbar.](shot:toolbar-sketch)

| Group | Tools |
|---|---|
| **Create** | Lines, Point, Rectangles, Circles, Arcs, Other Geometry (Ellipse, Polygons, Slots, Splines, Gear), Text, Patterns, References (Project Edge, Intersect, Project Again, Clean Up Projections, Clean Up Stale Projections, Canvas), Sketch Dimension |
| **Modify** | Round Corner, Chamfer, Trim, Extend, Offset |
| **Transform** | Move, Scale |
| **Constraints** | Constrain, Construction |

**Select** stands apart at the left. Press **Finish Sketch** at the right end to leave. See [Sketching](doc:sketch/start).

## The browser

The browser lists what is in the part.

![The browser: bodies, sketches, planes and parameters.](shot:browser-panel)

- **Bodies**, **Sketches**, **Planes** and **Canvases** are folders. Planes and Canvases appear once you have some.
- The eye beside a row shows or hides it. The eye on a folder shows or hides everything in it.
- Make your own folders inside **Bodies** with the folder button in the browser header, or right-click **Bodies** and choose **New Folder**. A body's right-click menu has **Move to Folder**. Drag bodies onto a folder to fill it.
- Drag a body, sketch, plane or canvas onto another row of the same kind to change the order of the list. Dragging down puts it after that row, dragging up puts it before. The order is only for tidiness: the model does not change. Dropping a body on a body inside a folder moves it into that folder.
- The **padlock** beside the eye locks a body or a sketch, so it cannot be picked or changed by accident. See [Lock bodies and sketches](doc:concepts/selecting).
- Click a body to select it. [[⌘]]-click or [[⇧]]-click selects several bodies, and a right-click then moves, scales, recolours, hides, locks or exports them together. **Double-click** to edit the feature that made it. Double-click a sketch to edit the sketch.
- Right-click a row for more: rename, hide, lock, suppress, move, appearance, export and delete.
- The browser and the parameters are two separate panels. Each can be collapsed, and the divider between them can be dragged.
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
