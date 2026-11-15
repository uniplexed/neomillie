# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""CloneCD images: a .ccd sheet and a .img of 2,352-byte sectors; the .sub (subchannel) is not read.

Layout from the GNU ccd2cue manual (appendix B, "CCD sheet format"), the psx-spx CD-ROM file format notes
(section "CDROM Disk Images CCD/IMG/SUB (CloneCD)") and Mednafen's CCD reader, with libmirage's image-ccd parser
read as a reference only. The selftest's fixture follows the layout of cue2ccd's dataplusaudio test sheet.

The .ccd is INI text. [Disc] Sessions must be 1 and DataTracksScrambled 0. [TRACK n] gives MODE (0 audio,
1 MODE1, 2 MODE2) and INDEX 0 and INDEX 1 as absolute sectors. The .img starts at LBA 0, track 1's 150-sector
pregap not stored, and holds every later pregap (INDEX 0 to INDEX 1). Entry Point 0xA2's PLBA is the lead-out.
"""
import re
from pathlib import Path
from typing import List

from .cue import find_file
from .disc import SECTOR, ConvertError, Track


def number(text):
    text = text.strip()
    return int(text, 16) if text.lower().startswith("0x") else int(text)


def sections(path):
    """{section name in lower case: {key in lower case: value}}."""
    out, current = {}, None
    for raw in re.split(r"\r\n|\r|\n", path.read_bytes().decode("latin-1")):
        line = raw.strip()
        if m := re.fullmatch(r"\[(.+)\]", line):
            current = out.setdefault(m[1].strip().lower(), {})
        elif "=" in line and current is not None:
            key, value = line.split("=", 1)
            current[key.strip().lower()] = value.strip()
    return out


def load(path: Path) -> List[Track]:
    s = sections(path)
    try:
        disc = s["disc"]
        if number(disc.get("sessions", "1")) != 1:
            raise ConvertError(f"{path.name}: {disc['sessions']} sessions, only discs of one session are read")
        if number(disc.get("datatracksscrambled", "0")):
            raise ConvertError(f"{path.name}: its data tracks are scrambled, which this does not read")
        img = find_file(path, path.stem + ".img", "utf-8")
        leadout = next((number(e["plba"]) for name, e in s.items()
                        if name.startswith("entry ") and number(e.get("point", "0")) == 0xA2), None)
        if leadout is None:
            leadout = img.stat().st_size // SECTOR
        found = sorted((int(name.split()[1]), sec) for name, sec in s.items() if re.fullmatch(r"track \d+", name))
    except (KeyError, ValueError) as e:
        raise ConvertError(f"{path.name}: not a CloneCD sheet this converter reads ({e})")
    if not found:
        raise ConvertError(f"{path.name}: no tracks")
    starts = []
    for no, sec in found:
        mode = number(sec.get("mode", "1"))
        if mode not in (0, 1):
            raise ConvertError(f"{path.name}: track {no} is MODE{mode}, which this does not handle")
        indices = {int(k.split()[1]): number(v) for k, v in sec.items() if re.fullmatch(r"index \d+", k)}
        if 1 not in indices:
            raise ConvertError(f"{path.name}: track {no} has no INDEX 1")
        # Track 1 starts at LBA 0 whatever its indices say: the .img starts there
        starts.append((no, mode == 0, 0 if no == found[0][0] else min(indices.values()), indices))
    tracks = []
    for n, (no, audio, start, indices) in enumerate(starts):
        end = starts[n + 1][2] if n + 1 < len(starts) else leadout
        tracks.append(Track(no=no, audio=audio, source=img, offset=start * SECTOR, stride=SECTOR, sectors=end - start,
                            indices={i: v - start for i, v in indices.items() if v >= start}))
    return tracks
