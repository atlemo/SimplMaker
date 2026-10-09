---
title: Draft
description: Lean the sides of a body over by a small angle, so a mould or a stamp can let go of the part.
---

**Draft** tilts faces by a draft angle. A box with straight sides becomes slightly narrower towards the top, the way a moulded or cast part has to be. Key: [[⇧D]] (every plain letter was already taken; you can change it in Settings). It is in the **Modify** group.

## Use it

1. Press [[⇧D]] for **Draft**, or right-click a face and choose **Draft Face**.
2. Click the **faces to lean**, such as the four sides of a box. Each click adds a face, and clicking it again takes it out. The status bar counts them.
3. Press [[Return]]. A dial with a dot appears on the first face, with a field for the angle.
4. Drag the dot round the arc, or click it and type an angle, then press [[Return]].

## The face that stays put

The faces pivot about a **flat face of the same body** that does not move: the bottom of a mould. Each drafted face keeps the line where it meets that face and leans away from it, so the body gets narrower the further it goes from it.

Draft picks that face for you: a flat face next to the first face you picked and square to it, the lowest one if there are several. To use another, such as the top, select it and press **Use the selected face as the one that stays put** in the inspector.

## Inspector

| Field | What it does |
|---|---|
| **Angle** | The draft angle, up to 85 degrees either way. It starts at `5 deg` and takes expressions. A positive angle leans the faces in, so the body gets narrower away from the fixed face. A negative angle widens it. |
| **Drafted faces** | How many faces lean. **Draft the selected faces too** adds more. |
| **Stays put** | The flat face the faces pivot about. |
| **Body** | The body being drafted |

## Good to know

- Flat faces and round walls (a shaft or the wall of a hole, which become cones) can be drafted. A face square to the pull direction cannot.
- Faces keep their names, so a fillet or hole made after a draft still finds them.
- A steep angle on a tall face can make the faces run into each other or into their neighbours. The error says so; use a smaller angle.
- Draft **before** you fillet the edges of the faces it leans. See [The timeline](doc:concepts/timeline).
- For 3D printing, a draft is rarely needed, but 1 to 2 degrees on a tall wall can help a part release from a silicone mould.
