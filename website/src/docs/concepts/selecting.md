---
title: Selecting things
description: How to pick faces, edges, bodies, sketch profiles and curves, and how tools ask for them.
---

## Picking in the viewport

Move the pointer over the model and what is under it lights up. Click to select it.

| Do this | To |
|---|---|
| **Click** a face or an edge | Select it |
| [[⇧]]-click | Add to, or remove from, the selection |
| **Double-click** an edge | Select its whole loop of edges |
| Click empty space, or press [[Esc]] | Clear the selection |

The status bar at the bottom of the viewport always reminds you.

## Selecting from the browser

Click a body, sketch, plane or canvas in the browser to select it. [[⇧]]-click adds more. Tools that work on whole bodies, such as Move, Combine, Mirror and Pattern, accept bodies picked here.

## Tools that wait for you

Most tools work on what you have already selected. If nothing is selected, the tool waits and tells you what it needs in the status bar, for example *Select a profile to revolve*. The cursor changes, and the origin planes appear when the tool needs one.

While a tool waits:

- **Click** to pick. [[⇧]]-click picks several.
- [[Return]] accepts what you have picked, using defaults for anything optional.
- [[Esc]] cancels.
- Press the tool's button again to finish it, or to cancel if nothing is picked.

:::tip
Select first, then choose the tool. A fillet needs edges, so click the edges and press [[F]]. The tool runs straight away.
:::

## Profiles and curves

In a sketch, each closed shape is a **profile**. When a tool such as Extrude needs profiles, the sketch's closed regions show shaded. Click one, or [[⇧]]-click several. Profiles inside other profiles become holes.

Open curves and lines are picked directly as **curves**. Rib, Pipe and Sweep take curves as paths. If you click one curve of a path, SimplMaker follows the curves joined end to end with it.

## Picking again later

Features built from profiles have a **Reselect…** button in the inspector. It shows the sketch again so you can click different profiles, then press [[Return]] to keep them or [[Esc]] to leave things as they were.

## Lock bodies and sketches

Lock a body or a sketch when it is finished and you do not want to nudge it by accident while you work on something nearby.

- Click the **padlock** beside the eye of a body or a sketch in the [browser](doc:start/interface). The padlock on a folder, or on the **Bodies** and **Sketches** rows, locks everything inside. You can also right-click a row and choose **Lock Body**, **Lock Sketch** or **Unlock**.
- A locked body or sketch is still drawn, but it cannot be hovered, picked, selected, edited, suppressed, moved or deleted.
- Locking does not change the shape, so nothing rebuilds. It is saved with the part, and it is one step in **Undo**.
- Click the padlock again to unlock.

![The browser with a locked body and a locked sketch.](shot:browser-lock)

Only bodies and sketches can be locked. Planes and canvases cannot.
