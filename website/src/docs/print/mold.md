---
title: Make a mold
description: Make a printable mold around a body, in two or four pieces, to cast copies of it in silicone or resin. With a gate, vents, keys and a check that the pieces can let go.
---

The **Mold** workspace makes a mold you can 3D print. Pick a body and SimplMaker builds a block around it, cuts the block into two pieces (or four), and hollows out the shape of the body. Pour silicone or resin in, wait, open the mold, and there is a copy.

It sits between Split and Render in the workspace list. Choose **Mold** there, or right-click a body and choose **Make a Mold…**, or use the command palette (⌘K).

Mold is marked **Experimental** in the workspace list: it works, but it is new, so print a small test mold before a big one and tell me what you find.

A mold is not a feature of the timeline. It is kept beside the part and linked to its body: change the body and the mold follows. It has no effect on the modelling history.

![The Mold workspace: the two halves of a mold drawn apart, with the cast body between them.](shot:mold-workspace)

## Make one

1. Choose **Mold** in the workspace list.
2. Every body is drawn and lights up as you point at it. **Click the body** to cast, or press **Make Mold** beside its name in the **Bodies** panel.
3. The mold builds in the background. The **Mold** panel on the right shows what it comes to: the **silicone** to mix in millilitres, the size of the block, and any warning.

SimplMaker picks the settings for you: it parts the mold across the body's shortest side, through the middle, pours from the top, puts the gate at the highest point, and adds a 10 mm wall and keys. Change what does not suit.

The pointer button in the header of the Bodies panel takes you back to choosing a body in the 3D view. You can make a mold of several bodies, one at a time. Each one is listed under **Molds**.

## Parting

The **parting plane** is where the mold opens. The ribbon has **X**, **Y** and **Z**, which part the mold across that axis through the middle of the body. The **Plane** menu in the panel also offers an origin plane or one of your own construction planes. The **Offset** moves the plane along its normal.

The plane has to be square to X, Y or Z. A plane that leans is not made yet.

**Pour from** is the way up while you pour. Stand the body the way it will be filled.

### Two pieces or four

![The same mold as four pieces, drawn apart. The red ball marks the gate.](shot:mold-four-pieces)

**2** is two halves: the simplest mold, and the quickest to print and clamp. **4** cuts each half again across a second plane, so every piece is pulled out sideways as well as away. A groove or a hook that stops two halves can let go of four pieces, and each piece is smaller to print. **Second cut** chooses the axis of that plane, or **Automatic**.

## Check that it lets go

Press **Release** in the **Check** group. The body is drawn alone and coloured by whether the pieces can let go of it when they are pulled apart:

| Colour | Means |
|---|---|
| **Green** | Lets go |
| **Amber** | No draft: a face parallel to the pull. It lets go, but it drags |
| **Red** | Undercut: a face leans back against the pull, so it would hold the casting |

The panel says how many faces are undercut. Part the body another way, cut it in four pieces, [draft](doc:modify/draft) the faces by a degree or two, or change the shape.

The **Casting** menu says what you pour:

- **Silicone** is flexible. It is peeled out of a mild undercut, so SimplMaker only warns.
- **Rigid resin** is stuck by an undercut, so the mold is refused until nothing hangs back. A face with no draft is warned about.

This check looks at the shape of each face. It does not find a face that hides behind another one along the pull.

## Gate and vents

The **gate** is the hole you pour through. It starts at the highest point of the body. Press **Gate** and click the body to put it somewhere else, or **Reset** to bring it back. It stays at the height you click. Its **Diameter** is 8 mm to start.

A **vent** is a small hole that lets air out while you pour. Air gets trapped at the top of every pocket that faces down, so give each one a vent:

- **Vent**: click the body to add one, and press Esc when you are done.
- **Auto Vents**: adds a vent at the top of every lobe of the body that the gate does not reach.
- **Clear Vents**: takes them all away.

Auto Vents finds the peaks only. The ceiling under an overhang traps air too, and needs a vent you place yourself. The gate and the vents show as small red and purple balls while the pieces are hidden. Vents are 2 mm wide to start, and 1.5 to 2.5 mm works well.

## Keys

**Keys** puts cone keys on the seams. The pieces then go together one way only, and do not slide. Each key has a **Size** and a **Clearance**, the gap left all round it in its socket (0.3 mm to start). A key that would sit in a channel is left out, and a key shrinks to fit a thin wall, with a warning.

## Sizes

The **Wall** (10 mm to start) is the thickness of the mold around the body. Every size takes an expression, so it can use a [parameter](doc:concepts/parameters).

## Look at the result

**Open** (and the slider under **View** in the panel) draws the pieces apart so you can see the cavity. **Show Grid** is off in this workspace to keep the view clear, and switching it on affects the Mold and Split workspaces only.

## Export

**Export** writes the pieces as STL, 3MF or STEP, as one file or one for each piece, laid out for printing: parting face up, cavity open, side by side.

Print them in PLA or PETG with at least three perimeters. Seal the seam with rubber bands, clamps or a little tape, and use a release agent. The wall, keys and clearance are first guesses: print a small test mold before the big one.

## Limits

- One body to a mold.
- Planes square to X, Y or Z only, and flat parting surfaces.
- A body with a hole right through it gets a pin that is part of the mold. That is fine for silicone.
- No shrinkage allowance, clamps or tongue-and-groove seams yet.
- The body has to be a valid solid. Repair a broken imported mesh in Design first.

An AI assistant can make a mold too. See [Work with an AI assistant](doc:ai/assistant).
