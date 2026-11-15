# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The project's logo, from the core's icon: python tools/make_logo.py OUT.svg|OUT.png|OUT.ico|OUT.icns [--cd]

Millie's pixels from make_icon.py, in her colours, with a line drawn around her: outside the drawing stays
transparent, so the logo reads on a light or a dark page. An .svg is the logo; a .png (256 pixels), an .ico
(16, 32, 48 and 256 pixels) or an .icns (128, 256 and 512 pixels) is the disc converter's icon, its pixels
scaled by a whole number and centred, or sampled below 36 pixels. Every image is a PNG, which Windows and macOS
take inside an .ico and an .icns.
"""
import struct
import sys
import zlib

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


def pixels(cd):
    """Each pixel's colour, None where transparent."""
    rows = art(cd)
    out = outside(rows)
    return [[colour(rows, out, x, y) for x in range(SIZE)] for y in range(SIZE)]


def png(cd, size):
    """The art as a size x size RGBA PNG."""
    px = pixels(cd)
    scale = size // SIZE
    off = (size - SIZE * scale) // 2
    raw = bytearray()
    for y in range(size):
        raw.append(0)       # no filter
        for x in range(size):
            if scale:
                i, j = (x - off) // scale, (y - off) // scale
                c = px[j][i] if 0 <= i < SIZE and 0 <= j < SIZE else None
            else:
                c = px[y * SIZE // size][x * SIZE // size]
            raw += bytes.fromhex(c[1:]) + b"\xff" if c else bytes(4)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def ico(cd):
    """A Windows icon of PNG images."""
    images = [(n, png(cd, n)) for n in (16, 32, 48, 256)]
    at = 6 + 16 * len(images)
    entries = b""
    for n, data in images:
        entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(data), at)
        at += len(data)
    return struct.pack("<HHH", 0, 1, len(images)) + entries + b"".join(d for _, d in images)


def icns(cd):
    """A macOS icon of PNG images."""
    body = b"".join(kind + struct.pack(">I", 8 + len(d)) + d
                    for kind, d in ((b"ic07", png(cd, 128)), (b"ic08", png(cd, 256)), (b"ic09", png(cd, 512))))
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def main(argv):
    if not argv or argv[0].startswith("-"):
        sys.exit(__doc__)
    cd = "--cd" in argv
    kind = argv[0].lower().rsplit(".", 1)[-1]
    if kind in ("png", "ico", "icns"):
        data = {"png": lambda: png(cd, 256), "ico": lambda: ico(cd), "icns": lambda: icns(cd)}[kind]()
        open(argv[0], "wb").write(data)
        print(argv[0], len(data), "bytes")
        return 0
    text = svg(cd)
    assert text.count("<rect") > 100 and "None" not in text
    open(argv[0], "w", encoding="ascii", newline="\n").write(text)
    print(argv[0], len(text), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
