---
title: Construction plane
description: A reference plane, offset or tilted from another plane or face, to sketch on or mirror across.
---

A **construction plane** is a plane you place anywhere. Sketch on it, mirror across it, or use it for the profile of a sweep or loft. Key: [[N]]. It is in the **Construct** group.

## Make one

1. Press [[N]] for **Plane**.
2. Click an **origin plane**, another construction plane, or a **flat face** to start from.

The new plane starts on top of the one you clicked.

## Plane Along Path

A plane square to a sketch curve, for the profile of a [sweep](doc:create/sweep) or the sections of a [loft](doc:create/loft). Key: [[⇧N]], in the **Construct** group.

1. Press [[⇧N]] and click a sketch curve. The curves joined end to end with it become the path.
2. A plane appears square to the path, with a dot on it. **Drag the dot** along the path, or type a **Position** from 0 (the start) to 1 (the end). A parameter works too.
3. Press **OK**. Nothing is added to the timeline before that, and **Cancel** or [[Esc]] leaves the part alone.

**Offset** moves the plane along the path's direction from that spot, and **Angle** tips it. After OK, the plane's Inspector shows the same **Position**, so you can change it later.

## Plane at Angle

A plane turned by an angle from a plane or a flat face, about an axis or an edge. Use it for sloped sketches, such as an angled bracket. Key: [[⇧R]], in the **Construct** group.

1. Press [[⇧R]]. Click the **base**: an origin plane, a construction plane or a flat face.
2. Click the **axis**: an edge, or a round face, or choose **X**, **Y** or **Z** in the panel.
3. Type the **Angle**. A negative angle turns the other way. The plane is previewed as you go. Press **OK**.

**Use axis direction only** projects the axis onto the base and turns the plane about a point on the base: its origin, or a point you pick with **Pivot**. Use it when the edge should only say which way to tilt, not where.

## Inspector

![The plane inspector.](shot:inspector-plane)

| Field | What it does |
|---|---|
| **From** | The plane or face it comes from |
| **Offset** | How far it moves away from that plane. It takes expressions. |
| **Angle** | How far it is tilted |
| **Turned about** | The axis it tilts around: Horizontal or Vertical. On a Plane at Angle it names the axis or edge, with **Use axis direction only** and the pivot. |
| **Position** | On a Plane Along Path: how far along the path, 0 to 1 |
| **New Sketch on This Plane** | Starts a sketch on it |
| **Reset Size** | Resets the size it is drawn at |

A plane is endless to everything that sketches on it or mirrors across it. The size you see is only how it is drawn.

## In the browser

Planes appear in the **Planes** folder of the browser. Hide or show one with its eye, and rename it from the right-click menu. Use clear names, such as *Lid Plane*.

## Tips

- Offset a plane by a parameter (`height + 2 mm`) so it follows your part.
- A tilted plane lets you sketch on a slope without a flat face there.
- Leave a sketch you drew on a construction plane and the plane hides itself. Its eye in the browser brings it back.
