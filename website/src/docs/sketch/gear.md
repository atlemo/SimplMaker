---
title: Gear
description: Draw an experimental spur gear with teeth, module, pressure angle, backlash and bore, and change it later.
---

The **Gear** tool draws a spur gear: a round wheel with straight teeth, for gears that mesh. Press [[K]] to pick it. The tool is experimental: it works, but may change.

## Draw one

1. Press [[K]].
2. Set the values in the fields beside the pointer, before or after the first click. Type a number and press [[Tab]] for the next field.
3. Click where the centre goes. A faint outline follows the pointer until you click.

| Field | What it does |
|---|---|
| **Teeth** | How many teeth, 6 to 200. |
| **Module** | The size of the teeth, in mm. The pitch diameter (the circle where two gears touch) is the module times the number of teeth. |
| **Pressure angle** | How steeply the teeth lean. 20° is the usual value. Leave it unless you are matching an existing gear. |
| **Backlash** | How much thinner each tooth is made, in mm. A little (0.1 to 0.2 mm) lets printed gears turn without binding. |
| **Bore** | The diameter of the hole through the middle, in mm. 0 for no hole. |

Values can be parameters or expressions, such as `teeth` or `module * 2`, so a gear follows your parameters like any other part of the sketch. See [Parameters and expressions](doc:concepts/parameters).

## Change it

After you click, the gear is drawn and the same fields change *that* gear: type a new number and it is drawn again at once. [[Return]] keeps the change, and [[Esc]] takes it back.

To change a gear later, choose the Select tool and click it. The Gear tool opens with that gear's fields. [[⌫]] deletes it while it is open.

## The gear as geometry

The gear is a single object. Its teeth are not separate curves, so you can't drag or constrain a tooth. Its centre is an ordinary point: drag it, dimension it, or constrain it, and the gear follows. Click an existing point, such as the sketch origin, to centre the gear on it.

Extrude a gear like any other shape, and the solid follows when you change its values. With a bore, the toothed ring and the hole are separate regions, so extrude the ring.

:::note
The teeth are smooth curves that follow the true tooth shape to within 0.002 mm. The tooth roots are not rounded.
:::

## Mesh two gears

Two gears mesh when they have the same module and pressure angle. Place their centres *(teeth of the first + teeth of the second) × module ÷ 2* apart, for example 32 mm for 12 and 20 teeth at module 2. Turn one gear so a tooth of the first points into a gap of the second.

## Next

[Editing curves](doc:sketch/edit)
