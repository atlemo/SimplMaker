---
title: Render view
description: Show a part on a solid floor with a light you set, soft shadows and a reflection, with quality presets up to a photographic look, ready for a picture or a presentation.
---

The **Render view** gives a part a presentation look. The grid gives way to a solid floor, the body edges go, and the part is lit by a light you can move, with soft shadows and a faint reflection in the floor. It only changes what you see. Nothing goes on the timeline and the view's own settings are not saved in the file. The one thing it shows that the file does remember is a body's [material](doc:modify/appearance): metal, glass or wood.

![A part in the Render view, with the options panel top left.](shot:render-view)

## Turn it on

Press the **Render** button (a camera) at the right end of the toolbar, left of the Inspector button. You can also choose **View → Render**, or right-click in the viewport and choose **Render View**.

Press the button again to turn the view off. The options panel opens in the top left corner of the view while the view is on. The browser, the Inspector and the timeline close when the view comes on, to give the part the whole window. The buttons in the toolbar bring them back, and they come back by themselves when the view goes off. The options panel floats above the status bar, and scrolls when the window is too short for it.

- The view needs a shaded [visual style](doc:start/navigation). If you were in a wireframe style, turning it on switches to **Shaded with Visible Edges**.
- It does not work together with the [3D Print Preview](doc:print/print-preview). Turning one on turns the other off.
- While you [sketch](doc:sketch/start) the Render button is greyed out and you see the sketch as usual. The Render view comes back when you finish the sketch.
- Finished sketches and construction planes are hidden, so the part is shown alone. They come back while a tool is waiting for you to pick something that needs them, such as a profile to extrude or a plane to sketch on. A [canvas](doc:create/canvas) picture stays.
- You can keep working in it. Clicking and hovering pick faces and edges as always, and picks go through the floor.

## Two tabs and a quality preset

The options panel has two tabs. **Simple** holds what an everyday render needs: the quality preset, the floor, the room and the light, the shadows, and the export. **Advanced** holds, one by one, the settings that the quality presets switch on together.

At the top of **Simple** you choose a **Quality**:

| Quality | What you get |
|---|---|
| **Simple** | The fast look: flat light, soft shadows and a reflection. It stays smooth on any Mac, and it is the look this view always had. |
| **Realistic** | Physical light with a filmic curve, ambient occlusion, contact shadows, a softbox overhead, a little glow and darker corners, and glass that bends what is behind it. |
| **Photo** | All of that a bit stronger. The best picture, and the slowest to draw. Exports are made from 64 pictures. |
| **Custom** | Where the settings are once you change one in the Advanced tab. It is a label, not something to click. |

A quality preset does not move the light, the floor or the room. It only sets the quality settings. Settings from before the presets existed start as **Simple**, so nothing changes until you choose another. A new installation starts at **Realistic**.

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
- **Room** is the room that shiny bodies reflect, and the colour of the light: **Studio**, **Light tent** (bright and even), **Overcast**, **Sunset** (warm and low) and **Dark studio** (almost black, with bright strips of light). The rooms are made in the program, not photographed, so they look the same on every Mac.

A weak second light from the side keeps the faces turned away from the main light from going black.

## Shadows

With **Shadows** on, the bodies cast shadows on the floor and on each other. Under it, **Softness** sets how soft the edges are. A shadow is sharp where it starts at the part and gets softer the farther it falls, as with a real light. Softness is greyed out when Shadows are off. The presets set it too.

## Show edges and noise

**Show edges** draws the lines along the edges of the bodies. They are off in the Render view so the part looks like a picture. Turn them on if you want an outlined look.

**Noise** adds a little grain over the whole picture: the backdrop, the floor, the reflection and the bodies. A touch of it takes the flat, digital look off smooth colours and hides banding in the soft shadows. It starts at 10%, which is subtle. At 100% it is plainly grainy, and at 0% it is off. The grain does not cover the lines of the edges or what you select, and it stays still on the screen while you turn the view.

## The Advanced tab

Each setting here is part of a quality preset. Change one and the preset becomes **Custom**.

| Setting | What it does |
|---|---|
| **Physical light** | Works out the light as light and shows it through a filmic curve, so highlights roll off instead of clipping. Every body gets a finish and reflects the room, a bit more at grazing angles. It switches on the settings below it: **Exposure**, **Finish** (matte to gloss, for plain and wooden bodies) and **Softbox** (a big soft light overhead, which also shows in shiny bodies). |
| **Occlusion** | Ambient occlusion. Corners, gaps and the foot of the part get darker, as they do where light can hardly reach. **Reach** is how far from a corner the darkening goes. |
| **Contact** | Short, sharp shadows right where bodies touch the floor and each other. They sit under the soft shadow of the main light. |
| **Glow** | A soft glow round what is brighter than the floor. Highlights on shiny bodies glow, and a white part on a white floor does not. |
| **Vignette** | Darker corners of the picture. |
| **Depth blur** | Depth of field: what is at the focus point stays sharp and what is nearer and farther blurs. No quality preset turns it on. It is off until you do. |
| **Focus** | **Select focus point**, then click on the part (or the floor): that spot is sharp. The cursor is a crosshair until you click, and Esc cancels. Picking a point turns the blur on if it is off. **Auto** goes back to the middle of the part. The point is kept for the session, not in the file. |
| **Glass refraction** | Glass bends the floor and the room behind it, and thicker glass is darker. A body standing behind the glass is seen through it, but not bent. It needs Physical light. |
| **Noise** | The grain, as below. |

Occlusion, glow and depth blur are made over the finished picture, so they need a little more work from the graphics chip. If turning the part feels slow, go back to **Simple**.

## Reset and double-click

- **Reset** in the top right corner of the panel puts every setting back to its start (the **Realistic** preset).
- **Double-click** a slider, or the dial, to put just that one back.

The settings are kept between launches, and they are the same for every part. They are not saved in the part's file.

## Make a picture

Press **Export render** at the bottom of the panel (or choose **File → Export Image…**) to save what the view shows as a picture. It is the view alone, at its full pixel size, without the panels, the toolbar and the navigation cube. Anything drawn in the view goes in it, including a selection and the edge lines if they are on. File → Export Image… works the same way in the ordinary 3D view, with the Render view off.

1. Put the part on the floor and set the view you want. [[⌘0]] fits it in the window. A bigger window makes a bigger picture.
2. Click an empty place to clear any selection, and move the pointer off the part so nothing is lit up.
3. In the dialog that opens, a small preview shows the picture. Choose the **Format**, **PNG** or **JPEG**.
4. Choose the **Quality**. **Standard** is one picture, as you see it. **High** and **Maximum** make 16 or 64 pictures, each a little to one side, and average them: smooth edges, and occlusion and soft shadows without grain. It takes a moment.
5. Press **Export…**, and choose where to save it.

### A transparent background

Switch on **Transparent background** to leave the backdrop out, so the picture is only the part, with see-through pixels around it. Put it on a web page, a slide or a photo and it takes the colour behind it. Soft edges and glass come out right. Only **PNG** can be see-through, so the switch is off for JPEG.

In the Render view the floor is left out too, with its shadows and reflection, and so are the grain, glow and darker corners (they would tint the see-through part). In the ordinary 3D view the grid and the axes go.

The picture an AI assistant makes of a part is not changed by the Render view. See [Work with AI](doc:ai/assistant).

## Good to know

- **View → Render Options** shows and hides the panel while the Render view stays on. The **×** in the panel's title row hides it too. The Render button turns the whole view off. Right-click in the viewport and choose **Show Render Options** to bring the panel back.
- With [Section Analysis](doc:modify/section-analysis) on, the cut bodies show without shadows. The floor shadows stay.
- The shadows cover the area around the part. With a very low light (a small Height), a long shadow can be cut off where that area ends.
- With the [Exploded view](doc:modify/exploded-view) on, the floor and the shadows follow the bodies as they are pulled apart.
- Colours you gave bodies in [Appearance](doc:modify/appearance) show in the Render view too, under the new light.
- Colours and the look do not go into an STL or STEP file.
