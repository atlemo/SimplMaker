---
title: Navigating the view
description: Orbit, pan and zoom with a trackpad or mouse, the view cube, standard views, orthographic view and visual styles.
---

## Trackpad

| Do this | To |
|---|---|
| Two-finger scroll | **Pan** the view |
| [[⇧]] and two-finger scroll | **Orbit** |
| Pinch | **Zoom** |
| Rotate with two fingers | **Spin** the view around the line of sight |
| Drag on empty space | **Orbit** |

These are the defaults. Choose another way of navigating, or change what each input does, in **Settings → Navigation**. See [Make navigation your own](doc:start/navigation#make-navigation-your-own) below.

## Mouse

| Do this | To |
|---|---|
| Drag on empty space | **Orbit** |
| Right-drag or middle-drag | **Pan** |
| Scroll wheel | **Zoom** |

While you sketch, hold [[⌥]] and drag on empty space to **roll** the view round on the paper.

## Make navigation your own

**Settings → Navigation** sets what the mouse, the wheel and the trackpad do.

- **Navigate like** picks a ready-made set of controls that copies another 3D app: **SimplMaker**, **Blender**, **Fusion**, **Onshape** or **SolidWorks**. Your direction and speed choices stay as they are. Once you change any single control by hand, the list shows **Custom**.
- **Mouse** and **Trackpad** list what each input does: the left, right and middle buttons, the wheel, and the trackpad's scroll. For each one you choose **Orbit**, **Pan**, **Zoom** or **Off**, separately for plain, [[⇧]], [[⌃]] and [[⌥]]. (**Roll**, for sketches, is also on the list.) The left button only navigates on empty space. On a face, an edge or a handle it picks or drags that instead.
- **Rotate gesture spins the view** turns the trackpad's two-finger rotate on or off.
- **Invert** switches reverse orbit up and down, orbit left and right, pan up and down, pan left and right, and zoom.
- **Orbit speed** and **Zoom speed** are sliders.
- **Reset Navigation** goes back to the SimplMaker controls.

## The view cube

The cube in the top-right corner of the viewport shows which way you are looking.

![The view cube.](shot:viewcube)

- Click a **face** to look straight at it.
- Click an **edge** or a **corner** to look at it from an angle.
- **Drag** the cube to orbit.
- Click the **house** to go to the home view, the isometric one.
- While you sketch, two curved **arrows** beside the cube turn the sketch a quarter turn counter-clockwise or clockwise on the screen.

## Standard views

**View → Standard Views** jumps to a fixed view. Fit All zooms to show the whole model.

| View | Shortcut |
|---|---|
| Top | [[⌘1]] |
| Front | [[⌘2]] |
| Right | [[⌘3]] |
| Home (isometric) | [[⌘4]] |
| Fit All | [[⌘0]] |

## Perspective or orthographic

Perspective makes distant things smaller, as your eye sees them. Orthographic keeps parallel lines parallel, which is easier for judging sizes. Turn it on with **View → Orthographic Projection** ([[⌥⌘O]]).

## Visual style

**View → Visual Style** changes how bodies are drawn.

| Style | Looks like |
|---|---|
| **Shaded** | Solid surfaces, no edge lines |
| **Shaded with Hidden Edges** | Solid surfaces, with the edges behind them drawn dashed |
| **Shaded with Visible Edges Only** | Solid surfaces with edge lines. This is the default. |
| **Wireframe** | Edges only (you can still click faces) |
| **Wireframe with Hidden Edges** | Edges only, with the hidden ones dashed |
| **Wireframe with Visible Edges Only** | Edges only, hiding the ones behind |

## Grid, axes and light or dark

- **View → Show Grid** ([[⌥⌘G]]) and **Show Axes** ([[⌥⌘A]]) toggle the reference lines.
- The viewport follows the system's light or dark mode, and draws thicker lines when macOS's **Increase Contrast** is on.
- The size of the grid squares, and the units they use, are in **Settings → Viewport**.
