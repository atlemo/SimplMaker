---
title: Work with an AI assistant
description: Connect Claude to SimplMaker in one click, then let it build, change, check and look at your part while you watch.
---

SimplMaker can let an AI assistant work on your part. Connected to **Claude Desktop** or **Claude Code**, the assistant can see the parts you have open and change them while you watch. You ask in plain words, for example *"Make a key ring with my name on it, about 35 mm long and 3 mm thick"*, and the features appear on the [timeline](doc:concepts/timeline) one after another, with the sizes as [parameters](doc:concepts/parameters) you can change yourself afterwards.

This is a beta feature, and it is off until you turn it on in **Settings → AI**. SimplMaker does not listen for assistants until you do.

![Claude Desktop beside SimplMaker. The assistant built a bridge as separate bodies, with its sizes as parameters you can change yourself.](shot:ai-assistant)

## What you need

- Claude Desktop or Claude Code on the same Mac. [Get Claude](https://claude.ai/download) if you have neither.

## Connect an assistant

1. Open **SimplMaker → Settings…** and choose **AI**.
2. Switch on **Let AI assistants work with SimplMaker**. The status line says whether it is off, waiting for an assistant, or connected.
3. Under **Connect an assistant**, find the app you use.

### Claude Desktop

Press **Connect**. SimplMaker adds itself to Claude Desktop's list of tools. If Claude is already running it asks to **Quit and Reopen Claude**, because Claude only reads its list when it starts. Your conversations are kept, but anything you were in the middle of typing may be lost. When Claude is back, the button changes to **Connected**.

### Claude Code

Press **Copy Command** and paste it into a terminal once. It adds SimplMaker for every folder you use Claude Code in. The row says **Added**, and then **Connected** after Claude Code first reaches SimplMaker.

If you have moved or reinstalled SimplMaker, the row says it was set up for another copy. Copy the command again to update it.

### Starting SimplMaker for you

If SimplMaker is closed when the assistant first needs it, the assistant opens it in the background and waits a few seconds. Starting Claude alone never opens SimplMaker. If **Let AI assistants work with SimplMaker** is off, SimplMaker still opens, and the assistant is told to ask you to switch it on.

## Ask for something

The pane lists a few things to try, each with a copy button:

- *What's in my open SimplMaker part?*
- *Make a key ring with the name Jane Doe on it, about 35 mm long and 3 mm thick.*

The first time the assistant changes your part, Claude asks you for permission. Choose **Always allow** to stop it asking each time.

## What the assistant can do

- **Look.** Read the open parts, their features, bodies, sizes and parameters, what you have selected, and take a picture of the viewport. A picture can show only some bodies, cut the part open, or draw sketches.
- **Build.** Make sketches and shapes: box, extrude, revolve, sweep, loft, pipe, rib, and the others in the toolbar. In a sketch it draws rectangles, circles, polygons, lines, arcs, text and smooth **splines**, so an organic outline such as a sole or a leaf is one smooth curve that can be rounded later.
- **Finish.** Fillets, chamfers, holes, threads, shells, draft, project, move, scale, lay on floor, combine, split, mirror and pattern.
- **Change.** Edit a feature, a sketch or a parameter, delete a feature, name, colour or hide a body, and undo or redo.
- **Read a mesh.** Cut any body, an imported STL most of all, with a plane at as many positions as it likes and read the outline, thickness, tilt and centre of each cut. That is how it works out what a scan is made of and draws it again as features you can edit, with **Twist Sweep** for blades and other twisted shapes.
- **Measure and check.** Measure distances and sizes. A **design check** looks over a part meant for printing and reports what is likely to go wrong: overhangs, thin walls and narrow gaps, tight or loose fits between separate bodies, a part that is bigger than the print bed or that floats above or sinks below the bed, and sizes that are not parameters. It only reports. It never changes anything.
- **Files.** Export a part as STL or STEP, and import a STEP or STL file.
- **Follow a guide.** A built-in design guide holds print-friendly sizes and recipes for things such as a snap-fit lid, a rounded box, a name tag, a screw-post case and a print-in-place hinge. The assistant reads it before it designs.

The assistant works through the same features you use, so everything it makes is on the timeline and can be edited by hand.

### Safe by design

- **Every change is one step in Undo.** Press [[⌘Z]] to take it back.
- **You see it happen.** The status bar says what the assistant is doing, such as *Creating Box1*.
- **It sees only your open parts.** It cannot read other files on your Mac.
- **Files go to one folder.** Exports are written to a folder called *SimplMaker Exports* in your Documents folder, and never over an existing file. Imports take only STEP and STL files that you give it a path to.

## What the assistant did

Under the connection settings, **What the assistant did** lists each action, newest first, with the time, which tool it used and how long it took. A tick is a change, an eye is something it only looked at, and a cross is something that failed. **Include looking** shows or hides the looking. **Copy** puts the whole log on the clipboard, and **Clear** empties it.

## Advanced

Open **Advanced** in the AI pane for what the connection is made of.

| Item | What it is |
|---|---|
| **Address** | The local address SimplMaker listens on. It only answers on this Mac. |
| **Secret** | A password that keeps other programs and websites from using the connection. **Show** reveals it and **Copy Secret** copies it. |
| **Make a New Secret…** | Makes a new password. Every connection made with the old one stops working until you give it the new one. |
| **Write Claude Desktop Configuration Again** | Repairs the Claude Desktop entry if you have changed it. |
| **Copy Claude Code Command (network version)** | The same command as above, using the address instead of the built-in relay. |

Anyone who has the secret and is on your Mac can read and change your open parts. Do not share it.

## Turn it off

Switch off **Let AI assistants work with SimplMaker**. SimplMaker stops answering assistants.

## Good to know

- Only **parts that are open** can be reached.
- [Locking](doc:concepts/selecting) a body or sketch protects it from your own clicks. It does not stop the assistant, so tell it which parts to leave alone.
- Browser folders and some newer options, such as choosing which bodies an extrude affects, are not yet available to the assistant.
- An imported STL that is over the size limit has to be reduced first. The assistant cannot reduce it. Import it yourself with **File → Import → STL…**, which offers to reduce it.
