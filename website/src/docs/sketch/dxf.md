---
title: DXF import and export
description: Bring a DXF drawing into a sketch, or send a sketch out as DXF for a laser cutter, a CNC router or another CAD program.
---

DXF is the drawing format that laser cutters, CNC routers and most CAD programs read.

## Import

1. Select a flat face or a plane, or nothing to use the XY plane. Or open the sketch you want to add the drawing to.
2. Choose **File → Import → DXF as Sketch…** and pick a file.

The drawing's middle goes on the sketch origin, and closed shapes become **profiles** you can extrude or cut. The result is plain, unconstrained geometry, like an [SVG import](doc:sketch/import-svg).

**What is read:** lines, arcs, circles, ellipses, and polylines (curved polyline segments become exact arcs). The file's units are used when it says them (inches, centimetres, metres…), and millimetres when it does not.

**What is left out:** splines, text, blocks, hatches and dimensions. SimplMaker tells you which kinds it found. In most CAD programs a spline can be saved as a polyline, and text can be exploded into outlines, before you export the DXF.

Only the text form of DXF is read. If a file says it is binary, save it again as an ASCII DXF.

## Export

Right-click a sketch in the browser or in the viewport and choose **Export as DXF…**. Its lines, arcs and circles are written as they are. Spline curves and ellipses are written as fine polylines. Construction geometry is left out, and the numbers are **millimetres**.

:::tip
For a laser-cut or milled plate, sketch the outline and holes on a plane, dimension them, and export the sketch. The same sketch can also be extruded into the 3D part.
:::
