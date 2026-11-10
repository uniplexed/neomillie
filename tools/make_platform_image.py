# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The Platform images: python tools/make_platform_image.py --selftest | --png

image_bytes(platform) is the file Platforms/_images/ng.bin or ngcd.bin, in Analogue's format as icon.bin
(tools/make_icon.py): 521 x 165 pixels of 16 bits, brightness byte first, then 0, stored rotated 90 degrees
counter-clockwise; 0 is the menu, 255 full ink. Isometric pixel art drawn here, on a grid of 2 x 2 pixels: Millie
sits next to a cartridge for ng and a disc for ngcd. Each object is a small voxel model, seen along (1, 1, 1).
--png writes build/platform_images.png, decoded back from those bytes, to see them.
"""
from functools import lru_cache
import math
import pathlib
import struct
import sys
import zlib

WIDTH, HEIGHT = 521, 165
GRID_W, GRID_H = WIDTH // 2, HEIGHT // 2
PALETTE = [0, 40, 80, 120, 160, 200, 235, 255]
FACE_INK = {"top": 0, "left": 34, "right": 74}      # the light comes from the upper left
PAPER = -34                                         # stays white on the shaded front
GLYPHS = {
    "N": ["##...##", "###..##", "####.##", "##.####", "##..###", "##...##", "##...##"],
    "E": ["#######", "##.....", "##.....", "######.", "##.....", "##.....", "#######"],
    "O": [".#####.", "##...##", "##...##", "##...##", "##...##", "##...##", ".#####."],
    "G": [".#####.", "##...##", "##.....", "##.####", "##...##", "##...##", ".#####."],
}
# The left half of Millie, sitting, front on; the art is mirrored. "K" line, "F" and "f" fur, "E" and "e" ears, "W" an eye's
# glint, "T" and "t" her tongue, "H" the harness, "Y" its buckle
MILLIE = [
    "..................",
    "...........KKKKKKK",
    ".........KKFFFFFFF",
    ".....KKKKFFFFFFFFF",
    "...KKEEEKFFFFFFFFF",
    "..KEEEEEKFFFFFFFFF",
    ".KEEEEEKFFFFFFFFFF",
    ".KEEEeEKFFFFFFFFFF",
    "KEEEEeEfFFFFFFFFFF",
    "KEEEeEEfFFFFFFFFFF",
    "KEEEeEEfFFKKKKFFFF",
    "KEEeEEffFKKKKKKFFF",
    "KEEeEEfFFKWWKKKFFF",
    "KEEeEEfFFKWWKKKFFF",
    "KEEeEEfFFKKKKKKFFF",
    "KEeEEEfFFFKKKKFFFF",
    "KEeEEEffFFFFFFFFFF",
    "KEeEEEEfFFFFFFFKKK",
    "KEEeEEEfFFFFFFFKKK",
    ".KEeEEEfFFFFFFFFKK",
    ".KEeEEKfFFFFFFFFFK",
    ".KEEEEKfFFFFKFFFFK",
    "..KEEKKfFFFFFKKFFK",
    "...KK..KfFFFFFFKKK",
    "........KffFFFFKTT",
    ".........KKfFFFKTT",
    "...........KKFFKTt",
    ".........KKKfFFFKK",
    ".......KKFFFFFFFFF",
    "......KFFfFFFFFFFF",
    ".....KFFHHfFFFFFFF",
    ".....KFFfHHFFFFFFF",
    ".....KFFFfHHFFFFFF",
    ".....KFFFFfHHFFFFF",
    "......KFFFFfHHHHHH",
    "......KFFFFFHHYYHH",
    "....KKKfFFFFFFFFFF",
    "...KFFFKFFFFFFFFFF",
    "..KFFFfKFFFFFFFFFK",
    "..KFFFfKFFFFFFFFFK",
    "..KFFFfKFFFFFFFFFK",
    "..KFFffKFFFFFFFFFK",
    "...KKKKKFFKFFKFFKK",
    "......KKKKKKKKKKKK",
]
MILLIE_INK = {"K": 255, "W": 0, "F": 0, "f": 40, "E": 120, "e": 160, "T": 120, "t": 200, "H": 200, "Y": 40}
MILLIE_W = 36
EYE_TO_EYE = 12         # columns from the left eye's glint to the right eye's
OVERLAP = 6             # columns of Millie in front of the object


def word(text):
    """The (column, row) cells of a word at twice the glyphs' size, and its width."""
    cells, x = set(), 0
    for c in text:
        cells |= {(x + i * 2 + a, j * 2 + b) for j, r in enumerate(GLYPHS[c]) for i, m in enumerate(r) if m == "#"
                  for a in range(2) for b in range(2)}
        x += 16
    return cells, x - 2


NEO, WORD_W = word("NEO")
GEO = word("GEO")[0]


def aes_cart(x, y, z):
    """A home-console cartridge standing up, its label on the front. The model's answer is (ink, part) or None."""
    W, T, H = CART_SIZE
    if y == T - 1:
        lx, lz = x - 5, H - 6 - z
        if 0 <= lx < W - 10 and 0 <= lz < 35:
            cx, cz = lx - (W - 10 - WORD_W) // 2, lz - 2
            return (255 if (cx, cz) in NEO or (cx, cz - 17) in GEO else PAPER), "label"
        if z >= H - 4 and x % 3 == 1:
            return 245, "grip"
    if x == W - 1 and z % 4 == 1:
        return 250, "rib"
    if z == H - 1 and y % 2:
        return 240, "top"
    return 170, "shell"


CART_SIZE = (62, 12, 45)


def disc_up(x, y, z):
    """A disc standing on its edge, with its grooves and two wedges of light."""
    radius, hole = DISC_SIZE[0] // 2, 4
    dx, dz = x + .5 - radius, z + .5 - radius
    d = math.hypot(dx, dz)
    if d > radius or d < hole:
        return None
    if y < DISC_SIZE[1] - 1:
        return 235, "edge"
    if d < hole + 1 or d > radius - 1:
        return 235, "rim"
    if d < hole + 5:
        return 150 + PAPER, "hub"
    wedge = (math.atan2(dz, dx) + .6) % math.pi
    if wedge < .30:
        return PAPER, "disc"
    if wedge < .50:
        return 40 + PAPER, "disc"
    return (120 if int(d) % 5 == 0 else 70) + PAPER, "disc"


DISC_SIZE = (52, 3, 52)


def trace(model, size, sx, sy):
    """The first voxel on a pixel's ray, as (ink, part, face), or None. A ray is x = t + sx/2, y = t - sx/2, z = t - sy."""
    X, Y, Z = size
    t = min(X - sx / 2, Y + sx / 2, Z + sy) + .5
    low = max(-sx / 2, sx / 2, sy) - .5
    prev = (math.floor(t + sx / 2), math.floor(t - sx / 2), math.floor(t - sy))
    while t > low:
        t -= .2
        pos = (t + sx / 2, t - sx / 2, t - sy)
        cell = tuple(math.floor(p) for p in pos)
        if cell == prev:
            continue
        hit = model(*cell) if all(0 <= c < s for c, s in zip(cell, size)) else None
        if hit:
            # the axis that crossed its boundary first is the face the ray came through; ties go to the front
            axis = max((n for n in (1, 0, 2) if cell[n] != prev[n]), key=lambda n: round(cell[n] + 1 - pos[n], 6))
            return hit[0], hit[1], ("right", "left", "top")[axis]
        prev = cell
    return None


def in_shadow(model, size, sx, sy):
    """Whether the floor under this pixel is shaded by the model."""
    x, y = sy + sx / 2, sy - sx / 2
    for z in range(size[2]):
        cell = (math.floor(x - (z + 1) * .6), math.floor(y + (z + 1) * .6), z)
        if all(0 <= c < s for c, s in zip(cell, size)) and model(*cell):
            return True
    return False


def render(model, size):
    """Rows of ink on the grid, the model centred, with its outline and dithered shadow."""
    X, Y, Z = size
    ox, oy = (GRID_W - (X - Y)) // 2, (GRID_H - ((X + Y) / 2 + Z)) / 2 + Z
    ink = [[0] * GRID_W for _ in range(GRID_H)]
    ids = [[None] * GRID_W for _ in range(GRID_H)]
    for j in range(GRID_H):
        for i in range(GRID_W):
            sx, sy = i - ox + .5, j - oy + .5
            hit = trace(model, size, sx, sy)
            if hit:
                tone, part, face = hit
                v = 255 if tone >= 250 else min(255, tone + FACE_INK[face])
                ink[j][i] = min(PALETTE, key=lambda p: abs(p - v))
                ids[j][i] = (part, face)
            elif (i + j) % 2 == 0 and in_shadow(model, size, sx, sy):
                ink[j][i] = 80
    for j in range(GRID_H):
        for i in range(GRID_W):
            around = [ids[j + b][i + a] for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1))
                      if 0 <= i + a < GRID_W and 0 <= j + b < GRID_H]
            if ids[j][i] is None:
                if any(around):
                    ink[j][i] = 255
            elif any(n is not None and n != ids[j][i] for n in around[:1] + around[2:3]):
                ink[j][i] = max(ink[j][i], 235)
    return ink


def scene(model, size):
    """Millie and the object side by side, the pair centred."""
    art = render(model, size)
    lit = [x for r in art for x, v in enumerate(r) if v]
    left, right = min(lit), max(lit)
    x0 = (GRID_W - (MILLIE_W - OVERLAP + right - left + 1)) // 2
    dx = x0 + MILLIE_W - OVERLAP - left
    art = [([0] * dx + r[:GRID_W - dx]) if dx >= 0 else r[-dx:] + [0] * -dx for r in art]
    y0 = GRID_H - len(MILLIE) - 2
    for y in (GRID_H - 2, GRID_H - 1):      # her shadow
        for x in range(x0 + 4, x0 + MILLIE_W):
            if (x + y) % 2 == 0:
                art[y][x] = 80
    for j, half in enumerate(MILLIE):
        for i, c in enumerate(half + half[::-1]):
            if c != ".":
                art[y0 + j][x0 + i] = MILLIE_INK["K" if c == "W" and i >= MILLIE_W // 2 else c]
        for i, c in enumerate(half):
            if c == "W":
                art[y0 + j][x0 + i + EYE_TO_EYE] = 0
    return art


@lru_cache(maxsize=None)
def pixels(platform):
    """Rows of brightness values, top to bottom, not yet rotated."""
    art = scene(*{"ng": (aes_cart, CART_SIZE), "ngcd": (disc_up, DISC_SIZE)}[platform])
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for j, r in enumerate(art):
        for i, v in enumerate(r):
            for y in (j * 2, j * 2 + 1):
                rows[y][i * 2:i * 2 + 2] = [v, v]
    return tuple(tuple(r) for r in rows)


def image_bytes(platform):
    """The 171,930 bytes of the image file."""
    rows = pixels(platform)
    out = bytearray()
    for y in range(WIDTH):              # rotated 90 degrees counter-clockwise: file row y, column x is art row x
        for x in range(HEIGHT):         # and art column WIDTH-1-y
            out += bytes((rows[x][WIDTH - 1 - y], 0))
    return bytes(out)


def decode(data):
    """Upright rows of an image file."""
    return [[data[((WIDTH - 1 - x) * HEIGHT + y) * 2] for x in range(WIDTH)] for y in range(HEIGHT)]


def png(rows):
    """Grey PNG of rows of brightness values."""
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    head = struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 0, 0, 0, 0)
    body = zlib.compress(b"".join(b"\0" + bytes(r) for r in rows))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", body) + chunk(b"IEND", b"")


def selfcheck():
    assert all(len(r) == 18 and set(r) <= set(MILLIE_INK) | {"."} for r in MILLIE)
    ng, cd = image_bytes("ng"), image_bytes("ngcd")
    assert len(ng) == len(cd) == WIDTH * HEIGHT * 2 == 171930
    assert ng != cd and set(ng[1::2]) == set(cd[1::2]) == {0}
    for p, data in (("ng", ng), ("ngcd", cd)):
        rows = decode(data)
        assert [tuple(r) for r in rows] == list(pixels(p))                          # the rotation undoes
        assert set(data[0::2]) <= set(PALETTE) and len(set(data[0::2])) > 4, p
        lit = [x for r in rows for x, v in enumerate(r) if v]
        assert min(lit) >= 40 and WIDTH - 1 - max(lit) >= 40, p                     # it fits, with a margin
    assert ng[:HEIGHT * 2] == bytes(HEIGHT * 2)                                     # the art's last column is off
    assert png([[0, 255]]).startswith(b"\x89PNG")


def main(argv):
    if argv == ["--selftest"]:
        selfcheck()
        print("make_platform_image: ok")
    elif argv == ["--png"]:
        rows = decode(image_bytes("ng")) + [[128] * WIDTH] + decode(image_bytes("ngcd"))
        out = pathlib.Path(__file__).resolve().parent.parent / "build" / "platform_images.png"
        out.write_bytes(png(rows))
        print(out)
    else:
        sys.exit("usage: make_platform_image.py --selftest | --png")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
