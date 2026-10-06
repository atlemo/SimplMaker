---
title: Combine
description: Join bodies together, cut one from another, or keep only where they overlap.
---

**Combine** does boolean operations between bodies. Key: [[J]]. It is in the **Modify** group.

## Use it

1. Press [[J]] for **Combine**.
2. Click the **target** body first: the body you want to change. Click any face or edge of it, or pick it in the browser.
3. Click the **tool** bodies to combine with it. [[⇧]]-click for more.
4. Press [[Return]].

The first body picked is the target. The status bar counts the tools you have picked.

## Operations

| Operation | Result |
|---|---|
| **Join** | The bodies become one |
| **Cut** | The tool bodies are removed from the target. Cut text out of a plate, or a pocket out of a block. |
| **Intersect** | Only the volume where the bodies overlap remains |

## Inspector

| Field | What it does |
|---|---|
| **Operation** | Join, Cut or Intersect |
| **Target** | The body that is changed |
| **Tool** or **Tools** | The bodies it is combined with |
| **Keep tool bodies** | Leaves the tool bodies in place after the operation, so you can use them again |
| **Swap Target and Tool** | Swaps them, when there is one tool |

## Tips

- Make the cutting shape its own body with **New Body**, then Combine, when you want to be able to move or change the tool afterwards.
- Hide a tool body with its eye in the browser while you work.
