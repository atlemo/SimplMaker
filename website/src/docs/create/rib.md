---
title: Rib
description: Add a thin supporting wall from a sketched line to an existing body.
---

**Rib** grows a thin wall from an open line to a body, like the braces on a bracket. Key: [[B]].

## Use it

1. You need an existing **body**.
2. Sketch an **open line** that runs along the rib's edge, on a plane through where the rib should be, with its ends reaching the body.
3. Press [[B]] for **Rib** and click the line.

The rib grows from the curve to the body, and is as thick across the sketch plane.

![A bracket braced by two ribs.](shot:rib-example)

## Inspector

| Field | What it does |
|---|---|
| **Thickness** | How thick the rib is. It starts at `2 mm` and takes expressions. |
| **Path** | The curve it grows from |

## Tips

- Use a parameter such as `rib_t` for the thickness, and keep it the same as your wall thickness for strong prints.
- Open **File → Open Example Parts → Bracket with Ribs** to see ribs at work.
