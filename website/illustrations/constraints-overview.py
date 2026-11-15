#!/usr/bin/env python3
"""Draws the "Constraints at a glance" illustration for the docs (docs/sketch/constraints).

    python3 website/illustrations/constraints-overview.py

writes website/illustrations/constraints-overview.svg. website/illustrations/render.sh turns it into the PNG the docs use
(website/src/static/docs/img/constraints-overview.png). The colours and symbols are the app's own: dark blue sketch,
white shapes, orange for what you select, and the badge glyphs SimplMaker draws next to the geometry.
"""
import math
import pathlib

OUT = pathlib.Path(__file__).with_name("constraints-overview.svg")

BG, CARD, CARD_LINE = "#16233f", "#1d2f55", "#2b4273"
WHITE, SOFT, DIM, ORANGE = "#ffffff", "#c9d3ee", "#8191b8", "#ff9f5a"
BADGE_BG, BADGE_LINE = "#2a2a2e", "#5a5b63"
FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"

W, MARGIN, GAP = 1600, 40, 24
CARD_W, CARD_H = 360, 300
TOP = 168
PANEL = 150          # drawing area of one panel, in px square


def pt(x, y, color=SOFT, r=5.5):
    return f'<rect x="{x - r:.1f}" y="{y - r:.1f}" width="{2 * r}" height="{2 * r}" rx="1.5" fill="{color}"/>'


def hot(x, y):
    """A point the constraint acts on: orange square with a soft halo."""
    return (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="12" fill="{ORANGE}" fill-opacity="0.22"/>'
            + pt(x, y, ORANGE, 6))


def line(a, b, color=WHITE, w=3.5, dash=None, cap="round"):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke="{color}" '
            f'stroke-width="{w}" stroke-linecap="{cap}"{d}/>')


def circle(c, r, color=WHITE, w=3.5, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return f'<circle cx="{c[0]:.1f}" cy="{c[1]:.1f}" r="{r}" fill="none" stroke="{color}" stroke-width="{w}"{d}/>'


def badge(cx, cy, glyph, size=30):
    s = size
    return (f'<rect x="{cx - s / 2:.1f}" y="{cy - s / 2:.1f}" width="{s}" height="{s}" rx="7" fill="{BADGE_BG}" '
            f'stroke="{BADGE_LINE}" stroke-width="1.5"/>'
            f'<text x="{cx:.1f}" y="{cy + s * 0.33:.1f}" text-anchor="middle" font-family="{FONT}" '
            f'font-weight="700" font-size="{s * 0.62:.0f}" fill="{WHITE}">{glyph}</text>')


def text(x, y, s, size=16, color=SOFT, weight=400, anchor="start", spacing=0):
    sp = f' letter-spacing="{spacing}"' if spacing else ""
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{color}" text-anchor="{anchor}"{sp}>{s}</text>')


def arrow(a, b, color=ORANGE, w=2.5, both=False, head=8):
    """A line from a to b with a hand-drawn head (SVG markers are not drawn by every renderer)."""
    d = unit((b[0] - a[0], b[1] - a[1]))
    n = (-d[1], d[0])
    def tip(p, s):
        return (f'<polyline points="{p[0] - s * d[0] * head + n[0] * head * 0.6:.1f},{p[1] - s * d[1] * head + n[1] * head * 0.6:.1f} '
                f'{p[0]:.1f},{p[1]:.1f} {p[0] - s * d[0] * head - n[0] * head * 0.6:.1f},{p[1] - s * d[1] * head - n[1] * head * 0.6:.1f}" '
                f'fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>')
    return line(a, b, color, w) + tip(b, 1) + (tip(a, -1) if both else "")


def add(a, b): return (a[0] + b[0], a[1] + b[1])
def mul(a, k): return (a[0] * k, a[1] * k)
def unit(a): n = math.hypot(*a); return (a[0] / n, a[1] / n)


def tick(p, d, color=ORANGE, n=1, gap=7, half=9):
    """Little cross-strokes on a line at p (d = the line's direction): one for 'equal' marks, two for the pair."""
    nx, ny = -d[1], d[0]
    out = []
    for i in range(n):
        o = (i - (n - 1) / 2) * gap
        c = (p[0] + d[0] * o, p[1] + d[1] * o)
        out.append(line((c[0] - nx * half, c[1] - ny * half), (c[0] + nx * half, c[1] + ny * half), color, 3))
    return "".join(out)


# --- one diagram per constraint: (before, after), each drawn in a PANEL × PANEL box ---------------------------------

def coincident():
    before = (line((14, 112), (66, 62), SOFT, 3) + line((88, 52), (138, 100), SOFT, 3)
              + hot(66, 62) + hot(88, 52))
    after = (line((14, 112), (76, 58), WHITE) + line((76, 58), (138, 100), WHITE)
             + f'<circle cx="76" cy="58" r="13" fill="{ORANGE}" fill-opacity="0.25"/>' + pt(76, 58, ORANGE, 7))
    return before, after


def on_curve():
    c = (70, 84)
    before = (circle(c, 46, SOFT, 3) + line((124, 34), (146, 10), SOFT, 3) + hot(124, 34))
    p = (c[0] + 46 * math.cos(math.radians(-42)), c[1] + 46 * math.sin(math.radians(-42)))
    after = (circle(c, 46) + line(p, (p[0] + 36, p[1] - 34), WHITE) + hot(*p))
    return before, after


def horizontal():
    before = line((14, 104), (136, 62), SOFT, 3) + hot(14, 104) + hot(136, 62)
    after = line((14, 84), (136, 84), WHITE) + pt(14, 84) + pt(136, 84)
    return before, after


def vertical():
    before = line((50, 14), (100, 136), SOFT, 3) + hot(50, 14) + hot(100, 136)
    after = line((75, 14), (75, 136), WHITE) + pt(75, 14) + pt(75, 136)
    return before, after


def parallel():
    before = (line((12, 62), (122, 30), SOFT, 3) + line((28, 128), (138, 116), SOFT, 3))
    d = unit((110, -32))
    a2 = (22, 130)
    after = (line((12, 62), (122, 30), WHITE) + line(a2, add(a2, mul(d, 114)), WHITE)
             + tick((67, 46), d, ORANGE, 2) + tick(add(a2, mul(d, 57)), d, ORANGE, 2))
    return before, after


def perpendicular():
    d1 = unit((90, -50)); d2 = (-d1[1] * -1, d1[0] * -1)  # perpendicular, pointing down-right
    d2 = unit((50, 90))
    # corner where the two lines cross
    cross = (76, 78)
    l1 = (add(cross, mul(d1, -64)), add(cross, mul(d1, 62)))
    l2 = (add(cross, mul(d2, -62)), add(cross, mul(d2, 58)))
    # right-angle marker in the wedge between +d1 and +d2
    m = 15
    s0 = add(cross, mul(d1, m)); s1 = add(s0, mul(d2, m)); s2 = add(cross, mul(d2, m))
    mark = (f'<polyline points="{s0[0]:.1f},{s0[1]:.1f} {s1[0]:.1f},{s1[1]:.1f} {s2[0]:.1f},{s2[1]:.1f}" fill="none" '
            f'stroke="{ORANGE}" stroke-width="3" stroke-linejoin="round"/>')
    before = (line((20, 112), (128, 62), SOFT, 3) + line((40, 24), (118, 124), SOFT, 3))
    after = line(*l1, WHITE) + line(*l2, WHITE) + mark
    return before, after


def tangent():
    c = (58, 90); r = 42
    n = (math.cos(math.radians(50)), -math.sin(math.radians(50)))   # from the centre toward the touch point
    t = (-n[1], n[0])
    touch = add(c, mul(n, r))
    a, b = add(touch, mul(t, -62)), add(touch, mul(t, 58))
    off = mul(n, -24)    # the line pushed into the circle, so it cuts through
    before = circle(c, r, SOFT, 3) + line(add(a, off), add(b, off), SOFT, 3)
    after = circle(c, r) + line(a, b) + hot(*touch)
    return before, after


def equal():
    d1 = (108, 0)
    l1 = ((14, 42), (14 + d1[0], 42))
    short = unit((66, 44)); long_ = unit((66, 44))
    s0 = (26, 98)
    before = (line(*l1, SOFT, 3) + line(s0, add(s0, mul(short, 78)), SOFT, 3))
    after = (line(*l1, WHITE) + line(s0, add(s0, mul(long_, 108)), WHITE)
             + tick((14 + 54, 42), (1, 0), ORANGE, 1) + tick(add(s0, mul(long_, 54)), long_, ORANGE, 1))
    return before, after


def midpoint():
    a, b = (12, 108), (138, 78)
    m = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    before = line(a, b, SOFT, 3) + line((104, 56), (104, 14), SOFT, 3) + hot(104, 56)
    d = unit((b[0] - a[0], b[1] - a[1]))
    after = (line(a, b, WHITE) + line(m, (m[0], m[1] - 62), WHITE) + hot(*m)
             + tick(((a[0] + m[0]) / 2, (a[1] + m[1]) / 2), d, ORANGE, 1, half=8)
             + tick(((b[0] + m[0]) / 2, (b[1] + m[1]) / 2), d, ORANGE, 1, half=8))
    return before, after


def concentric():
    before = circle((66, 74), 52, SOFT, 3) + circle((90, 94), 22, SOFT, 3) + hot(66, 74) + hot(90, 94)
    after = circle((75, 80), 52) + circle((75, 80), 24) + hot(75, 80)
    return before, after


def symmetric():
    axis = line((75, 6), (75, 144), ORANGE, 2.5, dash="7 6", cap="butt")
    before = (axis + line((75, 28), (28, 96), SOFT, 3) + line((75, 28), (126, 122), SOFT, 3)
              + hot(28, 96) + hot(126, 122))
    after = (axis + line((75, 28), (28, 112), WHITE) + line((75, 28), (122, 112), WHITE)
             + hot(28, 112) + hot(122, 112)
             + arrow((52, 132), (98, 132), both=True))
    return before, after


def fix():
    p = (32, 112)
    before = (line(p, (122, 66), SOFT, 3) + pt(*p, SOFT) + pt(122, 66, SOFT)
              + f'<path d="M 24 98 Q 8 82 20 62" stroke="{ORANGE}" stroke-width="2.5" fill="none" stroke-linecap="round"/>'
              + f'<polyline points="12,69 20,62 28,70" fill="none" stroke="{ORANGE}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>')
    cross = (f'<circle cx="{p[0]}" cy="{p[1]}" r="12" fill="none" stroke="{ORANGE}" stroke-width="3"/>'
             f'<line x1="{p[0] - 19}" y1="{p[1]}" x2="{p[0] + 19}" y2="{p[1]}" stroke="{ORANGE}" stroke-width="3"/>'
             f'<line x1="{p[0]}" y1="{p[1] - 19}" x2="{p[0]}" y2="{p[1] + 19}" stroke="{ORANGE}" stroke-width="3"/>')
    after = (line((122, 66), (112, 20), DIM, 2.5, dash="5 6") + pt(122, 66, DIM, 4.5)
             + line(p, (112, 20), WHITE) + pt(112, 20) + cross + pt(*p, ORANGE, 5.5))
    return before, after


CARDS = [
    ("Coincident", "●", "two points, or a point and a curve", coincident, "point"),
    ("Point on curve", "⊙", "a point and a line, circle or arc", on_curve, None),
    ("Horizontal", "H", "one or more lines", horizontal, None),
    ("Vertical", "V", "one or more lines", vertical, None),
    ("Parallel", "∥", "two lines", parallel, None),
    ("Perpendicular", "⊥", "two lines", perpendicular, None),
    ("Tangent", "T", "line and circle, or two circles", tangent, None),
    ("Equal", "=", "two lines, or two circles", equal, None),
    ("Midpoint", "M", "a point, then a line", midpoint, None),
    ("Concentric", "◎", "two circles or arcs", concentric, "ring"),
    ("Symmetric", "⇆", "two points, then the mirror line", symmetric, None),
    ("Fix", "⌖", "one or more points", fix, None),
]


def title_badge(x, y, glyph, kind):
    if kind == "point":     # Coincident has no badge in the app: the shared point is the symbol
        return (f'<rect x="{x - 15}" y="{y - 15}" width="30" height="30" rx="7" fill="{BADGE_BG}" stroke="{BADGE_LINE}" stroke-width="1.5"/>'
                f'<rect x="{x - 6}" y="{y - 6}" width="12" height="12" rx="2" fill="{ORANGE}"/>')
    if kind == "ring":      # Concentric is two circles sharing a centre
        return (f'<rect x="{x - 15}" y="{y - 15}" width="30" height="30" rx="7" fill="{BADGE_BG}" stroke="{BADGE_LINE}" stroke-width="1.5"/>'
                f'<circle cx="{x}" cy="{y}" r="9" fill="none" stroke="{WHITE}" stroke-width="2"/>'
                f'<circle cx="{x}" cy="{y}" r="4" fill="none" stroke="{WHITE}" stroke-width="2"/>')
    return badge(x, y, glyph)


def card(i, name, glyph, select, make, kind):
    col, row = i % 4, i // 4
    x = MARGIN + col * (CARD_W + GAP)
    y = TOP + row * (CARD_H + GAP)
    before, after = make()
    pad = (CARD_W - 2 * PANEL) / 3.0 - 6        # space between panels
    bx = x + 22
    ax = x + CARD_W - 22 - PANEL
    py = y + 108
    out = [f'<rect x="{x}" y="{y}" width="{CARD_W}" height="{CARD_H}" rx="18" fill="{CARD}" stroke="{CARD_LINE}" stroke-width="1.5"/>',
           title_badge(x + 38, y + 40, glyph, kind),
           text(x + 66, y + 48, name, 26, WHITE, 700),
           text(x + 24, y + 82, "Select: " + select, 16, DIM),
           f'<g transform="translate({bx + PANEL * 0.05} {py + PANEL * 0.05}) scale(0.9)">{before}</g>',
           f'<g transform="translate({ax + PANEL * 0.05} {py + PANEL * 0.05}) scale(0.9)">{after}</g>',
           # arrow between the panels
           f'<path d="M {x + CARD_W / 2 - 13} {py + PANEL / 2} L {x + CARD_W / 2 + 9} {py + PANEL / 2}" stroke="{DIM}" stroke-width="3" '
           f'stroke-linecap="round" fill="none"/>'
           f'<path d="M {x + CARD_W / 2 + 3} {py + PANEL / 2 - 8} L {x + CARD_W / 2 + 12} {py + PANEL / 2} L {x + CARD_W / 2 + 3} {py + PANEL / 2 + 8}" '
           f'stroke="{DIM}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>',
           text(bx + PANEL / 2, y + CARD_H - 16, "BEFORE", 12, DIM, 600, "middle", 1.5),
           text(ax + PANEL / 2, y + CARD_H - 16, "AFTER", 12, SOFT, 600, "middle", 1.5)]
    return "".join(out)


def steps(y):
    x0 = MARGIN
    w = W - 2 * MARGIN
    parts = [f'<rect x="{x0}" y="{y}" width="{w}" height="96" rx="18" fill="{CARD}" stroke="{CARD_LINE}" stroke-width="1.5"/>']
    items = [("1", "Select", "the items with the Select tool (S). Shift-click adds more."),
             ("2", "Constrain", "press Constrain in the toolbar and pick one. Only the ones that fit are enabled."),
             ("3", "Drag to test", "grab any point. The rule holds, and the rest of the sketch follows.")]
    cw = w / 3
    for k, (n, head, body) in enumerate(items):
        cx = x0 + 30 + k * cw
        parts.append(f'<circle cx="{cx + 16}" cy="{y + 48}" r="17" fill="{ORANGE}"/>'
                     + text(cx + 16, y + 55, n, 20, BG, 800, "middle"))
        parts.append(text(cx + 46, y + 42, head, 20, WHITE, 700))
        # wrap body at ~46 characters
        words, lines_, cur = body.split(), [], ""
        for wd in words:
            if len(cur) + len(wd) + 1 > 46:
                lines_.append(cur); cur = wd
            else:
                cur = (cur + " " + wd).strip()
        lines_.append(cur)
        for j, ln in enumerate(lines_):
            parts.append(text(cx + 46, y + 64 + j * 20, ln, 15, SOFT))
    return "".join(parts)


def main():
    rows = 3
    cards_bottom = TOP + rows * CARD_H + (rows - 1) * GAP
    steps_y = cards_bottom + 28
    H = steps_y + 96 + 40
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">',
           '<title>Constraints at a glance</title>',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           text(MARGIN, 82, "Constraints at a glance", 46, WHITE, 800),
           text(MARGIN, 124, "A constraint is a rule between shapes. Once it is set, it holds however you change the sketch.", 21, SOFT)]
    # legend, top right
    lx = W - MARGIN - 440
    svg += [pt(lx + 8, 66, SOFT, 6), text(lx + 24, 72, "shape", 15, DIM),
            hot(lx + 112, 66), text(lx + 130, 72, "what the rule acts on", 15, DIM),
            badge(lx + 330, 66, "H", 24), text(lx + 350, 72, "its symbol", 15, DIM)]
    for i, c in enumerate(CARDS):
        svg.append(card(i, *c))
    svg.append(steps(steps_y))
    svg.append("</svg>")
    OUT.write_text("\n".join(svg))
    print(f"{OUT} ({W} x {H})")


main()
