---
title: Troubleshooting
description: Fixes for common problems: failed features, sketches that won't solve, faces you can't pick, slow rebuilds, and printing.
---

## A feature has a red triangle

The geometry could not be made. Select the feature. The inspector shows the reason in red, and hovering its icon in the timeline shows it too. The features after it still rebuild where they can.

![An error explained in the inspector.](shot:inspector-shell-error)

| Message or cause | Try |
|---|---|
| **Too large for the neighbouring faces**, or **size too large for the adjacent faces** (fillet, chamfer) | Make the radius or distance smaller. A chamfer as big as the radius of a rounded corner it crosses is refused, and so is a fillet wider than its face. |
| **A wall can't follow a corner tighter than it is thick** (shell) | Use a thinner wall, or move the shell earlier in the timeline, before the fillets |
| **The hole diameter and depth must be positive** | Check the values, and any parameters they use |
| **Lost a face or edge** | An earlier change removed what the feature was attached to. Pick it again, with **Reselect…** where the feature has it, or delete and remake it |
| **Unknown parameter**, **cannot add values with different units** | Fix the expression. See [Parameters](doc:concepts/parameters). |

Suppressing a failing feature, with right-click → **Suppress**, lets you carry on while you decide what to do. See [The timeline](doc:concepts/timeline).

## A sketch won't extrude

- Make sure the shape is **closed**: lines end exactly where the next begins. Click a corner point and drag, or use **Coincident**.
- If the sketch is **over-constrained**, remove the dimension or constraint you added last. See [Constraints](doc:sketch/constraints).
- Shapes that cross themselves don't make a clean profile. Trim the overlap.

## I can't click the face or edge I want

- **Hidden bodies** can't be picked. Show them with the eye in the browser.
- For a fillet, click the **face** instead of each edge. Every edge around it is used.
- **Double-click an edge** to select its whole loop.
- A tool may be waiting for something else. Check the status bar, and press [[Esc]] to cancel.

## The Thread tool says the face isn't round

Click the side of a shaft or the wall of a hole, or a flat face next to one. See [Thread](doc:modify/thread).

## A rebuild is slow

- Very detailed parts, such as ones with threads, take longer to rebuild. The card in the middle of the view says what it is working on.
- **Suppress** the heavy features while you work on something else, then unsuppress them. Or roll the timeline marker back.
- A drag preview that is too slow stops at the last good value.

## My parameter doesn't do anything

- The parameter list shows what **uses** each one. If it says *Not used yet*, type its name into a size field.
- The name must match exactly. Autocomplete helps: start typing and press [[Tab]].

## Parts print the wrong size

- Check the model in millimetres with [Measure](doc:modify/measure).
- Look at your slicer's scale setting.
- Holes print small and pegs print large. Add a [tolerance parameter](doc:print/design-tips).

## Editing is switched off

The trial has ended or the licence needs checking. See [Licence and activation](doc:reference/license). You can still open and export parts.

## Still stuck?

[Write to support](/support/) with your SimplMaker version (**SimplMaker → About**), your macOS version, what you did and what happened. A screenshot or the `.simplmaker` file helps a lot.
