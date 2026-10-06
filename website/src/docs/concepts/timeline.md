---
title: The timeline
description: Every step is a feature. Roll back, edit an early step, reorder, suppress, delete, and fix errors.
---

SimplMaker stores a part as a list of **features**: sketches, extrusions, fillets, holes and so on, in the order you made them. The geometry is *rebuilt* from that list whenever something changes. The list is the timeline.

![The timeline along the bottom of the window.](shot:timeline-bar)

## Reading the timeline

- Each icon is a feature. It uses the same icon as the tool that made it.
- Hover an icon to see its name. Click it to select it, and its settings appear in the inspector.
- A **red triangle** on an icon means the feature failed. Hover over it to see why. The features after it still rebuild where they can.
- A faded icon is **suppressed** (switched off). A very faded icon is *after the marker*, so it is rolled back.
- The orange **marker** shows how far the model is built.

## Edit an earlier step

1. **Double-click** a feature in the timeline, or double-click its row in the browser. A sketch opens in sketch mode. Other features show their handles.
2. Change what you want. The later features rebuild on top of your change.

Everything refers to faces and edges by stable names, so a fillet stays on the right edge even when you change sizes upstream.

## Roll back

Drag the marker to the left, or use the four buttons at its left end:

| Button | Does |
|---|---|
| Start | rolls back to before the first feature |
| Back one | steps back one feature |
| Forward one | steps forward one feature |
| End | rolls forward to the latest feature |

While rolled back, the model shows how it looked at that point. Right-click a feature and choose **Roll Back to Here** for the same thing.

:::note
New features are added at the marker. If you roll back and add a feature, it goes in at that point, not at the end.
:::

## Reorder

Drag an icon sideways to build it earlier or later. Or right-click and choose **Move Earlier** or **Move Later**. A feature can't move before something it needs, for example an extrusion before its own sketch. The menu items are greyed out in that case.

## Suppress

Right-click a feature and choose **Suppress** to switch it off without deleting it. Everything built on it is rebuilt without it. Choose **Unsuppress** to bring it back. This is a good way to test what a fillet or a hole does.

## Delete

Right-click a feature and choose **Delete**, or use **Delete Feature** at the bottom of its inspector. Features that depended on it may show an error until you fix or delete them too.

## Undo and redo

**Edit → Undo** ([[⌘Z]]) and **Redo** ([[⇧⌘Z]]) work on everything: new features, edits, renames, colours, even moving the marker. Each drag or typed change is one step.

## Rebuild

SimplMaker rebuilds automatically. If you want to force it, choose **Create → Rebuild** ([[⌘R]]). The status bar shows how long the last rebuild took.

## When a feature fails

An error means the geometry could not be made. Common causes:

- A fillet or chamfer is **too large** for the neighbouring faces. Make it smaller.
- A sketch profile is **not closed**, or the sketch is over-constrained. See [Constraints](doc:sketch/constraints).
- A feature lost the face or edge it was attached to, because an earlier change removed it. Pick it again with **Reselect…** in the inspector.

The message appears in the inspector in red, and in the tooltip of the red triangle. More in [Troubleshooting](doc:reference/troubleshooting).
