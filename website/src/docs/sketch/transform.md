---
title: Move, scale and pattern
description: Move, turn, scale and repeat curves inside a sketch, or transform a whole sketch.
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

Click one of its copies with the Select tool to change it. **Delete** (or [[⌫]]) in the panel removes the copies and leaves the originals.

The copies are read-only: you can't draw to them, constrain them or drag them, but you can extrude their profiles like any other. A pattern makes at most 400 copies, and curves added to the sketch later are not part of it.

## Move and scale a whole sketch

To move, turn or scale a whole sketch in 3D, select it in the browser, then right-click and choose **Move or Rotate Sketch** or **Scale Sketch**. These add **Move** and **Scale** features to the timeline. See [Move, rotate and scale](doc:modify/move-scale).

The **Scale** tool in the Modify group of the design toolbar does the same for sketches.
