---
title: Render view
description: Show a part on a solid floor with a light you set, soft shadows and a reflection, ready for a picture or a presentation.
---

The **Render view** gives a part a presentation look. The grid gives way to a solid floor, the body edges go, and the part is lit by a light you can move, with soft shadows and a faint reflection in the floor. It only changes what you see. Nothing goes on the timeline and nothing is saved in the file.

![A part in the Render view, with the options panel top left.](shot:render-view)

## Turn it on

Press the **Render** button (a sun) at the right end of the toolbar, left of the Inspector button. You can also choose **View → Render**, or right-click in the viewport and choose **Render View**.

Press the button again to turn the view off. The options panel opens in the top left corner of the view while the view is on.

- The view needs a shaded [visual style](doc:start/navigation). If you were in a wireframe style, turning it on switches to **Shaded with Visible Edges**.
- It does not work together with the [3D Print Preview](doc:print/print-preview). Turning one on turns the other off.
- While you [sketch](doc:sketch/start) the Render button is greyed out and you see the sketch as usual. The Render view comes back when you finish the sketch.
- You can keep working in it. Clicking and hovering pick faces and edges as always, and picks go through the floor.

## The floor

The floor lies in the ground plane (Z = 0), so put the part on it with [Lay on Floor](doc:modify/lay-on-floor). It fades out into a slightly darker backdrop, so the part stands in a pool of light.

| Setting | What it does |
|---|---|
| **Swatches** | The colour of the floor: White, Silver, Graphite, Charcoal, Sand or Slate. The name of the chosen one is shown above. |
| **Reflection** | How strongly the floor shows the part, from nothing to a clear mirror image. It is strongest where the part touches the floor and fades with height. |
| **Blur** | How blurred the reflection is. At 0 it is a mirror. Higher, it stays sharp where the part meets the floor and softens higher up, like a polished floor. It is greyed out when Reflection is 0. |

From below the floor, the floor and the reflection are not drawn.

## Lighting

The light stays where you put it in the world. Turn the view and the part is lit from the same side as before, so a picture from another angle shows other faces in the light or in the shade.

- **Studio**, **Soft** and **Dramatic** are starting points. When you change one of the settings below the buttons, the choice moves to **Custom**.
- **Direction** is a dial. Drag it round to choose which way the main light shines from, seen from above. 0° is the far side of the part and the angle grows clockwise.
- **Brightness** is the strength of the main light.
- **Height** is how high the main light stands, from 5° (low and long shadows) to 90° (straight down).
- **Ambient** is the light that comes from everywhere. More of it makes the shaded sides lighter.

A weak second light from the side keeps the faces turned away from the main light from going black.

## Shadows

With **Shadows** on, the bodies cast shadows on the floor and on each other. Under it, **Softness** sets how soft the edges are. A shadow is sharp where it starts at the part and gets softer the farther it falls, as with a real light. Softness is greyed out when Shadows are off. The presets set it too.

## Show edges and noise

**Show edges** draws the lines along the edges of the bodies. They are off in the Render view so the part looks like a picture. Turn them on if you want an outlined look.

**Noise** adds a little grain over the whole picture: the backdrop, the floor, the reflection and the bodies. A touch of it takes the flat, digital look off smooth colours and hides banding in the soft shadows. It starts at 10%, which is subtle. At 100% it is plainly grainy, and at 0% it is off. The grain does not cover the lines of the edges or what you select, and it stays still on the screen while you turn the view.

## Reset and double-click

- **Reset** in the top right corner of the panel puts every setting back to its start.
- **Double-click** a slider, or the dial, to put just that one back.

The settings are kept between launches, and they are the same for every part. They are not saved in the part's file.

## Make a picture

Press **Export render** at the bottom of the panel to save what the view shows as a PNG file. It is the view alone, at its full pixel size, without the panels, the toolbar and the navigation cube. Anything drawn in the view goes in it, including a selection and the edge lines if they are on.

1. Put the part on the floor and set the view you want. [[⌘0]] fits it in the window. A bigger window makes a bigger picture.
2. Click an empty place to clear any selection, and move the pointer off the part so nothing is lit up.
3. Press **Export render**, and choose where to save it.

The picture an AI assistant makes of a part is not changed by the Render view. See [Work with AI](doc:ai/assistant).

## Good to know

- **View → Render Options** shows and hides the panel while the Render view stays on. The **×** in the panel's title row hides it too. The Render button turns the whole view off. Right-click in the viewport and choose **Show Render Options** to bring the panel back.
- With [Section Analysis](doc:modify/section-analysis) on, the cut bodies show without shadows. The floor shadows stay.
- The shadows cover the area around the part. With a very low light (a small Height), a long shadow can be cut off where that area ends.
- Colours you gave bodies in [Appearance](doc:modify/appearance) show in the Render view too, under the new light.
- Colours and the look do not go into an STL or STEP file.
