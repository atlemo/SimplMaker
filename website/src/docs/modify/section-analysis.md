---
title: Section Analysis
description: Cut the bodies by a plane, a face, a sketch or a canvas to look inside them, and drag the cut in or out.
---

**Section Analysis** slices the view through your bodies, like a cross-section drawing, so you can check wall thickness, hollow parts, and how pieces fit together inside. It only changes what you see: no feature is added, nothing goes on the timeline, and nothing is saved in the file. Key: [[⇧A]] (every plain letter was already taken; you can change it in Settings). It is in the **Inspect** group, next to [Measure](doc:modify/measure).

## Use it

1. Press [[⇧A]] for **Section Analysis**, or right-click a face and choose **Section Analysis at Face**.
2. Click what to cut at: an **origin plane**, a **construction plane**, a **flat face**, or a **sketch**. A sketch or a canvas in the browser works too: click it there.
3. **Drag the arrow** in the view to slide the cut in or out, 1 mm at a time (hold [[⌥]] to move freely), or type a distance in the **Offset** field of the panel at the top left.

The cut shows the solid material hatched and filled, with a dark outline where the plane meets the surfaces. The side of the plane facing you when you clicked is the side that is cut away.

If the plane you pick does not pass through the model (a face on the outside of a part, or the floor under it), the cut starts halfway through the model, so you see something at once. Drag it from there.

## The panel

- **Show the cut** turns the view on and off. The plane is kept, so turning it back on returns to the same cut. The same switch is in the **View** menu and the viewport's right-click menu.
- **Cut at** says which plane the cut follows. If the sketch or face moves when you change the model, the cut moves with it.
- **Offset** is how far the cut is from that plane. You can type a length with units, or a parameter expression.
- **Flip Side** cuts away the other side of the plane. The plane stays put.
- **Other Plane…** lets you click another plane, face or sketch.
- The **×** ends the analysis.

## Good to know

- You can keep working while the cut is on: sketch on the cut plane, measure, or pick faces. Clicks go to the faces that are left, and the hatched cut face itself cannot be picked.
- The cut works with every visual style and with the 3D Print Preview. In the wireframe styles the edges are cut, without a filled face.
- A body has to be a closed solid for the cut face to be filled.
