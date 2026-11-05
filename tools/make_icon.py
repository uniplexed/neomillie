# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The cores' icon: Millie, a dog, from her photo; the CD core's has a disc in the corner. python tools/make_icon.py --selftest

icon_bytes(cd) is the file icon.bin of a core folder, in Analogue's format (packaging-a-core, "Graphical Asset
Formats"): 36 x 36 pixels of 16 bits, brightness in the upper 8 bits (fully on is 0xFF00), stored rotated 90
degrees counter-clockwise. The brightness byte comes first in the file, as in Analogue's template icon.
The art is drawn here as text, one character a pixel, so no image library is needed; make_logo.py colours the
same marks for the project's logo.
"""
import sys

SIZE = 36
# Brightness of each mark of the art: "." is off and the outside, "#" her cream fur, "+" and "-" her tan ears
# and their darker strands, "o" an eye with "*" its glint, "n" her nose and mouth, "h" the harness, "t" her tongue
LEVEL = {".": 0, "#": 255, "+": 135, "-": 80, "o": 0, "*": 255, "n": 0, "h": 30, "t": 110}

CART = [
    "....................................",
    "....................................",
    "..............#..##..#..............",
    ".............#.######.#.............",
    ".......++....##########....++.......",
    ".....+++++.##############.+++++.....",
    "....++++++################++++++....",
    "....+++++##################+++++....",
    "...++++++##################++++++...",
    "...+++-+####################++-++...",
    "...+++-+####################++-++...",
    "...+++-+###oooo######oooo###++-++...",
    "...+++++###o*oo######o*oo###+++++...",
    "...++-+####oooo######oooo####++-+...",
    "...++-++###oooo######oooo###+++-+...",
    "...++-++###oooo######oooo###+++-+...",
    "...+++++#########nn#########+++++...",
    "..+++-+#########nnnn#########++-++..",
    ".++++-+#########nnnn#########++-+++.",
    ".++++-+##########nn##########++-+++.",
    ".++++++#######n##nn##n#######++++++.",
    "..++-++########n####n########+++-+..",
    "...+-++#########nnnn#########+++-...",
    ".....+...########tt########...+.....",
    ".................tt.................",
    "............############............",
    "..........hh############hh..........",
    "........###hh##########hh###........",
    ".......#####hh########hh#####.......",
    "......#######hh######hh#######......",
    "......########hh####hh########......",
    "......#########hh##hh#########......",
    "......########hhhhhhhh########......",
    "......########hhhhhhhh########......",
    "......########hhhhhhhh########......",
    ".......##########hh##########.......",
]

# The CD core's disc, a SIZE-21 patch with its top left at (DISC_X, DISC_Y); "/" keeps the cartridge's pixel.
DISC_X = DISC_Y = 21
DISC = [
    "///////.../////",
    "///////###..///",
    "////##+/+/##.//",
    "///#++//+//+///",
    "//#+++--/-/++#/",
    "//#++/////-++#/",
    "/#++-//##//-++#",
    "/#++#+/..#+-++#",
    "/#++-+#../+-++#",
    "./++-++##++-++#",
    "/./++-++++-++#/",
    "/./+++----+++#/",
    "//.#++++++++#//",
    "///.##++++##///",
    "/////.///#/////",
]


def pixels(cd):
    """Rows of brightness values, top to bottom, not yet rotated."""
    rows = [[LEVEL[c] for c in r] for r in CART]
    if cd:
        for j, r in enumerate(DISC):
            for i, c in enumerate(r):
                if c != "/":
                    rows[DISC_Y + j][DISC_X + i] = LEVEL[c]
    return rows


def icon_bytes(cd):
    """The 2,592 bytes of icon.bin; cd=True is the CD core's icon."""
    rows = pixels(cd)
    out = bytearray()
    for y in range(SIZE):               # rotated 90 degrees counter-clockwise: new (x, y) is old (SIZE-1-y, x)
        for x in range(SIZE):
            out += bytes((rows[x][SIZE - 1 - y], 0))
    return bytes(out)


def selfcheck():
    assert len(CART) == SIZE and all(len(r) == SIZE for r in CART)
    assert len(DISC) == SIZE - DISC_Y and all(len(r) == SIZE - DISC_X for r in DISC)
    cart, cd = icon_bytes(False), icon_bytes(True)
    assert len(cart) == len(cd) == SIZE * SIZE * 2 == 2592
    assert cart != cd
    assert set("".join(CART)) <= set(LEVEL) and set("".join(DISC)) <= set("/+-#.")
    # her left eye's glint is on at (12, 12); rotated counter-clockwise it is at x = 12, y = SIZE-1-12
    assert CART[12][12] == "*" and CART[13][13] == "o"
    at = ((SIZE - 1 - 12) * SIZE + 12) * 2
    assert cart[at:at + 2] == bytes((255, 0)) and cart[((SIZE - 1 - 13) * SIZE + 13) * 2] == 0
    # the first rotated row is the last column of the art, all off
    assert cart[:SIZE * 2] == bytes(SIZE * 2)


def main(argv):
    if argv != ["--selftest"]:
        sys.exit("usage: make_icon.py --selftest")
    selfcheck()
    print("make_icon: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
