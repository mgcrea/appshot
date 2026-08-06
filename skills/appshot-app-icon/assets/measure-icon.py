#!/usr/bin/env python3
"""Measure app icons so "it looks small" becomes a number you can compare.

    python3 measure-icon.py rendered_*.png
    python3 measure-icon.py App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png

Reports, per image:

  plate      the opaque region — the visible icon inside its canvas
  glyph      the artwork drawn *on* the plate, as a % of plate width/height
  corners    whether the plate is square (opaque corners) or rounded

Run it on the output of render-icon.swift to compare against peers, and on the source PNG to
check what you actually authored. Requires Pillow (`pip install pillow`).

Two measurement notes, because both have produced wrong conclusions before:

* The plate has an anti-aliased rim and often a specular gradient, so "differs from the plate
  colour" hits the edge pixels. We ignore a 10% border ring. That clamps the reported glyph
  width at 80% — a row reading 80.0% means "fills the window or more", not exactly 80%.
* Plate colour is taken as the dominant colour inside that ring, which assumes a solid or
  gently graded plate. For busy artwork the glyph figure is meaningless; trust the plate figure
  and judge the rest by eye.
"""

import sys
from collections import Counter

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  pip install pillow")

RING = 0.10          # fraction of plate width ignored at each edge
ALPHA_OPAQUE = 250   # alpha at/above this counts as plate
BUCKET = 24          # colour quantisation when finding the plate colour
DIFF = 2             # quantised distance from plate colour that counts as glyph


def measure(path):
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()

    solid = im.getchannel("A").point(lambda v: 255 if v >= ALPHA_OPAQUE else 0)
    box = solid.getbbox()
    if box is None:
        return None
    x0, y0, x1, y1 = box
    pw, ph = x1 - x0, y1 - y0

    inset = int(pw * RING)
    rx0, ry0, rx1, ry1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
    if rx1 <= rx0 or ry1 <= ry0:
        return dict(size=(w, h), plate=(pw, ph), glyph=None, square=None)

    counts = Counter()
    for y in range(ry0, ry1, 2):
        for x in range(rx0, rx1, 2):
            r, g, b, a = px[x, y]
            if a >= ALPHA_OPAQUE:
                counts[(r // BUCKET, g // BUCKET, b // BUCKET)] += 1
    if not counts:
        return dict(size=(w, h), plate=(pw, ph), glyph=None, square=None)
    plate = counts.most_common(1)[0][0]

    gx0, gy0, gx1, gy1 = w, h, -1, -1
    for y in range(ry0, ry1):
        for x in range(rx0, rx1):
            r, g, b, a = px[x, y]
            if a < ALPHA_OPAQUE:
                continue
            if abs(r // BUCKET - plate[0]) + abs(g // BUCKET - plate[1]) + abs(b // BUCKET - plate[2]) > DIFF:
                gx0, gy0 = min(gx0, x), min(gy0, y)
                gx1, gy1 = max(gx1, x), max(gy1, y)

    glyph = None if gx1 < 0 else (gx1 - gx0 + 1, gy1 - gy0 + 1)
    corner_alpha = px[x0, y0][3]
    return dict(size=(w, h), plate=(pw, ph), glyph=glyph, square=corner_alpha >= ALPHA_OPAQUE)


def main(paths):
    if not paths:
        sys.exit(__doc__)
    print(f"{'file':28s} {'canvas':>11s} {'plate':>11s} {'plate/canvas':>13s} "
          f"{'glyph w':>8s} {'glyph h':>8s}  corners")
    for p in paths:
        try:
            m = measure(p)
        except Exception as exc:                      # unreadable / not an image
            print(f"{p[-28:]:28s}  error: {exc}")
            continue
        if m is None:
            print(f"{p[-28:]:28s}  fully transparent")
            continue
        w, h = m["size"]
        pw, ph = m["plate"]
        gw = f"{100 * m['glyph'][0] / pw:.1f}%" if m["glyph"] else "—"
        gh = f"{100 * m['glyph'][1] / ph:.1f}%" if m["glyph"] else "—"
        corners = "square" if m["square"] else "rounded"
        print(f"{p[-28:]:28s} {w:5d}x{h:<5d} {pw:5d}x{ph:<5d} {100 * pw / w:12.1f}% "
              f"{gw:>8s} {gh:>8s}  {corners}")
    print("\nglyph figures clamp at 80% (a 10% ring is ignored); target band is 70-80% of plate width.")


if __name__ == "__main__":
    main(sys.argv[1:])
