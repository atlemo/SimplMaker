---
title: Move, scale, pattern and mirror
description: Move, turn, scale, repeat and mirror curves inside a sketch, or transform a whole sketch.
---

The **Transform** group in the sketch toolbar works on the curves and points you have selected. With nothing selected, it works on the whole sketch. The same commands are in the **Sketch** menu.

## Move

Press **Move**. A manipulator appears on the selection:

- Drag an **arrow** to slide along the sketch's x or y.
- Drag the **square** or the **dot** to slide in both directions.
- Drag the **ring** to turn about the middle of the selection.

The sketch follows live. Let go to keep the change as one undo step. Or type an **X**, a **Y** and an angle in the fields under the manipulator and press [[Return]]. Pick another selection and the manipulator moves to it. [[Esc]], or the tool's button again, turns it off.

A constraint or dimension that would pull the geometry back, such as a fixed point or a distance from the origin, puts it back and shows a message.

## Scale

Press **Scale**. A box asks for a factor, such as `1.5` or `width / 40`. It scales about the middle of the selection, or about the sketch origin when nothing is selected.

Circle radii, text height and the dimensions that measure what grows go along. A quarter turn swaps horizontal and vertical constraints.

## Pattern

Press **Pattern** to copy the selected curves in a **Rectangular** grid or a **Circular** run.

The copies show live and stay **linked**. They are rebuilt from the originals, so moving, resizing or dimensioning an original, or changing a parameter, moves every copy.

### Rectangular

- Drag the arrow along x or along y to set the spacing between columns or rows.
- Type the **counts** and **spacings** in the fields. The original counts as one. A negative spacing goes the other way.

### Circular

- Drag the **ring** to set how far the copies spread. 360° goes all the way round. Less puts the last copy at the end of the angle.
- Type the **count**.
- Click a sketch point to copy around it. The sketch origin is used to begin with.

Counts, spacings and the spread can be expressions or parameters (`n`, `width / 2`). Dragging replaces the expression with a number.

Press [[Return]] or **OK** to keep the pattern as one undo step. [[Esc]] or **Cancel** takes it back.

### Change or remove a pattern

Click one of its copies with the Select tool to change it. Or press **Pattern** while one of its copies is selected, or while the curves it copies are, or when the whole sketch is exactly what it copies: the pattern opens instead of a new one starting. **Delete** (or [[⌫]]) in the panel removes the copies and leaves the originals.

The copies are read-only: you can't draw to them, constrain them or drag them, but you can extrude their profiles like any other. A pattern makes at most 400 copies, and curves added to the sketch later are not part of it.

## Mirror

Press **Mirror** to copy the selected curves to the other side of a line. Like a pattern, the mirror image stays **linked**: it is rebuilt from the originals, so changing an original, a dimension or a parameter changes the image too.

1. Select the curves to mirror, or select nothing to mirror the whole sketch.
2. Press **Mirror**.
3. Click the **line** to mirror across: a drawn line, a **construction line**, or a **projected edge** from the model. Or press **X Axis** or **Y Axis** in the bar at the bottom to mirror across the sketch's own axes.
4. Press [[Return]] or **OK** to keep it. [[Esc]] or **Cancel** takes it back.

Click another line, or an axis button, to change the line before you keep it.

A shortcut: select the curves **and one construction line**, then press **Mirror**. The construction line is the line to mirror across, and the mirror is made at once, ready for [[Return]].

Draw the construction line first, and a mirror is a quick way to draw one half of a part and get the other for free. A point that sits on the mirror line is shared by the shape and its image, so a half that touches the line and its image make **one closed outline**: it offsets, extrudes and selects (double-click) as a whole. The line itself is never copied. Text is not mirrored.

### Change or remove a mirror

Each mirror has a **Mirror button** (the two-triangle icon) at the top right of its image. Click it to open the mirror and change the line it goes across. Clicking a mirrored curve only selects it: click one, or double-click to select the whole outline. With a mirrored curve selected, pressing **Mirror** does the same as the button. The button stays when constraint symbols are hidden. **Delete** (or [[⌫]]) removes the mirror image and leaves the originals, either in the bar or on a selected image.

The image is read-only like a pattern's copies: you can't draw to it, constrain it or drag it, but you can extrude its profiles. A mirror copies what other mirrors and patterns made, so a shape you have mirrored once can be mirrored again, image and all, across a second line. Mirrors are made in order: change an earlier one and the later ones that copy its image follow. Curves added to the sketch later are not part of a mirror; press **Mirror** again for them.

If you leave the sketch while the mirror bar is open and a line is chosen, the mirror is kept, as if you had pressed **OK**.

Mirroring bodies, not sketches, is in [Mirror and pattern](doc:modify/mirror-pattern).

## Move and scale a whole sketch

To move, turn or scale a whole sketch in 3D, select it in the browser, then right-click and choose **Move or Rotate Sketch** or **Scale Sketch**. These add **Move** and **Scale** features to the timeline. See [Move, rotate and scale](doc:modify/move-scale).

The **Scale** tool in the Modify group of the design toolbar does the same for sketches.
