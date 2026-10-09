---
title: Lay on Floor
description: Click a flat face and the body turns and drops to the floor, that face down and flush.
---

**Lay on Floor** puts a body down on one of its flat faces. It is for a part that floats in the scene, such as one you [imported](doc:concepts/files), and has to rest on the floor before you work on it or print it. Key: [[⇧L]] (every plain letter was already taken; you can change it in Settings). It is in the **Modify** group.

## Use it

1. Press [[⇧L]] for **Lay on Floor**, or right-click a face and choose **Lay Face on Floor**.
2. Click the **flat face** that should go down.

The body turns the shortest way until that face looks straight down, then drops until the face sits flush on the floor. The floor is the XY plane, at height zero, with Z pointing up.

If you select a face first, the tool lays it down at once.

## What you get

- The face **stays where it is sideways**. The body turns about the middle of that face, so it lands where you were looking, not somewhere else in the scene.
- Only the body you clicked moves. The other bodies stay put.
- Face and edge names are kept, so later features such as fillets and holes still find their faces.
- Only a **flat** face can lie on the floor. If you click a curved face, the tool tells you and keeps waiting.

## Inspector

The inspector shows the body and the face that was laid down. To lay a different face down, delete the feature and click the other face.

## Good to know

- The face goes to zero height, even if it is a recessed face and part of the body then sinks below the floor. Pick a face on the outside of the part, such as the widest face, for it to rest as it would on a table.
- To lay a part on its flat back and then slide it along the floor, follow it with [Move](doc:modify/move-scale).
