---
title: Loft
description: Blend smoothly between two or more profiles on different planes.
---

**Loft** joins profiles with a smooth surface. Key: [[L]].

## Use it

1. Make a sketch with a closed shape on one plane, and another on a second plane. Use [construction planes](doc:create/plane) for planes in the air. You can use more than two.
2. Press [[L]] for **Loft**.
3. Click the profiles **in order**. The status bar counts them. Press [[Return]] to loft the ones you have picked.

One profile from each sketch is used.

## Along a path

A loft takes the shortest way from one profile to the next. To make it bend, give it a **path** to follow: a curve drawn from the first profile to the last, like the centre line of a bent duct or the neck of a horn.

1. Draw the profiles as above.
2. Make a sketch on a plane that crosses the profiles (the front plane, when the profiles lie flat), and draw a line, arc or spline from the first profile to the last. Several curves are fine as long as they join end to end. The profile sketches show while you draw, each as a line, and the cursor snaps to them.
3. Press [[L]], click the profiles in order, click the path, and press [[Return]].

You can also add a path later: select the loft, click the curve, and choose **Follow the selected curve** in the Inspector.

How the shape follows the path depends on how the two meet:

- **The path meets every profile at a right angle.** The shape stays square to the path and turns with it, so a bent duct keeps its width through the bend. The profiles can be on planes at any angle to each other, such as the two ends of an elbow.
- **The path meets a profile at a slant.** The profiles have to be parallel. The shape stays parallel to them and moves sideways with the path, like a stack of cards pushed out of line.

The path only has to reach the planes of the first and last profile. If it is longer, the extra is ignored.

## Inspector

| Field | What it does |
|---|---|
| **Straight sides** | Joins the profiles with straight lines instead of a smooth blend. Not available along a path. |
| **Path** | The curve the loft follows, if any. Click a curve to set it; the minus button removes it. |
| **Profiles, in order** | The list of profiles. Click a profile in another sketch to add it, or **Add the selected profiles**. |
| **Operation** | New Body, Join, Cut or Intersect |

## Tips

- Profiles with the same number of sides loft most cleanly.
- Click them in the order along the loft, bottom to top.
- For a path, a right-angle constraint between the path and the edge of the sketch where it starts keeps the shape square to it.
- If a loft along a path fails, the path probably bends more tightly than the profiles are wide. Try a gentler curve.
