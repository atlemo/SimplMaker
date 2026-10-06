---
title: Shell
description: Hollow out a body, leaving the faces you pick open. Boxes, enclosures, cups and lids.
---

**Shell** scoops out the inside of a body and leaves a wall of even thickness. Key: [[S]]. It is in the **Modify** group.

## Use it

1. Press [[S]] for **Shell**.
2. Click the **faces to leave open**, such as the top of a box. [[⇧]]-click for more. The status bar counts them.
3. Press [[Return]]. The body is hollowed, and a size field appears for the wall thickness.
4. Type a thickness or drag the arrow, then press [[Return]].

![A box shelled with its top face open.](shot:shell-edit)

## Inspector

![The shell inspector.](shot:inspector-shell)

| Field | What it does |
|---|---|
| **Thickness** | The wall thickness. It starts at `2 mm` and takes expressions. |
| **Walls inside the body** | On: the walls grow inward, so the outside size stays the same. Off: they grow outward. |
| **Open faces** | How many faces are left open. **Open the selected faces too** adds more. |
| **Body** | The body being shelled |

## Order matters

Shell **before** you fillet or add other detail to the outside. A wall cannot follow a corner tighter than it is thick. If a fillet earlier in the timeline has a radius of 2 mm and you shell with 2 mm walls, the shell fails. The error says so:

![An error explains why the shell failed.](shot:inspector-shell-error)

Either use a thinner wall, or move the shell earlier in the timeline, before the fillets. See [The timeline](doc:concepts/timeline).

## Tips

- For 3D printing, choose a wall that is a multiple of your nozzle's line width. 1.2 mm to 2 mm suits most printers with a 0.4 mm nozzle.
- Leave the top open for a box, and make the lid as a second body.
