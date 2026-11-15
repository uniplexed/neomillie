# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Disc image conversion for the NeoMillieCD core: every reader gives a track list, one writer makes NAME.bin and NAME.cue.

A disc is written to DEST/.NAME.partial/ and renamed to DEST/NAME/ only when complete, so an error or a cancel
never leaves a disc that looks whole.
"""
import os
import shutil
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

from . import alcohol, chd, clonecd, cue, discjuggler, nero
from .disc import SECTOR, ConvertError, check_space, default_name, find_tool, safe_name, track_sectors, write_bin

EXTENSIONS = (".cue", ".ccd", ".mds", ".nrg", ".cdi", ".chd")


@dataclass
class Result:
    out: Path
    sectors: int
    gaps: int
    skipped: bool


def inside(path: Path, folder: Path) -> bool:
    """Whether path is in folder, compared by the file system, so case and links do not matter."""
    if not folder.exists():
        return False
    return any(p.exists() and os.path.samefile(p, folder) for p in Path(path).resolve().parents)


def tool(name: str, tools: Optional[Dict[str, str]]) -> Optional[str]:
    return find_tool(name, (tools or {}).get(name))


def find_discs(paths: Iterable[Path]) -> List[Path]:
    """Files as given; folders searched with their subfolders. A .ccd beside a .cue of the same stem is left out."""
    out = []
    for p in map(Path, paths):
        if not p.is_dir():
            out.append(p)
            continue
        found = sorted(f for f in p.rglob("*") if f.is_file() and f.suffix.lower() in EXTENSIONS)
        cues = {(f.parent, f.stem.lower()) for f in found if f.suffix.lower() == ".cue"}
        out += [f for f in found if not (f.suffix.lower() == ".ccd" and (f.parent, f.stem.lower()) in cues)]
    return out


def assign_names(sources: List[Path], names: Optional[List[str]] = None) -> List[Tuple[Path, str, Optional[str]]]:
    """Each source with its name, and an error for a name that cannot be used or that an earlier source took."""
    out, seen = [], {}
    for n, src in enumerate(sources):
        try:
            name = safe_name(names[n]) if names else default_name(src)
        except ConvertError as e:
            out.append((src, "", str(e)))
            continue
        first = seen.setdefault(name.lower(), src)
        out.append((src, name, None if first is src else f"same name as {first.as_posix()}"))
    return out


def needs(source: Path) -> Set[str]:
    """The external tools a disc needs."""
    ext = Path(source).suffix.lower()
    if ext == ".chd":
        return {"chdman"}
    try:
        return {"ffmpeg"} if ext == ".cue" and cue.compressed(Path(source)) else set()
    except Exception:
        return set()        # the conversion reports what is wrong with it


def load(source: Path, workdir: Path, tools: Optional[Dict[str, str]] = None, cancel=None) -> List:
    ext = source.suffix.lower()
    if ext == ".cue":
        return cue.load(source)
    if ext == ".chd":
        return chd.load(source, workdir, tool("chdman", tools), cancel)
    if ext == ".ccd":
        return clonecd.load(source)
    if ext == ".mds":
        return alcohol.load(source)
    if ext == ".nrg":
        return nero.load(source)
    if ext == ".cdi":
        return discjuggler.load(source)
    raise ConvertError(f"{source}: not a disc image this converter reads")


def convert(source: Path, dest: Path, name: str, overwrite: bool = False, tools: Optional[Dict[str, str]] = None,
            progress=None, cancel=None) -> Result:
    """Convert one disc into dest/name. An existing dest/name is skipped unless overwrite is set."""
    source, dest = Path(source), Path(dest)
    name = safe_name(name)
    out = dest / name
    if inside(source, out):
        raise ConvertError(f"{out}: would overwrite the source. Pick another DEST or --name")
    if out.exists() and not overwrite:
        return Result(out, 0, 0, True)
    partial = dest / f".{name}.partial"
    if partial.exists():
        shutil.rmtree(partial)
    partial.mkdir(parents=True)
    try:
        tracks = load(source, partial / ".work", tools, cancel)
        if any(inside(t.source, out) for t in tracks):
            raise ConvertError(f"{out}: would overwrite the source. Pick another DEST or --name")
        ffmpeg = tool("ffmpeg", tools)
        check_space(dest, sum(track_sectors(t, ffmpeg) for t in tracks) * SECTOR)
        at, gaps = write_bin(tracks, partial, name, ffmpeg, progress, cancel)
        shutil.rmtree(partial / ".work", ignore_errors=True)
        if out.exists():
            shutil.rmtree(out)
        partial.rename(out)
    except (OSError, EOFError, wave.Error) as e:
        # A file that cannot be read, or a WAV that is not one
        shutil.rmtree(partial, ignore_errors=True)
        raise ConvertError(f"{source}: {e}") from e
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return Result(out, at, gaps, False)
