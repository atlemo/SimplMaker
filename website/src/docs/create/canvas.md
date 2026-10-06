---
title: Canvas (reference image)
description: Place a picture on a plane or face to trace over and measure against.
---

A **canvas** puts an image into the part, lying on a plane. Trace it with sketch tools, or check your model against a photo or a drawing. Key: [[V]]. It is in the **Construct** group, and in **Create → Canvas (Reference Image)…**

## Place one

1. Select a flat face or a plane first, or press [[V]] and click one while the tool waits. You can also right-click a face or plane and choose **Insert Image…**.
2. Choose a PNG, JPEG, HEIC or TIFF file.

The picture lies on that plane at its middle, upright as the view shows the plane.

Clicks and sketching **pass through** the canvas, so it never gets in the way.

## Inspector

| Field | What it does |
|---|---|
| **File** | The image file. **Replace Image…** swaps in another. |
| **On** | The plane it lies on |
| **Opacity** | How see-through it is. A slider, and it rebuilds nothing. |
| **Width** | How wide it is. The height follows the picture's proportions. |
| **Across**, **Up** | Its position on the plane |
| **Turn** | Its rotation |

Width, position and turn take expressions. A canvas builds no geometry.

The image is kept **inside the part**. Canvases are listed in the **Canvases** folder of the browser, where the eye hides one.

## Tips

- Set the width to a known size in the picture, such as the width of a coin, and you can trace to scale.
- Turn the opacity down to see the model through the picture.
