# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Nero images (.nrg): the tracks from byte 0, then an index of chunks that the file's last bytes point to.

Layout from MAME's cdrom.cpp (parse_nero), libcdio's nrg.c and nrg.h, Aaru's Nero reader, nrgrip and the former
Wikipedia article "NRG (file format)", with libmirage's image-nrg parser read as a reference only. Every number
in the index is big-endian; the audio is little-endian, as in a BIN, as libcdio, Aaru and nrgrip read it (MAME's
parse_nero swaps it as big-endian).

- Footer: "NER5" and a 64-bit offset of the first chunk in the last 12 bytes (version 2), or "NERO" and a 32-bit
  one in the last 8 (version 1). A chunk is a 4-byte name and a 32-bit size, up to END!.
- DAOX (version 2) or DAOI (version 1), disc at once: a 22-byte header, then per track 42 or 30 bytes: ISRC (12),
  u16 sector size, u8 mode, a byte and a u16, then the file offsets of INDEX 00, INDEX 01 and the track's end,
  64-bit or 32-bit. Track 1's pregap is in the file before its INDEX 01, and so is every later pregap.
- ETN2 or ETNF, track at once: per track the offset and the length in bytes, the mode and the start LBA. No
  pregap is in the file; each track after the first gets the two seconds track-at-once writing leaves, as a PREGAP.
- Mode codes: 0x00 MODE1 of 2,048 bytes, 0x05 MODE1 of 2,352, 0x0F MODE1 with 96 bytes of subchannel, 0x07 and
  0x08 audio, 0x10 audio with subchannel; 0x02, 0x03, 0x06 and 0x11 are MODE2.
- SINF: one per session. More than one session, or more than one DAO or ETN chunk, is refused.
The CUES and CUEX chunks repeat what DAO gives and are not read.
"""
import struct
from pathlib import Path
from typing import List

from .disc import SECTOR, USER, ConvertError, Track

DATA = {0x00: USER, 0x05: SECTOR, 0x0F: SECTOR + 96}
AUDIO = {0x07: SECTOR, 0x08: SECTOR, 0x10: SECTOR + 96}
MODE2 = {0x02, 0x03, 0x06, 0x11}


def kind(path, no, mode):
    """(audio, sector size) of a mode code."""
    if mode in MODE2:
        raise ConvertError(f"{path.name}: track {no} is MODE2, which this does not handle")
    if mode not in DATA and mode not in AUDIO:
        raise ConvertError(f"{path.name}: track {no} has mode 0x{mode:02X}, which this does not handle")
    return mode in AUDIO, AUDIO.get(mode) or DATA[mode]


def chunks(path):
    """The index's chunks as (name, data), and whether the 64-bit forms are used."""
    size = path.stat().st_size
    with open(path, "rb") as f:
        f.seek(max(0, size - 12))
        tail = f.read()
        if tail[:4] == b"NER5":
            wide, (first,), end = True, struct.unpack(">Q", tail[4:]), size - 12
        elif tail[4:8] == b"NERO":
            wide, (first,), end = False, struct.unpack(">I", tail[8:]), size - 8
        else:
            raise ConvertError(f"{path.name}: not a Nero image (no NERO or NER5 at its end)")
        f.seek(first)
        index = f.read(max(0, end - first))
    out, at = [], 0
    while at + 8 <= len(index):
        name, n = index[at:at + 4], struct.unpack_from(">I", index, at + 4)[0]
        if name == b"END!":
            break
        out.append((name, index[at + 8:at + 8 + n]))
        at += 8 + n
    return out, wide


def load(path: Path) -> List[Track]:
    found, wide = chunks(path)
    names = [n for n, _ in found]
    if names.count(b"SINF") > 1 or sum(names.count(n) for n in (b"DAOI", b"DAOX", b"ETNF", b"ETN2")) > 1:
        raise ConvertError(f"{path.name}: more than one session, only discs of one session are read")
    tracks = []
    try:
        for name, data in found:
            if name in (b"DAOI", b"DAOX"):
                step, form = (42, ">12sHBBHQQQ") if name == b"DAOX" else (30, ">12sHBBHIII")
                first = data[20]
                for n in range((len(data) - 22) // step):
                    _, size, mode, _, _, zero, one, end = struct.unpack_from(form, data, 22 + n * step)
                    no = first + n
                    audio, _ = kind(path, no, mode)
                    if size not in (USER, SECTOR, SECTOR + 96):
                        raise ConvertError(f"{path.name}: track {no} has {size}-byte sectors")
                    # Track 1 starts at INDEX 01: the lead-in's pregap is not part of the disc's BIN
                    start = one if not tracks else zero
                    tracks.append(Track(no=no, audio=audio, source=path, offset=start, stride=size,
                                        sectors=(end - start) // size,
                                        indices={0: 0, 1: (one - start) // size} if one > start else {1: 0}))
            elif name in (b"ETNF", b"ETN2"):
                step, form = (32, ">QQII") if name == b"ETN2" else (20, ">IIII")
                for n in range(len(data) // step):
                    offset, length, mode, _ = struct.unpack_from(form, data, n * step)
                    no = n + 1
                    audio, size = kind(path, no, mode & 0xFF)
                    tracks.append(Track(no=no, audio=audio, source=path, offset=offset, stride=size,
                                        sectors=length // size, pregap=150 if n else 0, indices={1: 0}))
    except struct.error:
        raise ConvertError(f"{path.name}: its index ends early")
    if not tracks:
        raise ConvertError(f"{path.name}: no DAO or track at once index")
    return tracks
