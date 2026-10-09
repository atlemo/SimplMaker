---
title: Split Body
description: Divide bodies into new bodies along a plane, a face or a sketch profile.
---

**Split Body** cuts a body in two (or more) along a plane, a face or a sketch profile, and keeps every piece as a body of its own. Key: [[⇧S]] (every plain letter was already taken; you can change it in Settings). It is in the **Modify** group.

## Use it

1. Press [[⇧S]] for **Split Body**, or right-click a face and choose **Split Body…**.
2. Click the **bodies to split**. Click any face of a body, or pick it in the browser. Each click adds a body, and clicking it again takes it out. With only one body in the model you can skip this step.
3. Click what divides them:
   - an **origin plane** or a **construction plane**,
   - a **profile** in a visible sketch (it splits along the plane the sketch lies on), or
   - a **face**. Press [[Return]] first to tell the tool that the bodies are chosen, then click the face. A face of another body, or a face of the same body, works.

A plane, a flat face or a profile cuts **all the way through**, as if it had no edge. A curved face, such as the wall of a cylinder, cuts only **where it is**.

## What you get

- Each cut makes new bodies. The piece on the **back** of the plane (the side it faces away from) keeps the name and identity of the original body, so features made after it still find it. The other pieces are named Body2, Body3 and so on, and take on the colour of the body they came from. Rename them or recolour them in the browser.
- A body the tool does not cross **stays as it is**. If it crosses none of the bodies you picked, the feature says so and changes nothing.
- Faces keep their names. The new faces made by the cut are named after the feature, so you can still fillet or drill them.

## Inspector

| Field | What it does |
|---|---|
| **Bodies** | The bodies that are split |
| **Split with** | The plane, face or profile that divides them |
| **Split the selected bodies too** | Adds the bodies you have selected to the split |

To split along a different place, move the construction plane or sketch that the split uses; the pieces follow.

## Good to know

- To split along a plane that is not one of the origin planes, make a [construction plane](doc:create/plane) first. It can be offset or tilted.
- The pieces are separate bodies. To put them back together, use [Combine](doc:modify/combine) with **Join**.
- Splitting a hole-ridden body can make more than two pieces, if the cut separates parts that were only joined through the cut.
- To keep only one side, split, then hide the other body in the browser.
