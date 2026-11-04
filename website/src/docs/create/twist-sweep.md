---
title: Twist Sweep
description: Push a profile along a straight line while it turns, for twisted bars, propeller and fan blades, and spirals.
---

**Twist Sweep** pushes a sketch profile straight out from its sketch while it turns about the line it moves along. Key: [[⇧W]].

## Use it

1. Sketch a closed shape on a plane. The sweep starts on that plane and runs along its normal, the way an extrude does.
2. Press [[⇧W]] for **Twist Sweep**. If one profile is already selected it is made straight away; otherwise click the profile, then press [[Return]].
3. In the inspector, set the **Length** and the **End angle**. The shape twists from the **Start angle** (0 by default, the profile as you drew it) to the end angle.

![The Twist Sweep arrow with its length field, the dot that sets the turn, and the operation buttons.](shot:twist-sweep-handle)

Drag the orange arrow, or type in the field beside it, to set the length. The dot on the ring at the far end sets the **End angle** the same way. The New, Join, Cut and Intersect buttons under the part set the operation; **OK** finishes.

## Inspector

| Field | What it does |
|---|---|
| **Length** | How far it runs along the sketch's normal. **Flip direction** runs the other way. |
| **Start angle**, **End angle** | How far the profile has turned at the start and at the end. A positive angle turns counter-clockwise, seen from the front of the sketch. |
| **Curve** | How the turn is spread along the length. 1 turns evenly. Above 1 the shape stays nearly flat at the start and turns most toward the end; below 1 it turns early. At a fraction *t* of the way the turn is start + (end − start) × *t* to the power of the curve. |
| **Slide across (x)**, **Slide up (y)** | How far the profile has slid by the end, in the sketch's own x and y. This makes a lean, or the rise of a blade along its length. |
| **Turn about the profile's middle** | On: the profile turns about its own middle. Off: type the point of the sketch it turns about. |
| **Operation** | New Body, Join, Cut or Intersect |

All of them take expressions and parameters, like any other size.

## A fan or propeller blade

A blade is a flat plate that twists, cut to an outline. Make it from two features:

1. Draw a thin rectangle, wider than the blade, on the plane the blade starts from, and **Twist Sweep** it: set the length of the blade, the tilt at the far end, and the **Curve** (try 2 if the tilt grows faster toward the root). Use **Slide up** for a rise along the blade.
2. Draw the blade's outline on another plane and [Extrude](doc:create/extrude) it through the plate with the operation **Intersect**.

The blade has the outline's straight vertical edges, like a moulded one, and the plate's twist.

## Tips

- The shape is a smooth loft through a section about every 3° of turn, so a long twist can take a moment to rebuild.
- A profile that is long compared with the length and turns a lot can cross itself and fail. The inspector says so; use a shorter twist or a longer length.
- To copy a twisted shape from an imported STL, ask the [assistant](doc:ai/assistant) to slice it: it reads the tilt and rise at every station and fits the angles for you.
