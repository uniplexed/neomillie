# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fills the run directory of sim/cue: one directory per case under Assets/ngcd/common/, as the card has
them, from tools/make_test_disc.py, the CUE variants as text, a disc from tools/cd_convert.py, and the
hand-written golden TOCs in golden/."""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
BENCH = pathlib.Path(__file__).resolve().parent
run = pathlib.Path(sys.argv[1])
common = run / "Assets" / "ngcd" / "common"
SECTOR = 2352


def make(case, *opts):
    d = common / case
    if d.exists():
        shutil.rmtree(d)
    subprocess.run([sys.executable, str(ROOT / "tools/make_test_disc.py"), str(d), *opts], check=True)
    return d


def cue(lines, eol="\n", final=True):
    return eol.join(lines) + (eol if final else "")


def write_cue(path, text):
    """As written, on any OS: text mode would turn each LF into CR LF on Windows and hide the LF cases."""
    path.write_bytes(text.encode())


REFERENCE = ['FILE "disc.bin" BINARY',
             "  TRACK 01 MODE1/2352", "    INDEX 01 00:00:00",
             "  TRACK 02 AUDIO", "    INDEX 00 00:00:32", "    INDEX 01 00:00:34",
             "  TRACK 03 AUDIO", "    INDEX 00 00:00:44", "    INDEX 01 00:00:46"]

make("raw")
make("single")
make("crlf 'X', 1", "--crlf", "--spaces")
make("iso", "--iso2048")
make("missing", "--missing-bin")
make("probe", "--data-sectors", "300")

# Its last line ends with the file, right after the INDEX
d = make("pregap")
write_cue(d / "pregap.cue", cue(['FILE "gapless.bin" BINARY',
                                   "  TRACK 01 MODE1/2352", "    INDEX 01 00:00:00",
                                   "  TRACK 02 AUDIO", "    PREGAP 00:00:02", "    INDEX 01 00:00:32",
                                   "  TRACK 03 AUDIO", "    PREGAP 00:00:02", "    INDEX 01 00:00:42"], final=False))

# Lines the parser must skip: other keywords, junk, an index it does not use, a malformed INDEX 01 and
# PREGAP, a blank line, a tab, trailing spaces and no newline at the end
d = make("malformed")
write_cue(d / "malformed.cue", cue([
    "REM GENRE Test", "CATALOG 0000000000000", 'PERFORMER "Nobody"', 'TITLE "Malformed, but readable"',
    'FILE "disc.bin" BINARY',
    "  TRACK 01 MODE1/2352", "    FLAGS DCP", "    INDEX 01 00:00:00", "\tthis line is junk !!! 12:34:56",
    "  TRACK 02 AUDIO", '    TITLE "Two"', "    INDEX 00 00:00:32", "    INDEX 01 00:00:34",
    "    INDEX 01 bogus", "    INDEX 02 00:00:40", "    PREGAP", "    POSTGAP 00:00:00", "",
    "  TRACK 03 AUDIO", "    ISRC ABCDE1234567", "    INDEX 00 00:00:44", "    INDEX 01 00:00:46   "], final=False))

d = make("mode1_2048")
write_cue(d / "m2048.cue", cue([REFERENCE[0], "  TRACK 01 MODE1/2048"] + REFERENCE[2:]))

d = make("two_files")
write_cue(d / "two.cue", cue(['FILE "disc.bin" BINARY', "  TRACK 01 MODE1/2352", "    INDEX 01 00:00:00",
                                'FILE "gapless.bin" BINARY', "  TRACK 02 AUDIO", "    INDEX 01 00:00:00"]))

# 9,408 bytes, the most the bank holds, with track 3 in the last piece; and one byte more
d = make("long")
head, tail = REFERENCE[:6], REFERENCE[6:]
body = cue(head) + cue(tail)
pad = 9408 - len(body)
rem = []
while pad > 0:
    n = min(pad, 80)
    rem.append("REM " + "x" * (n - 5) if n >= 5 else " " * (n - 1))
    pad -= n
fits = cue(head) + cue(rem) + cue(tail)
assert len(fits) == 9408, len(fits)
write_cue(d / "fits.cue", fits)
write_cue(d / "long.cue", fits.replace("REM x", "REM xx", 1))
assert len((d / "long.cue").read_bytes()) == 9409

# tools/cd_convert.py output, from a 2,048-byte data track and two audio BINs, one behind PREGAP 00:02:00
# and one with INDEX 00 at its start
src = make("conv_src", "--iso2048")
disc = (src / "disc.bin").read_bytes()
(src / "a2.bin").write_bytes(disc[34 * SECTOR:44 * SECTOR])
(src / "a3.bin").write_bytes(disc[44 * SECTOR:56 * SECTOR])
write_cue(src / "src.cue", cue(['FILE "disc.iso" BINARY', "  TRACK 01 MODE1/2048", "    INDEX 01 00:00:00",
                                  'FILE "a2.bin" BINARY', "  TRACK 02 AUDIO", "    PREGAP 00:02:00", "    INDEX 01 00:00:00",
                                  'FILE "a3.bin" BINARY', "  TRACK 03 AUDIO", "    INDEX 00 00:00:00", "    INDEX 01 00:00:02"]))
subprocess.run([sys.executable, str(ROOT / "tools/cd_convert.py"), str(src / "src.cue"), str(common / "conv"),
                "--name", "conv"], check=True, stdout=subprocess.DEVNULL)

(run / "golden").mkdir(exist_ok=True)
for g in (BENCH / "golden").glob("*.toc"):
    shutil.copy(g, run / "golden" / g.name)
