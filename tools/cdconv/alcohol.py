# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Alcohol 120% images: a .mds descriptor, version 1, and its .mdf of 2,352 or 2,448-byte sectors.

Layout from Aaru's Alcohol 120% reader and writer and Yabause's MDS reader (cdbase.c), with libmirage's image-mds
parser read as a reference only; the three agree on every field used here. The selftest's fixture is laid out
as Aaru's writer lays out a CD. All numbers are little-endian:

- header: "MEDIA DESCRIPTOR", byte 16 the major version (1; version 2 is encrypted and refused), u16 at 20 the
  number of sessions, u32 at 80 the offset of the session blocks;
- session block, 24 bytes: u8 at 10 the number of entries, u32 at 20 the offset of the first 80-byte entry;
- entry: u8 mode at 0 (low three bits: 1 audio, 2 MODE1, others MODE2), u8 at 1 subchannel (8: 96 bytes after
  each sector), u8 point at 4 (1 to 99 a track, A0 to A2 the lead-in's), u32 at 12 the offset of the extra block,
  u16 at 16 the sector size, u32 at 36 the LBA of INDEX 01, u64 at 40 its offset in the .mdf, u32 at 52 the
  offset of the filename block;
- extra block: u32 pregap (INDEX 00 to 01) and u32 length from INDEX 01, in sectors;
- filename block: u32 offset of the name, u32 nonzero for UTF-16; "*.mdf" is the .mds's own name with .mdf.

Track 1's 150-sector pregap is not in the .mdf. A later track's pregap is in it when the track's offset leaves
room for it after the previous track (as Aaru and Yabause read it), else it is a PREGAP (as libmirage reads it).
Audio is little-endian.
"""
import struct
from pathlib import Path
from typing import List

from .cue import find_file
from .disc import SECTOR, USER, ConvertError, Track


def load(path: Path) -> List[Track]:
    b = path.read_bytes()
    if b[:16] != b"MEDIA DESCRIPTOR" or len(b) < 88:
        raise ConvertError(f"{path.name}: not an Alcohol 120% descriptor")
    if b[16] != 1:
        raise ConvertError(f"{path.name}: MDS version {b[16]}.{b[17]}, only version 1 is read")
    try:
        sessions, = struct.unpack_from("<H", b, 20)
        if sessions != 1:
            raise ConvertError(f"{path.name}: {sessions} sessions, only discs of one session are read")
        at, = struct.unpack_from("<I", b, 80)
        entries, first = struct.unpack_from("<B", b, at + 10)[0], struct.unpack_from("<I", b, at + 20)[0]
        found = []
        for n in range(entries):
            e = first + 80 * n
            mode, sub, point = b[e], b[e + 1], b[e + 4]
            if not 1 <= point <= 99:
                continue
            extra, size = struct.unpack_from("<IH", b, e + 12)
            one, offset = struct.unpack_from("<IQ", b, e + 36)
            names, = struct.unpack_from("<I", b, e + 52)
            pregap, length = struct.unpack_from("<II", b, extra)
            if mode & 7 not in (1, 2):
                raise ConvertError(f"{path.name}: track {point} is MODE2, which this does not handle")
            if size not in (USER, SECTOR, SECTOR + 96):
                raise ConvertError(f"{path.name}: track {point} has {size}-byte sectors")
            found.append((point, mode & 7 == 1, size, offset, pregap, length, names))
        if not found:
            raise ConvertError(f"{path.name}: no tracks")
        name_at, wide = struct.unpack_from("<II", b, found[0][6])
        raw = b[name_at:name_at + 1024]
        name = (raw[:len(raw) & ~1].decode("utf-16-le", "replace").split("\0")[0] if wide
                else raw.split(b"\0")[0].decode("latin-1"))
    except struct.error:
        raise ConvertError(f"{path.name}: the descriptor ends early")
    mdf = path.with_suffix(name[1:]) if name.startswith("*.") else find_file(path, name, "latin-1")
    if not mdf.is_file():
        mdf = find_file(path, mdf.name, "utf-8")
    tracks = []
    for n, (no, audio, size, offset, pregap, length, _) in enumerate(sorted(found)):
        indices, gap = {1: 0}, 0
        if n:
            prev = tracks[-1]
            end = prev.offset + prev.sectors * prev.stride
            if pregap and offset - pregap * size == end:
                # The pregap is in the .mdf, before INDEX 01
                offset, indices, length = end, {0: 0, 1: pregap}, length + pregap
            elif offset == end:
                gap = pregap
            else:
                raise ConvertError(f"{path.name}: track {no} is not where the previous track ends")
        tracks.append(Track(no=no, audio=audio, source=mdf, offset=offset, stride=size, sectors=length, pregap=gap,
                            indices=indices))
    return tracks
