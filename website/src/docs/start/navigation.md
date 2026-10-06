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

If you would rather have scrolling orbit, and [[⇧]]-scrolling pan, change it in **Settings → Navigation**.

## Mouse

| Do this | To |
|---|---|
| Drag on empty space | **Orbit** |
| Right-drag or middle-drag | **Pan** |
| Scroll wheel | **Zoom** |

**Settings → Navigation → Invert mouse-wheel zoom** reverses the wheel.

## The view cube

The cube in the top-right corner of the viewport shows which way you are looking.

![The view cube.](shot:viewcube)

- Click a **face** to look straight at it.
- Click an **edge** or a **corner** to look at it from an angle.
- **Drag** the cube to orbit.
- Click the **house** to go to the home view, the isometric one.

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
