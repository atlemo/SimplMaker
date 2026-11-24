---
title: Sweep
description: Move a profile along a path to make a rail, a handle or a channel.
---

**Sweep** drags a profile along a path. Key: [[W]].

## Use it

1. Sketch the **path**, for example a curved line, in one sketch.
2. Sketch the **profile** in another sketch, on a plane that cuts across the start of the path.
3. Press [[W]] for **Sweep**. Click the profile, then click the path.

If you click one curve of a path, SimplMaker follows the curves joined end to end with it, so you don't have to click each one.

## Inspector

| Field | What it does |
|---|---|
| **Profiles** | The profiles being swept. **Reselect…** picks them again. |
| **Path** | The curves it follows. Click sketch curves in the viewport to choose another path. |
| **Twist** | How far the profile turns about the path from one end to the other, spread evenly along it. 0 is a plain sweep. It takes expressions. |
| **Operation** | New Body, Join, Cut or Intersect |

## Twist

Type a **Twist** and the profile turns about the path as it travels along it, on curved paths as well as straight ones. A rectangle with a twist of 360° is a ribbon with one full turn; a ring of circles off the path becomes strands that spiral like a rope. The twist is the total over the whole path, so a long path needs a bigger angle (1080° or more) before the spiral is easy to see.

Profiles that only touch each other, such as a ring of tangent circles, sweep as separate strands of one body.

## Tips

- Put the profile sketch on a plane that is square to the path where it starts. [Construction planes](doc:create/plane) help here.
- For a plain round tube, [Pipe](doc:create/pipe) is quicker.
