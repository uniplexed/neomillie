# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""DiscJuggler images (.cdi), versions 2, 3 and 3.5: the tracks back to back from byte 0, then a descriptor.

Layout from cdirip 0.6.3 by DeXT (cdi.c, cdi.h), the only source that reads versions 2 and 3, and Aaru's
DiscJuggler reader, with libmirage's image-cdi parser read as a reference only. The selftest's fixture writes
the descriptor in cdirip's reading order with the values libmirage's v3.5 framing names for its other bytes.
Only the format's offsets, sizes and values come from cdirip (GPL-2.0-only); none of its code is used.
All numbers are little-endian, audio too.

- Footer, the last 8 bytes: the version word (0x80000004 for 2, 0x80000005 for 3, 0x80000006 for 3.5) and the
  descriptor's offset, from the file's start in 2 and 3, counted back from the end in 3.5.
- Descriptor: u16 sessions; per session u16 tracks (0: an open session, the end), each track's descriptor,
  then 12 bytes (version 2) or 13 (3 and 3.5).
- Track descriptor, in reading order: u32 (nonzero: 8 more bytes), twice the mark 00 00 01 00 00 00 FF FF FF FF,
  4 bytes, u8 name length and the name, 19 bytes, u32 (0x80000000: 8 more bytes), 2 bytes, u32 pregap and u32
  length in sectors, 6 bytes, u32 mode (0 audio, 1 MODE1, 2 MODE2), 12 bytes, u32 start LBA, u32 total length
  (pregap and length), 16 bytes, u32 sector size code (0: 2,048, 1: 2,336, 2: 2,352, 3: 2,368, 4: 2,448 with
  96 bytes of subchannel), 29 bytes; in 3 and 3.5 then 5 bytes and a u32 (0xFFFFFFFF: 78 more bytes).
- Each track takes total length sectors in the file, its pregap first. Track 1's pregap (150 sectors) is
  before LBA 0 and not part of the BIN; a later track's pregap is kept as INDEX 00.
"""
import struct
from pathlib import Path
from typing import List

from .disc import SECTOR, USER, ConvertError, Track

VERSIONS = {0x80000004: 2, 0x80000005: 3, 0x80000006: 35}
SIZES = {0: USER, 2: SECTOR, 4: SECTOR + 96}
MARK = b"\0\0\x01\0\0\0\xff\xff\xff\xff"


def load(path: Path) -> List[Track]:
    size = path.stat().st_size
    if size < 8:
        raise ConvertError(f"{path.name}: not a DiscJuggler image")
    with open(path, "rb") as f:
        f.seek(size - 8)
        word, where = struct.unpack("<II", f.read(8))
        if word not in VERSIONS:
            raise ConvertError(f"{path.name}: DiscJuggler version word 0x{word:08X}, which this does not read")
        version = VERSIONS[word]
        start = size - where if version == 35 else where
        if not 0 <= start < size:
            raise ConvertError(f"{path.name}: its descriptor is not in the file")
        f.seek(start)
        b = f.read(size - start)        # the descriptor, a few KB; the tracks before it stay on disk
    at = 0

    def take(form):
        nonlocal at
        v = struct.unpack_from(form, b, at)
        at += struct.calcsize(form)
        return v if len(v) > 1 else v[0]

    found = []
    try:
        sessions = take("<H")
        for s in range(sessions):
            count = take("<H")
            if not count:
                break
            if found:
                raise ConvertError(f"{path.name}: more than one session, only discs of one session are read")
            for _ in range(count):
                if take("<I"):
                    at += 8
                if b[at:at + 20] != MARK * 2:
                    raise ConvertError(f"{path.name}: track {len(found) + 1}'s descriptor is not where it should be")
                at += 24
                name_length = take("<B")
                at += name_length + 19
                if take("<I") == 0x80000000:
                    at += 8
                at += 2
                pregap, length = take("<II")
                at += 6
                mode = take("<I")
                at += 12
                _, total = take("<II")
                at += 16
                code = take("<I")
                at += 29
                if version != 2:
                    at += 5
                    if take("<I") == 0xFFFFFFFF:
                        at += 78
                no = len(found) + 1
                if mode == 2 or code == 1:
                    raise ConvertError(f"{path.name}: track {no} is MODE2, which this does not handle")
                if mode not in (0, 1) or code not in SIZES:
                    raise ConvertError(f"{path.name}: track {no} has mode {mode}, sector code {code}, "
                                       "which this does not handle")
                found.append((no, mode == 0, SIZES[code], pregap, length, total))
            at += 12 if version == 2 else 13
    except struct.error:
        raise ConvertError(f"{path.name}: the descriptor ends early")
    if not found:
        raise ConvertError(f"{path.name}: no tracks")
    tracks, pos = [], 0
    for no, audio, size, pregap, length, total in found:
        if no == 1 or not pregap:
            tracks.append(Track(no=no, audio=audio, source=path, offset=pos + pregap * size, stride=size,
                                sectors=total - pregap, indices={1: 0}))
        else:
            tracks.append(Track(no=no, audio=audio, source=path, offset=pos, stride=size, sectors=total,
                                indices={0: 0, 1: pregap}))
        pos += total * size
    if pos > start:
        raise ConvertError(f"{path.name}: shorter than its tracks")
    return tracks
