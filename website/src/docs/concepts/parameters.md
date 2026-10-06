---
title: Parameters and expressions
description: Name your sizes once and use them everywhere. How to write values, units, maths and functions.
---

A **parameter** is a named value, such as `width = 60 mm`. Any size field can use it. Change the parameter and everything built on it rebuilds. This is the idea that makes the model *parametric*.

## The parameters list

Parameters live below the folders in the browser.

![The parameters list.](shot:parameters-panel)

- Press **+** to add one. It starts as `p1` with the value `10 mm`.
- **Double-click** the name to rename it. Every expression that uses it follows.
- Click the value to edit it. Press [[Return]] and the model rebuilds.
- Under each parameter, SimplMaker lists which features **use** it, so you can see what a change will touch. It says *Not used yet* until you use it.
- The small unit menu on the right of a parameter (`mm`) says what kind of value it is: **Length (mm)**, **Angle (deg)** or **Number**. The calculated value is shown beside it.

Names must start with a letter or `_`, and contain only letters, digits and `_`. They can't be a unit, a function or a constant (`mm`, `sin`, `pi`).

:::tip
Name things by what they mean, not what they are: `wall`, `tolerance`, `screw_d`. Then every value reads like a sentence.
:::

## Where you can use an expression

Every size field. That is the inspector, the dimension popover in a sketch, the typed size next to a drag handle, and the parameter values themselves. If a field takes a number, it takes an expression.

## Writing a value

A bare number takes the unit of its field. `10` in a length field is 10 mm. In an angle field it is 10°. Add a unit to be sure.

| Unit | Meaning |
|---|---|
| `mm` | millimetres |
| `cm` | centimetres |
| `m` | metres |
| `in` | inches |
| `ft` | feet |
| `deg` | degrees |
| `rad` | radians |

You can mix units: `1 in + 5 mm`. Inside the model everything is kept in millimetres, whatever you type.

## Maths

| Operator | Does |
|---|---|
| `+` `-` | add, subtract (both sides must have the same kind of unit) |
| `*` `/` | multiply, divide |
| `^` | power, with a whole-number exponent |
| `( )` | group |

Examples:

```
width / 2
hole_d + 0.2 mm
(width - 2 * wall) / 3
1.5 in
45 deg
```

### Functions and constants

| Name | Does |
|---|---|
| `sin` `cos` `tan` | trigonometry. Give an angle: `sin(30 deg)` |
| `asin` `acos` `atan` | inverse trigonometry; the result is an angle |
| `sqrt` | square root |
| `abs` | absolute value |
| `min` `max` | the smaller or larger of two or more values |
| `round` `floor` `ceil` | round to a whole number |
| `pi`, `e` | the constants |

## Autocomplete

Start typing a parameter's name in any field and SimplMaker offers matches. Press [[Tab]] or [[Return]] to accept one.

## Parameters can use parameters

`pocket = width / 4` is fine. SimplMaker works out the order itself. If two parameters refer to each other it shows **circular reference** on both.

## Errors

If an expression can't be worked out, the field shows why, for example *cannot add values with different units* or *unknown parameter 'wdith'*. Fix it and the model rebuilds.

## Changing a parameter to a number, and back

Dragging a handle in the viewport sets the value to a plain number. If that value came from a parameter, SimplMaker asks before replacing it, so you don't break the link by accident.
