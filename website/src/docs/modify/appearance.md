---
title: Appearance and colours
description: Give bodies a colour and a material (plastic, metal, glass or wood). Both are saved in the file and need no rebuild.
---

Colour makes a part easier to read, and helps tell bodies apart in an assembly. Key: [[A]].

## Colour a body

1. Press [[A]], or choose **View → Show Appearance**. The Appearance panel opens in the top-right corner.
2. Select the **bodies** in the viewport (a face or edge counts for its body) or in the panel's list. [[⇧]]-click for more.
3. Click a colour.

![The Appearance panel.](shot:appearance-panel)

- Click any swatch, or **Custom Colour** for any colour you like.
- **Default** puts the standard colour back.
- Right-click a body in the browser and choose **Appearance…** to open the panel for it.

![A body in a custom colour.](shot:appearance-result)

## Materials

Under the colours, the **Material** row makes the selected bodies **Plastic**, **Metal**, **Glass** or **Wood**. **Plain** is the ordinary look.

- **Plastic** is a moulded surface in the body's colour. Its **Roughness** slider runs from a glossy part that shows the lights of the room as clear highlights to a matte one that only shows a soft sheen. The slider appears under the tiles when plastic is selected. It is one undo step, and a double-click puts it back to the plastic's own.

- **Metal** reflects a small studio, tinted by the body's colour. Curved parts show it best. It has a **Roughness** too, from polished to brushed.
- **Glass** is see-through, tinted by the body's colour, with a bright edge at grazing angles. Glass casts no shadow, so a glass lid doesn't blot out the floor.
- **Wood** draws grain rings and fibres in the body's colour. The grain is fixed in space, so a body that moves slides through it, as if cut from the same log.

![A wooden block, a glass spring and a metal ring in the Render view, with the Material row in the Appearance panel.](shot:appearance-materials)

Materials show in the [Render view](doc:modify/render) only. In the everyday view a body is drawn in its colour, as before. A body with no colour of its own gets one that suits the material (an off-white for plastic, a wood brown, a light blue for glass, aluminium for metal) when you pick it. A colour you chose is kept.

## Good to know

- Colours and materials are **saved in the file**.
- They can be **undone**.
- They need **no rebuild**, so changing a colour or material is instant.
- While you sketch, the key belongs to the sketch tools ([[A]] draws an arc), so the Appearance menu item is off.
- Colours don't go into an STL file. They are only for looking at the model.
