# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The project's logo, from the core's icon: python tools/make_logo.py docs/neomillie.svg [--cd]

Millie's pixels from make_icon.py, in her colours, with a line drawn around her: outside the drawing stays
transparent, so the logo reads on a light or a dark page.
"""
import sys

from make_icon import CART, DISC, DISC_X, DISC_Y, SIZE

LINE, FACE, EAR, EAR_SHADE, EYE, GLINT = "#2b2320", "#fbf4e6", "#c9a578", "#a8855c", "#2b2320", "#ffffff"
NOSE, HARNESS, TONGUE = "#2b2320", "#3a3a44", "#e8818f"
DISC_FACE, DISC_RING, DISC_LINE = "#b9c4cf", "#8796a5", "#2b2320"
COLOUR = {"#": FACE, "+": EAR, "-": EAR_SHADE, "o": EYE, "*": GLINT, "n": NOSE, "h": HARNESS, "t": TONGUE,
          "d": DISC_FACE, "e": DISC_RING, "k": DISC_LINE, "g": GLINT}


def art(cd):
    rows = [list(r) for r in CART]
    if cd:
        for j, row in enumerate(DISC):
            for i, c in enumerate(row):
                if c != "/":
                    rows[DISC_Y + j][DISC_X + i] = {"+": "d", "-": "e", ".": "g", "#": "k"}[c]
    return rows


def outside(rows):
    """Off pixels the edge of the canvas can reach: everything else is inside the drawing."""
    seen, todo = set(), [(x, y) for x in range(SIZE) for y in (0, SIZE - 1)] + [(x, y) for y in range(SIZE) for x in (0, SIZE - 1)]
    while todo:
        x, y = todo.pop()
        if not (0 <= x < SIZE and 0 <= y < SIZE) or (x, y) in seen or rows[y][x] != ".":
            continue
        seen.add((x, y))
        todo += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return seen


def colour(rows, out, x, y):
    """The pixel's colour, or None for the transparent outside. The outside pixels that touch her get the
    line, so the logo reads on a light page as on a dark one."""
    c = rows[y][x]
    if (x, y) in out:
        near = [(x + a, y + b) for a in (-1, 0, 1) for b in (-1, 0, 1)]
        return LINE if any(0 <= i < SIZE and 0 <= j < SIZE and (i, j) not in out for i, j in near) else None
    return COLOUR.get(c, FACE)      # an off pixel inside her is fur too


def svg(cd):
    rows = art(cd)
    out = outside(rows)
    runs = []
    for y in range(SIZE):
        x = 0
        while x < SIZE:
            c = colour(rows, out, x, y)
            w = 1
            while x + w < SIZE and colour(rows, out, x + w, y) == c:
                w += 1
            if c:
                runs.append(f'<rect x="{x}" y="{y}" width="{w}" height="1" fill="{c}"/>')
            x += w
    title = "NeoMillieCD" if cd else "NeoMillie"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="288" height="288" '
            f'shape-rendering="crispEdges" role="img" aria-label="{title}"><title>{title}</title>' + "".join(runs) + "</svg>\n")


def main(argv):
    if not argv or argv[0].startswith("-"):
        sys.exit(__doc__)
    text = svg("--cd" in argv)
    assert text.count("<rect") > 100 and "None" not in text
    open(argv[0], "w", encoding="ascii", newline="\n").write(text)
    print(argv[0], len(text), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
