---
title: Pipe
description: Make a round tube along sketch curves, solid or hollow.
---

**Pipe** gives a sketched line a round body. Key: [[P]].

## Use it

1. Sketch the path with lines and arcs, joined end to end.
2. Press [[P]] for **Pipe** and click the curves, or one curve of the path.

A pipe with a `5 mm` diameter appears.

![A pipe along a curved path, with its diameter handle.](shot:pipe-edit)

## Inspector

![The pipe inspector.](shot:inspector-pipe)

| Field | What it does |
|---|---|
| **Diameter** | The outside diameter. It takes expressions. |
| **Hollow** | Makes it a tube. Then set the **Wall** thickness. |
| **Path** | The curves it follows. Click sketch curves in the viewport to choose another path. |
| **Operation** | New Body, Join, Cut or Intersect |

## Tips

- Keep bends gentler than the pipe's own radius, or the pipe can't be built.
- The Flanged Pipe example (**File → Open Example Parts**) has a hollow pipe along a curved path.
