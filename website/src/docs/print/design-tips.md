---
title: Designing for printing
description: Practical ways to use parameters, tolerances, walls, holes and threads so your parts print right the first time.
---

SimplMaker is made for parts you will print. This page collects the ways its features help. The numbers are common starting points: your printer, filament and slicer settings decide the final answer, so **test and adjust**.

## Put your tolerances in parameters

Printed parts rarely come out at exactly the size you modelled. Holes print a little small, and pegs a little big. Instead of fixing each hole by hand, define the correction once:

```
tolerance = 0.2 mm
peg_d     = 8 mm
hole_d    = peg_d + tolerance
```

Now every hole that uses `hole_d` follows. When you change filament or printer and the fit changes, edit `tolerance` once and everything updates. This is the best reason to model with parameters.

## Make sizes follow each other

Name the sizes that matter, and derive the rest:

```
wall      = 2 mm
lid_gap   = 0.3 mm
box_w     = 60 mm
lid_w     = box_w - 2 * wall - lid_gap
```

Change `box_w` and the lid still fits. See [Parameters and expressions](doc:concepts/parameters).

## Walls

Choose wall thickness in multiples of your nozzle's line width. For a 0.4 mm nozzle, walls of 1.2 mm, 1.6 mm or 2 mm work well. Use [Shell](doc:modify/shell) to hollow a body to an even wall.

## Holes and pegs

- **Clearance holes** for screws should be a little bigger than the screw. For example, 3.2 to 3.5 mm for an M3. Use a parameter.
- **Press fits** need a smaller tolerance. Print a test piece.
- **Vertical holes** print rounder than horizontal ones.
- Use a **counterbore** or **countersink** so screw heads sit flush. See [Hole](doc:modify/hole).

## Threads

SimplMaker models real threads, with a **tolerance offset** for printing (PETG, ASA, ABS and Nylon presets). Print a short test bolt and nut before the real part. See [Thread](doc:modify/thread).

## Orientation

Model parts the way they will print: flat bottom on the XY plane, with Z up. Layer lines are weakest across layers, so orient a part so that loads run along them, not across.

## Overhangs

A fillet on the underside of a part prints as an overhang. Use a **chamfer** at 45° on the bottom edges instead. Chamfering the bottom edge of a part also reduces the bulge that can form on the first layer. See [Fillet and chamfer](doc:modify/fillet-chamfer).

## Strengthen thin parts

A thin wall or a tall post is weak. Add [ribs](doc:create/rib) behind it, or [fillet](doc:modify/fillet-chamfer) the inside corners where it meets the base.

## A test print is cheap

Print a small piece that has just the tricky feature: a thread, a snap fit, a hinge. Adjust `tolerance`, rebuild, print again. Because every size is a parameter, each round takes a minute.

## Export

Choose **File → Export…**, pick **STL**, and open the file in your slicer. See [Exporting for printing](doc:print/export).
