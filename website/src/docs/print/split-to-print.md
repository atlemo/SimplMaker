---
title: Split to Print
description: Cut a part that is too big for your printer into pieces that fit it, with pins, keys, dovetails, dowels or magnets to put them back together.
---

The **Split** workspace takes one body that is bigger than your printer's build volume and cuts it into pieces that fit. It adds connectors so the pieces line up and hold together after printing. Everything stays linked to the body: change the body and the pieces follow.

It sits between Design and Mold in the workspace list. Choose **Split** there, or right-click a body and choose **Split to Print…**, or use the command palette (⌘K).

A split is not a feature of the timeline. It is kept beside the part and has no effect on the modelling history.

## Choose your printer

Pick one of the popular printers in the **Printer** menu of the ribbon, or **Custom volume** and type the width, depth and height. The preset sizes are the makers' published build volumes. If yours differs, use a custom volume.

The **Margin** (3 mm to start) is kept free all round the bed for the skirt, the brim and the edge. The pieces have to fit the build volume less this margin.

With **Turn pieces to fit** on, a piece may stand on the bed any way up, so a long piece can lie down or stand up. SimplMaker then plans the cuts for the way that needs the fewest pieces. Turn it off to keep every piece the way it stands in the model.

## Cuts

By default the cuts are **Automatic**: the fewest pieces that fit, cut evenly. A connector that sticks out of a piece takes some of its length, and the plan leaves room for it.

- The **X Y Z** menus in the ribbon set how many pieces go across each axis. **Automatic** lets SimplMaker choose.
- Choose **By hand** in the panel to place each cut yourself: an axis and a coordinate of the world. The cuts you had stay where they are when you switch.

A piece that is still too big is drawn in red, and the panel says which one.

## Connectors

| Type | What it is | Good for |
|---|---|---|
| **Flat (glue)** | No connector | Parts you will glue and sand |
| **Round pin** | A pin on one piece, a socket in the other | Quick, easy to line up |
| **Square key** | A square key and socket | Also stops the pieces turning |
| **Dovetail** | A tab that slides into a slot | A joint that locks sideways too. Slide the pieces together |
| **Loose dowel** | A socket in both pieces and a separate dowel | Pieces that must not stick out. The dowels are exported with the pieces, or use a rod you buy |
| **Magnet pocket** | A pocket in each piece for a round magnet | Pieces you want to take apart again |

A **round pin** or a **square key** can also be made a **separate part**: choose **Separate** in the ribbon, or the **Separate part** switch in the panel. Neither piece then has anything sticking out. Both get a socket, and the pin or key is exported as a part of its own, one for each joint. Print it apart (lying or standing), or cut a rod to length. Its length is then twice the depth in each piece.

Each type has a size and a length (or depth, or magnet thickness), and the **Spacing** says about how far apart connectors go on a wide cut. SimplMaker puts them where they fit inside the body with a wall round them, and says so when a cut has no room for one.

## Fit

The **Fit** is the gap left all round a connector in its socket.

| Fit | Gap | When |
|---|---|---|
| **Tight** | 0.1 mm | A well tuned printer, resin, or a press fit |
| **Standard** | 0.2 mm | An FDM printer in good order |
| **Loose** | 0.3 mm | A fast or coarse print, or a pin that should slide in easily |
| **Custom** | Your number | When you know better |

Print one test joint first: every printer is a little different.

## Look at the result

The **Open** button in the ribbon, and the **Apart** slider in the panel, draw the pieces apart so you can see the connectors. The **Pieces** section of the panel lists each piece with its size and whether it fits.

## Export

**Export** writes the pieces as STL, 3MF or STEP, as one file or one file for each piece. The pieces are laid out for printing: each turned to fit the build volume if it needs turning, standing on the bed, and packed in rows on plates the size of your printer. The panel says how many plates that takes.

## Limits

- Cuts are planes square to X, Y or Z.
- The body has to be a valid solid. Repair a broken imported mesh in Design first.
- One body to a split. You can make several splits of a part.
