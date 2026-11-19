---
title: Examples and the tutorial
description: The Start page, the guided tutorial, and five example parts to learn from.
---

## The Start page

SimplMaker opens on the **Start page**, a page as big as the window. It is also the **Start** choice in the mode selector at the top of every part, so you can come back to it any time (**Window → Start**, [[⇧⌘1]]).

| Choice | What it does |
|---|---|
| **New Part** | Opens an empty part in a new window, in Design |
| **Open…** | Opens a `.simplmaker` file |
| **Take the tutorial** | Starts the guided tutorial in this part, or in a new one if this part has something in it already |
| **Sketch**, **Box**, **Cylinder** | Begin this part with that tool, and move to Design |
| **Open the demo part** | Opens a plate with a hole, fillets and a chamfer |

Your recent parts are listed on the right. Double-click one, or select it and press [[Return]]. The first part of a launch opens on the Start page. A part you make yourself (**New Part**, ⌘N, a new window) opens in Design, and so does a part with features in it.

## The tutorial: a desk organizer

A guided tutorial of about ten minutes. A card at the bottom of the view walks you through making a desk organizer you can print:

- five named parameters
- a sketch and an extrusion for the floor
- a second sketch on top of the floor: its outline, traced from the floor's corners, and a guide drawn one wall thickness inside it
- three sections hung from the guide's corners, sized with typed expressions such as `(width - 3 * wall) / 2`, and one **Equal** constraint that keeps the two back sections the same depth
- an extrusion that raises the walls
- changing `width` and `depth` at the end, to watch the walls and every section follow

The card follows what you actually do. It moves on when the part shows a step is done, steps back if you undo it, and tells you when something is off, such as a rectangle drawn with plain numbers instead of parameters, an inset that went outwards, or a section filled in instead of the wall.

- The **‹** button goes back a step and undoes what you did in it.
- **Do it for me** performs the current step the way the interface would, so you can see how.
- **Leave tutorial** (or the ✕) closes the card.
- **Help → Resume Tutorial** brings it back.

What to use next pulses gently in the toolbar.

## Example parts

**File → Open Example Parts** has five parts to open and take apart:

- **Plate with Holes, Fillets and a Chamfer**: a plate with a pin hole cut from a sketch on its top face, two filleted corners and a chamfered edge.
- **Bracket Profile (try the sketch solver)**: an L-bracket drawn as one closed sketch, every size tied to a parameter. One corner of the slanted top is left free, so you can drag it and watch the solver hold everything else in place.
- **Constraints Sampler (drag the points)**: one sketch with a small cell for each [constraint](doc:sketch/constraints), already satisfied and otherwise free, so you can drag a point and see what the rule keeps in place.
- **Bracket with Ribs**: an L-bracket braced by two ribs, each grown from a sketched line.
- **Flanged Pipe on a Manifold**: an advanced five-body assembly: a manifold block, an O-ring, a flange, a pipe swept along a curved path and four threaded bolts, each body in its own colour.

Select a feature in the timeline to see how it was made, and change a parameter to see the part rebuild.
