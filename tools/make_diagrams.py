# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""docs/architecture.md's diagrams of each core's parts: docs/img/parts-cart.svg and docs/img/parts-cd.svg.

    python tools/make_diagrams.py
"""
import html
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
W, GAP, M = 980, 14, 14          # width, gap between boxes, margin
STYLE = """svg{font-family:system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif}
.bg{fill:#fbfaf7}.t{font-size:14px;font-weight:600;fill:#24231f}.s{font-size:12px;fill:#62605a}
.band{font-size:11.5px;font-weight:700;letter-spacing:.09em;fill:#62605a}
.box{stroke:#c9c6bc;stroke-width:1}.a{stroke:#85837c;stroke-width:1.4;fill:none}.ah{fill:#85837c}
.host{fill:#ececea}.cd{fill:#e3ecf8}.con{fill:#e3f1e5}.out{fill:#f7ead9}.mem{fill:#eee6f4}
@media (prefers-color-scheme:dark){
.bg{fill:#1c1b19}.t{fill:#ecebe6}.s,.band{fill:#a3a19a}.box{stroke:#4a4944}.a{stroke:#8f8d86}.ah{fill:#8f8d86}
.host{fill:#2c2c2a}.cd{fill:#22303f}.con{fill:#22362a}.out{fill:#3c3020}.mem{fill:#33283a}
}"""


class Diagram:
    def __init__(self, title, desc):
        self.title, self.desc, self.parts, self.y = title, desc, [], 12
        self.pos = {}

    def row(self, band, boxes, h=92):
        """boxes: (key, class, title, lines). They share the width."""
        self.parts.append(f'<text class="band" x="{M}" y="{self.y + 12}">{html.escape(band)}</text>')
        y = self.y + 22
        w = (W - 2 * M - GAP * (len(boxes) - 1)) / len(boxes)
        for i, (key, cls, title, lines) in enumerate(boxes):
            x = M + i * (w + GAP)
            self.pos[key] = (x, y, w, h)
            self.parts.append(f'<rect class="box {cls}" x="{x:.0f}" y="{y}" width="{w:.0f}" height="{h}" rx="8"/>'
                              f'<text class="t" x="{x + 13:.0f}" y="{y + 24}">{html.escape(title)}</text>'
                              + "".join(f'<text class="s" x="{x + 13:.0f}" y="{y + 43 + 16 * n}">{html.escape(l)}</text>'
                                        for n, l in enumerate(lines)))
        self.y = y + h + 26

    def right(self, a, b):
        """From a's right edge to b's left edge, a and b side by side in one row."""
        ax, ay, aw, ah = self.pos[a]; bx, by, _, bh = self.pos[b]
        self.arrow(f"M{ax + aw:.0f} {ay + ah / 2:.0f} L{bx - 2:.0f} {by + bh / 2:.0f}")

    def left(self, a, b):
        """From a's left edge to b's right edge, b to the left of a in one row."""
        ax, ay, _, ah = self.pos[a]; bx, by, bw, bh = self.pos[b]
        self.arrow(f"M{ax:.0f} {ay + ah / 2:.0f} L{bx + bw + 2:.0f} {by + bh / 2:.0f}")

    def down(self, a, b, x=None, x2=None, dy=10, label=None, side="right"):
        """From a's bottom to b's top, a row or more below. x: where it leaves a (its middle unless given); x2:
        where it enters b (straight below x unless given). A bend runs dy below a. The label sits beside the
        stretch that enters b, on the side asked."""
        ax, ay, aw, ah = self.pos[a]; bx, by, bw, _ = self.pos[b]
        x1 = ax + aw / 2 if x is None else x
        x2 = x1 if x2 is None else x2
        y1, y2, mid = ay + ah, by - 2, ay + ah + dy
        bent = abs(x1 - x2) >= 1
        self.arrow(f"M{x1:.0f} {y1} L{x1:.0f} {mid} L{x2:.0f} {mid} L{x2:.0f} {y2}" if bent
                   else f"M{x1:.0f} {y1} L{x2:.0f} {y2}")
        if label:
            ly = (mid + y2) / 2 + 4 if bent else y1 + 20
            lx, anchor = (x2 + 7, "start") if side == "right" else (x2 - 7, "end")
            self.parts.append(f'<text class="s" x="{lx:.0f}" y="{ly:.0f}" text-anchor="{anchor}">'
                              f'{html.escape(label)}</text>')

    def centre(self, key):
        x, _, w, _ = self.pos[key]
        return x + w / 2

    def arrow(self, d):
        self.parts.append(f'<path class="a" marker-end="url(#ah)" d="{d}"/>')

    def svg(self):
        h = self.y
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="{W}" role="img">\n'
                f'<title>{html.escape(self.title)}</title>\n<desc>{html.escape(self.desc)}</desc>\n<style>\n{STYLE}\n</style>\n'
                '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
                '<path class="ah" d="M0 0 L10 5 L0 10 z"/></marker></defs>\n'
                f'<rect class="bg" width="{W}" height="{h}"/>\n' + "\n".join(self.parts) + "\n</svg>\n")


def pocket_row(d, card_lines, loader_lines):
    d.row("THE POCKET", [
        ("sd", "host", "SD card", card_lines),
        ("os", "host", "Pocket system", ["reads files, shows the menu,", "writes saves on Quit"]),
        ("ld", "host", "Loader and settings", loader_lines),
    ], h=78)
    d.right("sd", "os"); d.right("os", "ld")


def memory_rows(d, chips, users):
    d.row("MEMORY", [("arb", "mem", "Memory arbiter",
                      ["gives each chip to one user at a time, in a fixed order of priority, so that the picture never waits"])], h=56)
    d.row("", chips, h=92)
    for key in users:                    # straight down from each user, and to each chip
        d.down(key, "arb")
    for key, *_ in chips:
        d.down("arb", key, x=d.centre(key))


def cd():
    d = Diagram("The parts of NeoMillieCD", "The Pocket's side, the rebuilt CD drive, the console and the memory chips of the CD core, and what passes between them.")
    pocket_row(d, ["BIOS, disc (CUE and BIN),", "memory card file"], ["takes the BIOS, and each", "menu item as a register"])
    # Right to left, as the RTL does it: the mount gives the drive its tracks, the drive asks for sectors, the
    # fetch (or with Turbo its ring) reads them from the Pocket and hands them to the decoder and the sound
    d.row("THE CD DRIVE, REBUILT", [
        ("dec", "cd", "Decoder", ["offers each data sector to", "the 68K, which copies it", "into memory"]),
        ("fetch", "cd", "Sector fetch", ["reads sectors five ahead of", "the drive; with CD Turbo 4x,", "256 in a ring in SDRAM"]),
        ("drive", "cd", "Drive model", ["seeks, plays and answers the", "BIOS; 1x or 2x by CD/CDZ,", "up to 4x by Turbo"]),
        ("mount", "cd", "Disc mount", ["reads the CUE: the tracks,", "data or audio, and where", "each one starts"]),
    ])
    d.down("os", "fetch", x=d.centre("fetch"), label="sectors")
    d.down("os", "mount", x=d.pos["os"][0] + d.pos["os"][2] - 30, x2=d.centre("mount"), label="the CUE")
    d.left("mount", "drive"); d.left("drive", "fetch"); d.left("fetch", "dec")
    d.row("THE CONSOLE", [
        ("cpu", "con", "68K processor", ["runs the BIOS and the game,", "reads the buttons; 12, 16", "or 24 MHz by 68K Clock"]),
        ("vid", "con", "Video chip", ["draws the sprites and the", "text layer, line by line"]),
        ("pic", "out", "Picture out", ["304 or 320 wide, PAL,", "position, and the scaler's", "aspect ratio"]),
        ("snd", "con", "Sound", ["Z80 processor and YM2610:", "FM and samples, plus the", "disc's music"]),
        ("aud", "out", "Sound out", ["Stereo Mix, Mute and", "ADPCM-A Channel act", "here"]),
    ])
    d.down("dec", "cpu", x=d.centre("cpu"), label="program, graphics and samples")
    d.down("fetch", "snd", x2=d.centre("snd"), dy=14, label="music")
    d.right("vid", "pic"); d.right("snd", "aud")
    memory_rows(d, [
        ("c0", "mem", "PSRAM 1, 16 MB", ["the BIOS and the", "game's program"]),
        ("c1", "mem", "PSRAM 2, 16 MB", ["sound samples"]),
        ("sd2", "mem", "SDRAM, 64 MB", ["sprites, and the", "Turbo ring"]),
        ("sr", "mem", "SRAM, 256 KB", ["the text layer"]),
        ("fp", "mem", "Inside the FPGA", ["the Z80's program,", "colours, the memory", "card"]),
    ], ["cpu", "vid", "snd"])
    return d.svg()


def cart():
    d = Diagram("The parts of NeoMillie", "The Pocket's side, the console with its cartridge and the memory chips of the cartridge core, and what passes between them.")
    pocket_row(d, ["BIOS, a folder of ROM files", "per game, save files"], ["the game's entry says which", "file goes to which chip"])
    d.row("THE CONSOLE AND ITS CARTRIDGE", [
        ("cpu", "con", "68K processor", ["runs the BIOS and", "the game, reads the", "buttons; 12, 16 or", "24 MHz by 68K Clock"]),
        ("chips", "con", "Cartridge chips", ["bank switching and", "protection (SMA, PVC,", "CMC), as a game needs"]),
        ("vid", "con", "Video chip", ["draws the sprites", "and the text layer,", "line by line"]),
        ("pic", "out", "Picture out", ["304 or 320 wide,", "PAL, position and", "aspect ratio"]),
        ("snd", "con", "Sound", ["Z80 and YM2610: FM,", "two kinds of samples,", "square waves"]),
        ("aud", "out", "Sound out", ["Stereo Mix, Mute", "and ADPCM-A", "Channel act here"]),
    ], h=108)
    d.right("cpu", "chips"); d.right("vid", "pic"); d.right("snd", "aud")
    memory_rows(d, [
        ("c0", "mem", "PSRAM 1, 16 MB", ["the BIOS, the game's", "program, MVS backup RAM"]),
        ("c1", "mem", "PSRAM 2, 16 MB", ["sound samples"]),
        ("sd2", "mem", "SDRAM, 64 MB", ["sprites"]),
        ("sr", "mem", "SRAM, 256 KB", ["the text layer and the", "Z80's program, copied", "here after a load"]),
        ("fp", "mem", "Inside the FPGA", ["the 68K's work RAM,", "colours, the memory", "card, two read caches"]),
    ], ["cpu", "vid", "snd"])
    # The ROMs go to the memory chips, down the gap between Sound and Sound out, which is under the loader
    gap = (d.pos["snd"][0] + d.pos["snd"][2] + d.pos["aud"][0]) / 2
    d.down("ld", "arb", x=gap, label="the ROMs, before the game starts", side="left")
    return d.svg()


def main():
    out = ROOT / "docs" / "img"
    out.mkdir(parents=True, exist_ok=True)
    for name, svg in (("parts-cd.svg", cd()), ("parts-cart.svg", cart())):
        (out / name).write_text(svg, encoding="utf-8")
        print(out / name, len(svg), "bytes")


if __name__ == "__main__":
    main()
