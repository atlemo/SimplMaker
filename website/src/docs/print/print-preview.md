---
title: 3D Print Preview
description: Look at a part the way an FDM printer would build it: layer lines, a top skin and the outer perimeters.
---

**FDM 3D Print Preview** draws your bodies as if they had been printed on a filament (FDM) printer. You see the layer lines on the walls, the diagonal skin on the top, and the lines the nozzle follows round the edge of each flat face. It is a quick way to judge how a part will look and feel before you slice it.

It is a look, not a slice. SimplMaker does not make G-code, and the lines are an approximation. Use your slicer for the real thing.

## Turn it on

Choose **View → FDM 3D Print Preview**, or right-click in the viewport and choose **FDM 3D Print Preview**. Choose it again (the right-click item then says **Leave 3D Print Preview**) to turn it off.

The preview is a view setting. It is not saved with the part, and it does not change the part. It works with the shaded [visual styles](doc:start/navigation) only, so the menu item is greyed out while a wireframe style is on. The body's edge lines are hidden while it is on, so the layers show.

![A part in 3D Print Preview, with the options panel top left.](shot:print-preview)

## Set the layer height and the nozzle

A small panel opens in the top left corner of the view with two choices.

| Option | Choices (mm) | What it changes |
|---|---|---|
| **Layer height** | 0.12, 0.16, 0.20, 0.24 | How far apart the layer lines are |
| **Nozzle** | 0.2, 0.4, 0.6, 0.8 | How wide the perimeter lines are |

The start is 0.20 mm and a 0.4 mm nozzle. The close button on the panel hides it. The preview stays on. The choices are kept until you quit SimplMaker. They are not saved with the part.

## What to look for

- **Layer lines** on walls that lean or curve show where a slope will look stepped. A smaller layer height makes the steps finer.
- **Top surfaces** show the diagonal skin, so you can see how a flat top will look.
- **Edges of flat faces** show two perimeter lines, the width of the nozzle you chose. A wall or rib that is only as thick as these lines is a sign it may be too thin to print well. See the [design tips](doc:print/design-tips).

The [Render view](doc:modify/render) restyles the bodies too, so the two do not work together: turning one on turns the other off.

## Combine it with a cut

The preview works together with [Section Analysis](doc:modify/section-analysis), so you can cut a part open and still see the layers on the outside.

## Good to know

- The options panel is not shown while you sketch.
- In a wireframe style the bodies are drawn as usual, without layers. Go back to a shaded style and the preview is there again.
