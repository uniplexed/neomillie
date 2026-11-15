# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The CUE reader: MODE1/2048, MODE1/2352 and AUDIO tracks in BINARY, MOTOROLA (big-endian audio) and WAVE files.

A file ending in .mp3, .ogg, .flac, .ape or .opus is decoded by ffmpeg whatever its FILE line says, since such CUEs
often say WAVE for an MP3. The sheet is read as UTF-8 (a BOM is dropped), else as Latin-1; a file name that is not
found as written is looked up in its folder ignoring case and trying the encodings older sets use.
"""
import re
from pathlib import Path
from typing import List

from .disc import SECTOR, USER, ConvertError, Track, parse_msf

COMPRESSED = (".mp3", ".ogg", ".flac", ".ape", ".opus")
NAME_ENCODINGS = ("utf-8", "cp932", "cp1252", "latin-1")


def sheet_text(path):
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw.decode("latin-1"), "latin-1"


def walk(folder, parts):
    """The file at parts under folder, each part matched as written, else ignoring case; None if there is none."""
    for part in parts:
        if not folder.is_dir():
            return None
        entries = list(folder.iterdir())
        folder = next((e for e in entries if e.name == part), None) or \
            next((e for e in entries if e.name.lower() == part.lower()), None)
        if folder is None:
            return None
    return folder if folder.is_file() else None


def find_file(cue, name, encoding):
    """The file a FILE line names: as written; else from the CUE's folder ignoring case, the separator and the encoding
    of older sets; else its last part beside the CUE, for a path on the PC that made the CUE."""
    path = cue.parent / name
    if path.is_file():
        return path
    raw = name.encode(encoding)
    for enc in NAME_ENCODINGS:
        try:
            parts = [p for p in raw.decode(enc).replace("\\", "/").split("/") if p]
        except UnicodeDecodeError:
            continue
        found = parts and (walk(cue.parent, parts) or walk(cue.parent, parts[-1:]))
        if found:
            return found
    raise ConvertError(f"{cue.name}: {name} not found")


def parse(path):
    """List of tracks: {file, kind, no, mode, pregap, indices}."""
    text, encoding = sheet_text(path)
    tracks, file, kind = [], None, None
    for raw in re.split(r"\r\n|\r|\n", text):
        line = raw.strip()
        if m := re.match(r'FILE\s+(?:"(.+)"|(\S+))\s+(\w+)$', line):
            file, kind = (m[1] or m[2], encoding), m[3].upper()
        elif m := re.match(r"TRACK\s+(\d+)\s+(\S+)", line):
            if m[2] not in ("MODE1/2048", "MODE1/2352", "AUDIO"):
                raise ConvertError(f"{path.name}: track {m[1]} is {m[2]}, which this does not handle")
            tracks.append({"file": file, "kind": kind, "no": int(m[1]), "mode": m[2], "pregap": 0, "indices": {}})
        elif m := re.match(r"(PREGAP|INDEX\s+(\d+))\s+(\S+)", line):
            if not tracks:
                raise ConvertError(f"{path.name}: {m[1]} before any TRACK")
            try:
                at = parse_msf(m[3])
            except ValueError:
                raise ConvertError(f"{path.name}: {line!r} is not a time of mm:ss:ff")
            if m[2] is None:
                tracks[-1]["pregap"] = at
            else:
                tracks[-1]["indices"][int(m[2])] = at
    if not tracks:
        raise ConvertError(f"{path.name}: no tracks")
    for t in tracks:
        if not t["indices"]:
            raise ConvertError(f"{path.name}: track {t['no']} has no INDEX")
    return tracks


def compressed(path: Path) -> bool:
    """Whether a CUE names a compressed audio file."""
    return any(t["file"] and Path(t["file"][0]).suffix.lower() in COMPRESSED for t in parse(path))


def load(path: Path) -> List[Track]:
    """Where each track's bytes are in its file. A CUE's times count sectors of each track's own size."""
    tracks = parse(path)
    by_file = {}
    for t in tracks:
        by_file.setdefault(t["file"], []).append(t)
    for file, shared in by_file.items():
        if file is None:
            raise ConvertError(f"{path.name}: track {shared[0]['no']} has no FILE")
        source = find_file(path, *file)
        byte = 0
        for n, t in enumerate(shared):
            # A file's first track starts at the file's start, with any pregap the file holds
            first = min(t["indices"].values()) if n else 0
            size = USER if t["mode"] == "MODE1/2048" else SECTOR
            sectors = min(shared[n + 1]["indices"].values()) - first if n + 1 < len(shared) else None
            if source.suffix.lower() in COMPRESSED:
                read = "ffmpeg"
            elif t["kind"] == "WAVE":
                read = "wav"
            else:
                # Only audio has a byte order; a data track's bytes are the same either way
                read = "swap" if t["kind"] == "MOTOROLA" and t["mode"] == "AUDIO" else "raw"
            if read in ("wav", "ffmpeg") and len(shared) > 1:
                raise ConvertError(f"{source.name}: tracks sharing an audio file are not handled")
            t["track"] = Track(no=t["no"], audio=t["mode"] == "AUDIO", source=source, offset=byte, stride=size,
                               sectors=sectors, pregap=t["pregap"],
                               indices={i: v - first for i, v in t["indices"].items()}, read=read)
            if sectors is not None:
                byte += sectors * size
    return [t["track"] for t in tracks]
