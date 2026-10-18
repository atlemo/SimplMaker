---
title: Text in sketches
description: Add text to a sketch, choose a font and height, and use the letters to extrude, cut or emboss.
---

Text in a sketch is made of **profiles** (the letters), so you can use it like any other shape: extrude it, cut it out of a plate, or [project it onto a curved surface](doc:modify/project).

## Add text

1. Start a sketch and press [[X]] for the **Text** tool.
2. Click where the text should start.
3. Type the words and press [[Return]].

The letters appear in the sketch as you type, at the size and place they will have. Press [[Esc]] to drop the text instead.

To change the words later, click the text with the Text tool, or double-click it with the Select tool. The letters follow what you type there too.

## Size and font

Select the sketch and look under **Text** in the inspector:

| Field | What it does |
|---|---|
| **Text** | The words |
| **Height** | The height of the letters. It takes an expression such as `label_h`. |
| **Font** | One of the offered fonts |

Fonts offered: Helvetica Bold, Helvetica, Avenir Next, Futura Bold, Arial Rounded, Menlo Bold and Georgia Bold. For 3D printing, bold and rounded faces hold up best at small sizes.

![Text in a sketch on the face of a body. The Text, Height and Font fields are in the inspector.](shot:sketch-text)

## Move, scale and turn text

Text moves, scales and turns with the rest of the sketch. See [Move, scale and pattern](doc:sketch/transform). A turned copy of text turns with it.

## Use it

Click any letter of a finished text to pick the whole text, and hover to see what a click would pick. [[⇧]]-click adds or removes a whole text, and [[⌥]]-click picks a single letter. The insides of letters such as O and B are not part of the text, so extruding it does not fill them.

- **Extrude** the letters to raise them, or choose **Cut** to engrave them. One click on the text is enough. See [Extrude](doc:create/extrude).
- **Project** them onto a curved or angled face. See [Project](doc:modify/project).
