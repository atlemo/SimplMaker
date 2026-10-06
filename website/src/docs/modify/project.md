---
title: Project
description: Throw sketch shapes, such as text, onto a body so they follow its surface, raised out of it or cut into it.
---

**Project** works like a projector. It throws sketch profiles onto a body so they follow the surface, flat or curved. Use it for text on a cylinder or a logo on a sphere. Key: [[O]]. It is in the **Modify** group.

## Use it

1. Sketch the shapes on a plane in front of the body. For text, use the [Text tool](doc:sketch/text).
2. Press [[O]] for **Project**.
3. Click the **profiles**, such as the letters of a text. [[⇧]]-click for several.
4. Click the **face** to project onto. Or press [[Return]] to use the whole body when it is the only one.
5. Drag the arrow on the surface, or type the height or depth, and press [[Return]].

The profiles land along the sketch's normal (or against it) on the faces that face the sketch. A round post gets them on the sketch side only.

## Emboss or deboss

| Type | Does |
|---|---|
| **Emboss** | Raises the shapes by a **Height** and joins them to the body |
| **Deboss** | Cuts them in by a **Depth** |

Choose in the inspector.

## Inspector

| Field | What it does |
|---|---|
| **Type** | Emboss or Deboss |
| **Height** or **Depth** | How far it stands out or goes in. It takes expressions. |
| **Flip direction** | Projects the other way. It is set to point at the body when you start. |
| **Profiles** | How many are used. **Reselect…** picks them again. |
| **Faces** | *All that face the sketch*, or the faces you limited it to. Use **Project onto the selected faces** to limit it, or **Project onto every face instead**. |

## Limits

It is a **projection**, not a wrap. The shapes are not unrolled, so they stretch where the surface turns away from the sketch, and nothing lands on a face seen edge-on. For text that wraps right round a cylinder, keep it narrow.

:::tip
Printed text needs to be bold and large enough for your nozzle. Pick a bold font, and raise it by at least a couple of layers.
:::
