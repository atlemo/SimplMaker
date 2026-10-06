---
title: Thread
description: Model a metric or inch screw thread on a shaft or in a hole, with a tolerance offset for 3D printing.
---

**Thread** cuts a real, modelled thread: external on a shaft, internal in a hole. Key: [[D]]. It is in the **Modify** group.

## Use it

1. Press [[D]] for **Thread**, or right-click a round face and choose **Thread…**.
2. Click the **side of a shaft** or the **wall of a hole**. If you click a flat face, the round face next to it is used.
3. The thread appears in the size that suits the face. Adjust it in the inspector and press **OK**.

[[⇧]]-click to pick several faces and thread them together with [[Return]].

The size is chosen from the face's diameter. An 8 mm shaft gets M8. A 6.8 mm hole, which is the tap drill for M8, gets an M8 thread. The face is turned or bored to the thread's diameters first, and the thread uses the basic 60° profile, without tolerance classes.

![An internal thread in a hole.](shot:thread-result)

## Inspector

![The thread inspector.](shot:inspector-thread)

| Field | What it does |
|---|---|
| **Kind** | **External** on a shaft, or **Internal** in a hole. Shown for information. |
| **Standard** | ISO Metric, ISO Metric Fine, UNC or UNF |
| **Size** | The thread size, for example M8 × 1.25 |
| **Pitch**, **Major Ø**, **Minor Ø** | The numbers for the chosen size, for information |
| **Tap drill** | For an internal thread, the drill size to use when tapping by hand |
| **Tolerance offset** | See below |
| **Length** | **Full length** of the face, or a **Distance** (drag the arrow to set it) |
| **Start from the other end** | Starts at the far end instead of the free end |
| **Left-handed** | Cuts a left-hand thread |

By default the thread runs from the free end: a shaft's tip, or a hole's mouth.

## Tolerance offset: threads that print

A printed thread comes out slightly tight. The **Tolerance offset** models the thread a little bigger on its major and minor diameters, or a little smaller if negative, to make up for it.

| Choice | Offset |
|---|---|
| **None** | No offset |
| **PETG** | +1 % |
| **ASA** | +1.5 % |
| **ABS** | +2 % |
| **Nylon** | +3 % |
| **Custom percent** | A percentage you set |
| **Custom distance** | A distance you set |

The percentages are a percentage of the major diameter. Treat the material choices as a starting point: printers differ, so print a test thread and adjust. Store the value in a parameter once you know it.

:::tip
Use the same offset on both halves, the bolt and the nut. Print a short test pair first, which takes minutes, before the big part.
:::

## Tips

- Threads add a lot of geometry. If rebuilds feel slow, thread late, or suppress the thread while you work on something else. See [The timeline](doc:concepts/timeline).
- For larger holes and bolts, a metric coarse thread prints more reliably than a fine one.
