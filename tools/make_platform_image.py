# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The Platform images: python tools/make_platform_image.py --selftest | --png

image_bytes(platform) is the file Platforms/_images/ng.bin or ngcd.bin, in Analogue's format as icon.bin
(tools/make_icon.py): 521 x 165 pixels of 16 bits, brightness byte first, then 0, stored rotated 90 degrees
counter-clockwise. ng is text, in a font drawn here as the icon is. ngcd is a Neo Geo CDZ, or the top loader, in shaded pixel art,
drawn here from its shapes, with no logo. --png writes build/platform_images.png, decoded back from those bytes, to see them.
"""
import math
import pathlib
import struct
import sys
import zlib

WIDTH, HEIGHT = 521, 165
TEXT = {"ng": "NEO GEO"}
MODEL = "top"           # the console the ngcd image shows: "top" or "cdz"
SCALE = 8               # pixels a font pixel
SPACE = 3               # font columns of a space
FONT = {
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
}
GLYPH_W, GLYPH_H = 5, 7


class Iso:
    """A drawing at half size on a black canvas: a box of A by B by TALL art pixels, x from its back to its
    front, y from its right side to its left, lit from the upper left. Isometric from the front left corner,
    or, with a yaw in degrees, from the front right, the way product photos are taken. iso(x, y, z) is the
    canvas point of a box coordinate; side says which side face shows."""
    TOP, SIDE, FRONT, EDGE, DARK = 200, 120, 80, 255, 25
    RISE_PER_DEPTH = 0.55               # how much a step back climbs the canvas, in the yawed view
    SCALE = 1.45                        # the yawed view is drawn this much larger, to fill the image

    def __init__(self, A, B, TALL, yaw=None, shades=None):
        self.w, self.h = WIDTH // 2, HEIGHT // 2
        self.art = [[0] * self.w for _ in range(self.h)]
        self.A, self.B, self.TALL = A, B, TALL
        self.yaw = yaw
        self.side = "left" if yaw is None else "right"
        if shades:
            self.TOP, self.SIDE, self.FRONT, self.EDGE, self.DARK = shades
        if yaw is None:
            self.cx, self.cy = self.w // 2 + (B - A) // 2, (self.h - (A + B) // 2 - TALL) // 2 + TALL
        else:
            t, e, k = math.radians(yaw), self.RISE_PER_DEPTH, self.SCALE
            self.cx = self.w / 2 + k * (B * math.cos(t) - A * math.sin(t)) / 2
            self.cy = self.h / 2 + k * (B * e * math.sin(t) + A * e * math.cos(t) + TALL) / 2

    def iso(self, x, y, z=None):
        z = self.TALL if z is None else z
        if self.yaw is None:
            return self.cx + x - y, self.cy + (x + y) / 2 - z
        t, e, d, k = math.radians(self.yaw), self.RISE_PER_DEPTH, self.A - x, self.SCALE
        return self.cx + k * (d * math.sin(t) - y * math.cos(t)), self.cy - k * (y * e * math.sin(t) + d * e * math.cos(t) + z)

    @property
    def near(self):
        """The y of the side face that shows."""
        return self.B if self.side == "left" else 0

    def fill(self, points, value):
        art, w, h = self.art, self.w, self.h
        ys = [p[1] for p in points]
        for y in range(max(0, int(min(ys))), min(h, int(max(ys)) + 1)):
            cross = sorted(p[0] + (y + 0.5 - p[1]) * (q[0] - p[0]) / (q[1] - p[1])
                           for p, q in zip(points, points[1:] + points[:1])
                           if (p[1] <= y + 0.5) != (q[1] <= y + 0.5))
            for a, b in zip(cross[::2], cross[1::2]):
                for x in range(max(0, round(a)), min(w, round(b))):
                    art[y][x] = value

    def line(self, p, q, value):
        n = max(1, round(max(abs(q[0] - p[0]), abs(q[1] - p[1]))))
        for i in range(n + 1):
            x, y = round(p[0] + (q[0] - p[0]) * i / n), round(p[1] + (q[1] - p[1]) * i / n)
            if 0 <= x < self.w and 0 <= y < self.h:
                self.art[y][x] = value

    def outline(self, points, value):
        for p, q in zip(points, points[1:] + points[:1]):
            self.line(p, q, value)

    def rect(self, x0, y0, x1, y1, z=None):     # level, on the top
        return [self.iso(x0, y0, z), self.iso(x1, y0, z), self.iso(x1, y1, z), self.iso(x0, y1, z)]

    def on_front(self, y0, y1, z0, z1):         # on the front, x = A
        A = self.A
        return [self.iso(A, y0, z0), self.iso(A, y1, z0), self.iso(A, y1, z1), self.iso(A, y0, z1)]

    def box(self):
        """The three faces and their edges: the back and far edges of the top lit, the bottom ones dark."""
        A, B, TALL, iso, n = self.A, self.B, self.TALL, self.iso, self.near
        far = B - n
        self.fill([iso(0, n), iso(A, n), iso(A, n, 0), iso(0, n, 0)], self.SIDE)
        self.fill([iso(A, 0), iso(A, B), iso(A, B, 0), iso(A, 0, 0)], self.FRONT)
        self.fill(self.rect(0, 0, A, B), self.TOP)
        self.line(iso(0, far), iso(A, far), self.EDGE)
        self.line(iso(0, 0), iso(0, B), self.EDGE)
        self.line(iso(A, 0), iso(A, B), self.TOP + 30)
        self.line(iso(A, 0, 0), iso(A, B, 0), self.DARK)
        self.line(iso(0, n, 0), iso(A, n, 0), self.DARK)
        self.line(iso(A, n, 0), iso(A, n), self.DARK)

    def ribs(self, xs):
        """Grooves cut into the side that shows, at these depths, carrying on over the top's edge."""
        n, TALL, iso = self.near, self.TALL, self.iso
        for x in xs:
            self.fill([iso(x, n, TALL), iso(x + 3, n, TALL), iso(x + 3, n, 2), iso(x, n, 2)], self.SIDE - 60)
            self.line(iso(x + 3, n, TALL), iso(x + 3, n, 2), self.SIDE + 40)
            self.fill(self.rect(x, min(n, n - 3), x + 3, max(n, n + 3)) if False else
                      self.rect(x, n - 3 if n else 0, x + 3, n if n else 3), self.TOP - 70)

    def ports(self, spans):
        """Controller ports on the front, each a (y0, y1)."""
        for y0, y1 in spans:
            self.fill(self.on_front(y0, y1, 4, 7), self.DARK)
            self.line(self.iso(self.A, y0, 7), self.iso(self.A, y1, 7), self.FRONT + 60)

    def rows(self):
        """The canvas as rows of WIDTH x HEIGHT, each art pixel 2 x 2."""
        w, h = self.w, self.h
        return [[v for v in r for _ in (0, 1)] + [0] * (WIDTH - 2 * w) for r in self.art for _ in (0, 1)] + [[0] * WIDTH] * (HEIGHT - 2 * h)


def console_top():
    """The top-loading Neo Geo CD: a hump across the top the big lid sits in, the groove before it, vents
    behind, ribs over the back half of the side."""
    c = Iso(62, 68, 10, yaw=22, shades=(140, 70, 100, 235, 15))
    A, B, TALL = c.A, c.B, c.TALL
    TOP, SIDE, FRONT, EDGE, DARK = c.TOP, c.SIDE, c.FRONT, c.EDGE, c.DARK
    iso, fill, line, rect, art = c.iso, c.fill, c.line, c.rect, c.art
    L = A - 20                          # the lid's front edge
    near = c.side == "left"             # which side of a raised shape shows
    c.box()
    c.ribs(range(3, A // 2, 7))         # the ribs run over the back half of the side only
    c.ports(((9, 17), (B - 17, B - 9)))
    # The vents at the back, on the low level behind the hump: a recessed plate with three slots
    fill(rect(3, 14, 12, B - 14), TOP - 40)
    line(iso(3, 14), iso(3, B - 14), DARK)
    line(iso(3, 14), iso(12, 14), DARK)
    for x in (5, 8, 11):
        fill(rect(x, 16, x + 1, B - 16), DARK)

    # The hump the lid sits in: a broad rounded rise across the top, from behind the lid to near the front,
    # its sides shaded in steps so they read as curved, as the shoulders beside the real lid do
    HX0, HY0, HX1, HY1 = 14, 6, A - 4, B - 6
    INSET = (0, 0.2, 0.8, 1.8, 3.4)
    HUMP = len(INSET)
    LEFT_SHADE = (SIDE - 15, SIDE, SIDE + 25, SIDE + 55, TOP - 20)
    FRONT_SHADE = (FRONT - 15, FRONT, FRONT + 20, FRONT + 45, TOP - 50)
    for k, d in enumerate(INSET):
        x0, y0, x1, y1 = HX0 + d, HY0 + d, HX1 - d, HY1 - d
        z = TALL + k
        ys = y1 if near else y0
        fill([iso(x0, ys, z), iso(x1, ys, z), iso(x1, ys, z + 1), iso(x0, ys, z + 1)], LEFT_SHADE[k])
        fill([iso(x1, y0, z), iso(x1, y1, z), iso(x1, y1, z + 1), iso(x1, y0, z + 1)], FRONT_SHADE[k])
    d = INSET[-1]
    TOPZ = TALL + HUMP
    fill(rect(HX0 + d, HY0 + d, HX1 - d, HY1 - d, TOPZ), TOP + 8)
    yf = HY0 + d if near else HY1 - d
    line(iso(HX0 + d, yf, TOPZ), iso(HX1 - d, yf, TOPZ), EDGE)
    line(iso(HX0 + d, HY0 + d, TOPZ), iso(HX0 + d, HY1 - d, TOPZ), EDGE)

    # The lid: a raised block on the hump, its front rounded and bevelled; before it the dark groove one reaches
    # under to lift it, with its lip. Its two visible sides are in shade, its bevel in half light, its top lit.
    RISE, BEVEL = 4, 1.5
    Y0, Y1 = 13, B - 13                 # the lid spans the hump but for its shoulders
    bow = lambda n, out, z: iso(L + (6 + out) * math.sin(math.pi * n / 24), Y0 - out + n * (Y1 - Y0 + 2 * out) / 24, z)
    arc_top = [bow(n, -BEVEL, TOPZ + RISE) for n in range(25)]
    arc_mid = [bow(n, 0, TOPZ + RISE - BEVEL) for n in range(25)]
    arc_low = [bow(n, 0, TOPZ) for n in range(25)]
    hollow = [bow(n, 6, TOPZ) for n in range(25)]
    lip = [bow(n, 9, TOPZ) for n in range(25)]
    fill(arc_low + hollow[::-1], DARK)
    for p, q in zip(lip, lip[1:]):
        line(p, q, TOP - 90)
        line((p[0] + 1, p[1] + 1), (q[0] + 1, q[1] + 1), TOP + 25)
    YN, YF = (Y1, Y0) if near else (Y0, Y1)
    fill([iso(16, YN, TOPZ), iso(L, YN, TOPZ), iso(L, YN, TOPZ + RISE), iso(16, YN, TOPZ + RISE)], SIDE - 20)
    fill(arc_low + arc_mid[::-1], FRONT - 20)
    fill(arc_mid + arc_top[::-1], FRONT + 40)
    fill([iso(16, Y0, TOPZ + RISE)] + arc_top + [iso(16, Y1, TOPZ + RISE)], TOP + 15)
    fill(rect(18, Y0 + 2, L - 4, Y1 - 2, TOPZ + RISE), TOP + 30)
    far_end, near_end = (arc_top[0], arc_top[-1]) if near else (arc_top[-1], arc_top[0])
    line(iso(16, Y0, TOPZ + RISE), iso(16, Y1, TOPZ + RISE), EDGE)
    line(iso(16, YF, TOPZ + RISE), far_end, EDGE)
    yf = Y0 + 2 if near else Y1 - 2
    line(iso(18, yf, TOPZ + RISE), iso(L - 4, yf, TOPZ + RISE), EDGE)
    line(iso(18, Y0 + 2, TOPZ + RISE), iso(18, Y1 - 2, TOPZ + RISE), EDGE)
    for p, q in zip(arc_top, arc_top[1:]):
        line(p, q, EDGE)
    line(iso(16, YN, TOPZ + RISE), near_end, DARK)
    line(arc_low[-1 if near else 0], arc_mid[-1 if near else 0], DARK)
    line(iso(16, YN, TOPZ), iso(16, YN, TOPZ + RISE), DARK)
    for y in (B // 2 - 3, B // 2, B // 2 + 3):          # the three air holes before the lid's mark
        x, yy = iso(L - 12, y, TOPZ + RISE)
        art[round(yy)][round(x)] = TOP - 80
    fill(rect(L - 9, Y0 + 8, L - 6, Y0 + 12, TOPZ + RISE), TOP - 60)

    # The power button at the front left, a lit disc with a shadowed rim
    button = [iso(A - 9 + 4 * math.cos(i * math.pi / 12), B - 13 + 4 * math.sin(i * math.pi / 12), TOPZ) for i in range(24)]
    fill(button, TOP + 40)
    c.outline(button, DARK)
    line(iso(A - 11, B - 15, TOPZ), iso(A - 8, B - 16, TOPZ), EDGE)

    return c.rows()




def console_cdz():
    """The Neo Geo CDZ: a low box with a big round lid, flat at its front, two triangular buttons at the front
    corners, vent slots at the back corners and beside the lid, ribs over the front half of the side, and the
    two ports at the right of the front."""
    c = Iso(60, 70, 8)
    A, B, TALL = c.A, c.B, c.TALL
    TOP, SIDE, FRONT, EDGE, DARK = c.TOP, c.SIDE, c.FRONT, c.EDGE, c.DARK
    iso, fill, line, rect = c.iso, c.fill, c.line, c.rect
    c.box()
    c.ribs(range(A // 2 + 2, A - 6, 5))
    c.ports(((6, 13), (16, 23)))

    def slots(x0, y0, n, along_x):      # a vent: n short dark slots, each with a lit edge
        for i in range(n):
            if along_x:
                p, q = iso(x0, y0 + 3 * i), iso(x0 + 7, y0 + 3 * i)
            else:
                p, q = iso(x0 + 3 * i, y0), iso(x0 + 3 * i, y0 + 7)
            line(p, q, DARK)
            line((p[0] + 1, p[1]), (q[0] + 1, q[1]), TOP + 30)
    slots(4, 5, 4, True)                # back right
    slots(4, B - 15, 4, True)           # back left
    slots(A - 16, 4, 4, False)          # front right, beside the lid
    slots(A // 2 - 4, B - 10, 3, True)  # left, beside the lid

    # The lid: a disc raised in two rounded steps, cut flat at its front, with the small bar on that edge
    LX, LY, R = A / 2 - 2, B / 2, 25
    CUT = LX + 0.72 * R

    def disc(r, z, cut):
        pts = []
        for i in range(72):
            x, y = LX + r * math.cos(i * math.pi / 36), LY + r * math.sin(i * math.pi / 36)
            pts.append(iso(min(x, cut), y, z))
        return pts
    fill(disc(R, TALL, CUT), FRONT + 10)
    c.outline(disc(R, TALL, CUT), DARK)
    fill(disc(R - 0.8, TALL + 1, CUT - 0.6), SIDE + 60)
    fill(disc(R - 1.8, TALL + 2, CUT - 1.4), TOP + 20)
    rim = disc(R - 1.8, TALL + 2, CUT - 1.4)
    for i in range(36, 71):             # the lit rim at the back
        line(rim[i], rim[i + 1], EDGE)
    fill(rect(CUT - 2.2, LY - 2, CUT - 1.4, LY + 2, TALL + 2), TOP - 90)
    fill(rect(LX - 6, LY - 10, LX - 3, LY - 6, TALL + 2), TOP - 60)      # the disc mark
    for y in (LY - 3, LY, LY + 3):                                        # the three air holes
        x, yy = iso(LX + 8, y, TALL + 2)
        c.art[round(yy)][round(x)] = TOP - 80

    # The two triangular buttons at the front corners: power at the left, open at the right
    for tri in ([iso(A - 3, B - 3), iso(A - 14, B - 3), iso(A - 3, B - 14)],
                [iso(A - 3, 3), iso(A - 14, 3), iso(A - 3, 14)]):
        fill(tri, TOP + 45)
        c.outline(tri, DARK)
    return c.rows()


def pixels(platform):
    """Rows of brightness values, top to bottom, not yet rotated."""
    if platform == "ngcd":
        return console_cdz() if MODEL == "cdz" else console_top()
    lines = [""] * GLYPH_H
    for c in TEXT[platform]:
        for j in range(GLYPH_H):
            lines[j] += ("." * SPACE if c == " " else FONT[c][j]) + "."
    lines = [r[:-1] for r in lines]
    x0, y0 = (WIDTH - len(lines[0]) * SCALE) // 2, (HEIGHT - GLYPH_H * SCALE) // 2
    rows = [[0] * WIDTH for _ in range(HEIGHT)]
    for j, r in enumerate(lines):
        for i, c in enumerate(r):
            if c == "#":
                for y in range(y0 + j * SCALE, y0 + (j + 1) * SCALE):
                    rows[y][x0 + i * SCALE:x0 + (i + 1) * SCALE] = [255] * SCALE
    return rows


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
    assert all(len(g) == GLYPH_H and all(len(r) == GLYPH_W for r in g) for g in FONT.values())
    ng, cd = image_bytes("ng"), image_bytes("ngcd")
    assert len(ng) == len(cd) == WIDTH * HEIGHT * 2 == 171930
    assert ng != cd
    assert set(ng[1::2]) == set(cd[1::2]) == {0} and set(ng[0::2]) == {0, 255} and len(set(cd[0::2])) > 4
    for p, data in (("ng", ng), ("ngcd", cd)):
        assert decode(data) == pixels(p)                                            # the rotation undoes
    for p, data in (("ng", ng), ("ngcd", cd)):
        rows = decode(data)
        lit = [x for r in rows for x, v in enumerate(r) if v]
        lit_rows = [y for y, r in enumerate(rows) if any(r)]
        assert min(lit) >= 40 and abs(min(lit) - (WIDTH - 1 - max(lit))) <= 3, p    # it fits, with a margin, centred
        assert lit_rows[0] >= 1 and lit_rows[-1] <= HEIGHT - 2, p
    lit_rows = [y for y, r in enumerate(decode(ng)) if any(r)]
    assert lit_rows[0] == (HEIGHT - GLYPH_H * SCALE) // 2 and len(lit_rows) == GLYPH_H * SCALE
    # The N's top left, at art (x0, y0), lands at file row WIDTH-1-x0, column y0, and not where it was
    x0 = min(x for r in decode(ng) for x, v in enumerate(r) if v)
    y0 = (HEIGHT - GLYPH_H * SCALE) // 2
    assert ng[((WIDTH - 1 - x0) * HEIGHT + y0) * 2] == 255 and ng[(y0 * HEIGHT + x0) * 2] == 0
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
