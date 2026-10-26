---
title: Exploded view
description: Slide all the bodies of a part apart with one slider, to show how it is built up.
---

The **Exploded view** pulls the bodies of a part apart, in equal steps, so you can see how it goes together. Drag a slider and the layers open up like an accordion: a flange lifts off its block, the bolts rise out of their holes and the O-ring hangs between them. It only changes what you see. Nothing goes on the timeline, nothing is saved in the file, and the bodies are not moved in the part.

![A pipe, a flange, four bolts, an O-ring and a block pulled apart along Z, with the Exploded View panel top left.](shot:exploded-view)

## Turn it on

Choose **View → Exploded View**, or right-click in the viewport and choose **Exploded View**. The panel opens in the top left corner of the view.

To turn it off, press the **×** in the panel, choose **View → Exploded View** again, or right-click and choose **Leave Exploded View**. The bodies slide back to where they were.

The view needs at least two shown bodies. With only one, the panel says there is nothing to pull apart.

## The slider

The slider goes from 0 % (everything in place) to 100 %. Drag it to open the part up, and back to close it again.

How it works:

- The bodies are sorted into **layers** along an axis, by the middle of each body. Bodies side by side at the same level, such as the four bolts above, share a layer and move together.
- Every layer moves one equal step away from the next, so each gap between layers opens by the same distance, whatever the size of the bodies.
- The part opens around its middle. The middle layer stays where it is when there is an odd number of layers.
- At 100 % the part is twice as long on that axis as it started.

## Direction

The **Direction** switch chooses which way the bodies go apart.

| Choice | What it does |
|---|---|
| **Z** | Along the Z axis only. The way to go for a part that stacks up: a lid, a plate, a body, a base. |
| **X** | Along the X axis only |
| **Y** | Along the Y axis only |
| **All** | Along X, Y and Z at once, so bodies that lie side by side also spread out. Use it for a part that is spread out in several directions. |

On an axis where all the bodies are on one level, nothing opens along that axis, and the picture stays as it was.

## Good to know

- **Hidden bodies** stay out of it. To leave a body out of the exploded view, hide it first with the eye beside it in the [browser](doc:start/interface).
- While you [sketch](doc:sketch/start) or use a tool, the bodies sit back in place, because the handles and previews of the tools are drawn where the bodies really are. When you are done, they slide out again. The slider keeps its place.
- You can still click bodies to select them and read their sizes in the inspector.
- **Fit All** ([[⌘0]]) fits the view around the bodies as they are drawn now, so use it when a body has moved out of the window.
- With the [Render view](doc:modify/render) on, the floor and the shadows follow the moved bodies. Together they make a good picture for a manual: use **Export render** to save it.
- With [Section Analysis](doc:modify/section-analysis) on, the cut stays where its plane is. It does not move along with the bodies.
- The exploded view is not in the file. STL and STEP exports, and the picture an AI assistant makes of a part, show the bodies in place. See [Work with AI](doc:ai/assistant).
- Bodies that lie one inside the other with the same middle, such as a pin in the centre of a ring, do not separate along the axes where their middles are the same.
