# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Generated test discs for the CD benches: python tools/make_test_disc.py OUTDIR [options]

Writes into OUTDIR:
  disc.bin     a data track of --data-sectors MODE1/2352 sectors (sync, the BCD MSF of lba + 150, mode 1,
               2,048 data bytes holding the sector number as 16-bit big-endian words, EDC and ECC as
               tools/cd_convert.py makes them), then two audio tracks of 10 sectors, each behind a pregap of 2
               sectors of silence in the BIN (INDEX 00); audio is a 1 kHz sine at -6 dB, 16-bit little-endian
               stereo, L = R
  gapless.bin  the same tracks without the pregap sectors, for a CUE with the PREGAP keyword
  disc.cue     the reference CUE of disc.bin: LF, INDEX 00 and 01
  README       a line per file

Options:
  --data-sectors N  the data track's length, 32 by default
  --iso2048         also disc.iso, the data track's user data alone, 2,048-byte sectors
  --missing-bin     disc.cue names missing.bin, which is not written
  --crlf            disc.cue ends its lines with CR LF
  --spaces          the BIN is "Test Disc 'X', 1.bin" and disc.cue names it so
  --salt N          the data words' high byte is XORed with N, so that two discs differ

Nothing here comes from a real disc. The golden TOCs of sim/cue are written by hand, not from this script.
"""
import math
import pathlib
import sys

sys.dont_write_bytecode = True     # no __pycache__ in tools/
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from cd_convert import SECTOR, USER, mode1_sector, msf_text  # noqa: E402

AUDIO_SECTORS = 10
GAP = 2
SPACED = "Test Disc 'X', 1.bin"


def user_data(lba, salt=0):
    """2,048 bytes: the sector number as 16-bit big-endian words."""
    return ((lba & 0xFFFF) ^ (salt << 8)).to_bytes(2, "big") * (USER // 2)


def sine_sectors(n, start_frame=0):
    """n sectors of a 1 kHz sine at -6 dB (amplitude 16384), 588 stereo frames each."""
    out = bytearray()
    for i in range(start_frame, start_frame + n * 588):
        v = round(16384 * math.sin(2 * math.pi * 1000 * i / 44100))
        out += v.to_bytes(2, "little", signed=True) * 2
    return bytes(out)


def build(data_sectors, gaps, salt=0):
    """The BIN's bytes and the INDEX positions (in BIN sectors) of each track."""
    b = bytearray()
    for lba in range(data_sectors):
        b += mode1_sector(lba, user_data(lba, salt))
    tracks = [(0, None)]
    for _ in range(2):
        idx0 = len(b) // SECTOR
        if gaps:
            b += bytes(GAP * SECTOR)
        tracks.append((len(b) // SECTOR, idx0 if gaps else None))
        b += sine_sectors(AUDIO_SECTORS)
    return bytes(b), tracks


def cue_text(name, tracks, eol):
    lines = [f'FILE "{name}" BINARY']
    for n, (idx1, idx0) in enumerate(tracks, 1):
        lines.append(f"  TRACK {n:02d} {'MODE1/2352' if n == 1 else 'AUDIO'}")
        if idx0 is not None:
            lines.append(f"    INDEX 00 {msf_text(idx0)}")
        lines.append(f"    INDEX 01 {msf_text(idx1)}")
    return eol.join(lines) + eol


def main(argv):
    opts = {"--iso2048": False, "--missing-bin": False, "--crlf": False, "--spaces": False}
    data_sectors = 32
    salt = 0
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in opts:
            opts[a] = True
        elif a == "--data-sectors":
            i += 1
            data_sectors = int(argv[i])
        elif a == "--salt":
            i += 1
            salt = int(argv[i])
        else:
            args.append(a)
        i += 1
    if len(args) != 1:
        sys.exit(__doc__)
    out = pathlib.Path(args[0])
    out.mkdir(parents=True, exist_ok=True)

    disc, tracks = build(data_sectors, True, salt)
    gapless, _ = build(data_sectors, False, salt)
    bin_name = SPACED if opts["--spaces"] else "disc.bin"
    (out / bin_name).write_bytes(disc)
    (out / "gapless.bin").write_bytes(gapless)
    named = "missing.bin" if opts["--missing-bin"] else bin_name
    eol = "\r\n" if opts["--crlf"] else "\n"
    (out / "disc.cue").write_bytes(cue_text(named, tracks, eol).encode())
    readme = [f"{bin_name}: {len(disc) // SECTOR} sectors, data 0-{data_sectors - 1}, audio behind 2-sector INDEX 00 gaps",
              f"gapless.bin: {len(gapless) // SECTOR} sectors, the same tracks with no gap sectors",
              f"disc.cue: names {named}, {'CR LF' if opts['--crlf'] else 'LF'}"]
    if opts["--iso2048"]:
        (out / "disc.iso").write_bytes(b"".join(user_data(lba) for lba in range(data_sectors)))
        readme.append(f"disc.iso: {data_sectors} sectors of 2,048 bytes, no sync")
    (out / "README").write_text("\n".join(readme) + "\n", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
