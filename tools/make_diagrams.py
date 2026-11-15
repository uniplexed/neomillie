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
        ax, ay, aw, ah = self.pos[a]; bx, by, _, bh = self.pos[b]
        self.parts.append(f'<path class="a" marker-end="url(#ah)" d="M{ax + aw:.0f} {ay + ah / 2:.0f} L{bx - 2:.0f} {by + bh / 2:.0f}"/>')

    def down(self, a, b, at=0.5, to=0.5, label=None):
        ax, ay, aw, ah = self.pos[a]; bx, by, bw, _ = self.pos[b]
        x1, x2, y1, y2 = ax + aw * at, bx + bw * to, ay + ah, by - 2
        mid = y1 + 9
        d = f"M{x1:.0f} {y1} L{x2:.0f} {y2}" if abs(x1 - x2) < 1 else f"M{x1:.0f} {y1} L{x1:.0f} {mid} L{x2:.0f} {mid} L{x2:.0f} {y2}"
        self.parts.append(f'<path class="a" marker-end="url(#ah)" d="{d}"/>')
        if label:
            self.parts.append(f'<text class="s" x="{min(x1, x2) + 8:.0f}" y="{mid - 3 if abs(x1 - x2) >= 1 else y1 + 15}">{html.escape(label)}</text>')

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
        ("pad", "host", "Buttons", ["read by the 68K; L/R Buttons", "sets what L and R press"]),
    ], h=78)
    d.right("sd", "os"); d.right("os", "ld")


def memory_rows(d, chips, users):
    d.row("MEMORY", [("arb", "mem", "Memory arbiter",
                      ["gives each chip to one user at a time, in a fixed order of priority, so that the picture never waits"])], h=56)
    d.row("", chips, h=92)
    for key, at in users:
        d.down(key, "arb", to=at)
    for i, (key, *_) in enumerate(chips):
        d.down("arb", key, at=(i + 0.5) / len(chips))


def cd():
    d = Diagram("The parts of NeoMillieCD", "The Pocket's side, the rebuilt CD drive, the console and the memory chips of the CD core, and what passes between them.")
    pocket_row(d, ["BIOS, disc (CUE and BIN),", "memory card file"], ["takes the BIOS, and each", "menu item as a register"])
    d.row("THE CD DRIVE, REBUILT", [
        ("mount", "cd", "Disc mount", ["reads the CUE: the tracks,", "data or audio, and where", "each one starts"]),
        ("fetch", "cd", "Sector fetch", ["asks the Pocket for sectors", "and keeps five read ahead", "of the drive"]),
        ("ring", "cd", "Turbo ring", ["with CD Turbo 4x: 256 sectors", "kept ready in SDRAM,", "filled 16 per read"]),
        ("drive", "cd", "Drive model", ["seeks, plays and answers", "the BIOS; 1x or 2x by", "CD/CDZ, 4x by Turbo"]),
        ("dec", "cd", "Decoder", ["offers each sector to the", "68K, which copies it into", "memory"]),
    ])
    d.down("os", "fetch", at=0.5, to=0.5)
    d.down("ld", "drive", at=0.5, to=0.5)
    for a, b in (("mount", "fetch"), ("fetch", "ring"), ("ring", "drive"), ("drive", "dec")):
        d.right(a, b)
    d.row("THE CONSOLE", [
        ("cpu", "con", "68K processor", ["runs the BIOS and the game;", "12, 16 or 24 MHz by", "68K Clock"]),
        ("vid", "con", "Video chip", ["draws the sprites and the", "text layer, line by line"]),
        ("pic", "out", "Picture out", ["304 or 320 wide, PAL,", "position, and the scaler's", "aspect ratio"]),
        ("snd", "con", "Sound", ["Z80 processor and YM2610:", "FM and samples, plus the", "disc's music"]),
        ("aud", "out", "Sound out", ["Stereo Mix, Mute and", "ADPCM-A Channel act", "here"]),
    ])
    d.down("dec", "cpu", at=0.5, to=0.8, label="program, graphics and samples from the disc")
    d.down("drive", "snd", at=0.5, to=0.5, label="music")
    d.right("vid", "pic"); d.right("snd", "aud")
    memory_rows(d, [
        ("c0", "mem", "PSRAM 1, 16 MB", ["the BIOS and the", "game's program"]),
        ("c1", "mem", "PSRAM 2, 16 MB", ["sound samples"]),
        ("sd2", "mem", "SDRAM, 64 MB", ["sprites, and the", "Turbo ring"]),
        ("sr", "mem", "SRAM, 256 KB", ["the text layer"]),
        ("fp", "mem", "Inside the FPGA", ["the Z80's program,", "colours, the memory", "card"]),
    ], [("cpu", 0.1), ("vid", 0.3), ("snd", 0.7)])
    return d.svg()


def cart():
    d = Diagram("The parts of NeoMillie", "The Pocket's side, the console with its cartridge and the memory chips of the cartridge core, and what passes between them.")
    pocket_row(d, ["BIOS, a folder of ROM files", "per game, save files"], ["the game's entry says which", "file goes to which chip"])
    d.row("THE CONSOLE AND ITS CARTRIDGE", [
        ("cpu", "con", "68K processor", ["runs the BIOS and", "the game; 12, 16 or", "24 MHz by 68K Clock"]),
        ("chips", "con", "Cartridge chips", ["bank switching and", "protection (SMA, PVC,", "CMC), as a game needs"]),
        ("vid", "con", "Video chip", ["draws the sprites", "and the text layer,", "line by line"]),
        ("pic", "out", "Picture out", ["304 or 320 wide,", "PAL, position and", "aspect ratio"]),
        ("snd", "con", "Sound", ["Z80 and YM2610: FM,", "two kinds of samples,", "square waves"]),
        ("aud", "out", "Sound out", ["Stereo Mix, Mute", "and ADPCM-A", "Channel act here"]),
    ])
    d.down("ld", "chips", at=0.5, to=0.5, label="the ROMs, copied to memory before the game starts")
    d.right("cpu", "chips"); d.right("vid", "pic"); d.right("snd", "aud")
    memory_rows(d, [
        ("c0", "mem", "PSRAM 1, 16 MB", ["the BIOS, the game's", "program, MVS backup RAM"]),
        ("c1", "mem", "PSRAM 2, 16 MB", ["sound samples"]),
        ("sd2", "mem", "SDRAM, 64 MB", ["sprites"]),
        ("sr", "mem", "SRAM, 256 KB", ["the text layer and the", "Z80's program, copied", "here after a load"]),
        ("fp", "mem", "Inside the FPGA", ["the 68K's work RAM,", "colours, the memory", "card, two read caches"]),
    ], [("cpu", 0.08), ("vid", 0.42), ("snd", 0.75)])
    return d.svg()


def main():
    out = ROOT / "docs" / "img"
    out.mkdir(parents=True, exist_ok=True)
    for name, svg in (("parts-cd.svg", cd()), ("parts-cart.svg", cart())):
        (out / name).write_text(svg, encoding="utf-8")
        print(out / name, len(svg), "bytes")


if __name__ == "__main__":
    main()
