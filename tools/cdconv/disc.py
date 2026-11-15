# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The track model every reader returns, and the writer that turns a track list into NAME.bin and NAME.cue.

The BIN holds 2,352-byte sectors. A 2,048-byte sector gets its sync, header, EDC and ECC as ECMA-130 gives them;
a sector with subchannel (2,448 bytes) loses the subchannel.

The EDC and ECC code (the ECC_F and ECC_B tables, edc() and ecc_block()) follows Neill Corlett's ECM 1.0,
Copyright (C) 2002 Neill Corlett, under the GNU General Public License version 2 or (at your option) any later
version, used here under version 3 or later.
"""
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

SECTOR = 2352
USER = 2048

ECC_F = [((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF for i in range(256)]
ECC_B = [0] * 256
for i in range(256):
    ECC_B[i ^ ECC_F[i]] = i
EDC = []
for i in range(256):
    e = i
    for _ in range(8):
        e = (e >> 1) ^ (0xD8018001 if e & 1 else 0)
    EDC.append(e)


class ConvertError(Exception):
    """A disc that cannot be converted; the message names the file and the problem."""


class Cancelled(ConvertError):
    pass


def edc(data):
    e = 0
    for b in data:
        e = EDC[(e ^ b) & 0xFF] ^ (e >> 8)
    return e


def ecc_block(src, majors, minors, major_mult, minor_inc):
    size = majors * minors
    out = bytearray(2 * majors)
    for major in range(majors):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minors):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ECC_F[a]
        a = ECC_B[ECC_F[a] ^ b]
        out[major] = a
        out[major + majors] = a ^ b
    return out


def bcd(v):
    return (v // 10) << 4 | v % 10


def msf_text(lba):
    return f"{lba // 4500:02d}:{lba // 75 % 60:02d}:{lba % 75:02d}"


def parse_msf(text):
    m, s, f = map(int, text.split(":"))
    return (m * 60 + s) * 75 + f


def mode1_sector(lba, user):
    """A MODE1/2352 sector of a disc LBA, with the 150 sectors of the lead-in in its address."""
    a = lba + 150
    s = bytearray(SECTOR)
    s[0:12] = b"\x00" + b"\xFF" * 10 + b"\x00"
    s[12:16] = bytes((bcd(a // 4500), bcd(a // 75 % 60), bcd(a % 75), 1))
    s[16:16 + USER] = user
    s[0x810:0x814] = edc(s[:0x810]).to_bytes(4, "little")
    s[0x81C:0x8C8] = ecc_block(s[12:], 86, 24, 2, 86)
    s[0x8C8:SECTOR] = ecc_block(s[12:], 52, 43, 86, 88)
    return s


@dataclass
class Track:
    """One track of a disc image.

    offset is the byte of the track's first sector in source; sectors is None for "to the end of the file";
    indices count sectors from that first sector; read is "raw", "wav", "swap" (big-endian audio) or "ffmpeg".
    """
    no: int
    audio: bool
    source: Path
    offset: int
    stride: int
    sectors: Optional[int]
    pregap: int = 0
    indices: Dict[int, int] = field(default_factory=dict)
    read: str = "raw"


CHUNK = 256     # sectors read at a time
# A windowed program would open a console for each tool it starts
NO_WINDOW = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}


def check_wav(w, name):
    for got, want, what in ((w.getframerate(), 44100, "Hz"), (w.getnchannels(), 2, "channels"),
                            (8 * w.getsampwidth(), 16, "bits")):
        if got != want:
            raise ConvertError(f"{name}: WAV is {got} {what}, needs {want}")


def swap16(data):
    """16-bit words byte-swapped: big-endian audio made little-endian."""
    out = bytearray(data)
    n = len(out) & ~1
    out[0:n:2], out[1:n:2] = data[1:n:2], data[0:n:2]
    return bytes(out)


def need_ffmpeg(t, ffmpeg):
    if not ffmpeg:
        raise ConvertError(f"{t.source.name}: compressed audio needs ffmpeg, on the PATH or beside this program "
                           f"({install_hint('ffmpeg')})")
    return ffmpeg


def ffmpeg_bytes(t, ffmpeg):
    """The track decoded to 44.1 kHz 16-bit stereo, little-endian."""
    # Its errors go to a file: a damaged file can make far more of them than a pipe holds
    with tempfile.TemporaryFile() as errors:
        p = subprocess.Popen([need_ffmpeg(t, ffmpeg), "-nostdin", "-v", "error", "-i", str(t.source),
                              "-f", "s16le", "-ar", "44100", "-ac", "2", "-"], stdout=subprocess.PIPE, stderr=errors,
                             **NO_WINDOW)
        try:
            while data := p.stdout.read(CHUNK * SECTOR):
                yield data
            if p.wait():
                errors.seek(0)
                raise ConvertError(f"{t.source.name}: ffmpeg failed: {errors.read()[-2000:].decode(errors='replace').strip()}")
        finally:
            if p.poll() is None:
                p.kill()
            p.communicate()


def track_bytes(t, ffmpeg=None):
    """The track's bytes, little-endian for audio, in chunks of whole strides where it can."""
    if t.read == "wav":
        with wave.open(str(t.source)) as w:
            check_wav(w, t.source.name)
            while data := w.readframes(CHUNK * 588):
                yield data
        return
    if t.read == "ffmpeg":
        yield from ffmpeg_bytes(t, ffmpeg)
        return
    with open(t.source, "rb") as f:
        f.seek(t.offset)
        left = None if t.sectors is None else t.sectors * t.stride
        while left is None or left:
            data = f.read(CHUNK * t.stride if left is None else min(left, CHUNK * t.stride))
            if not data:
                break
            if left is not None:
                left -= len(data)
            yield swap16(data) if t.read == "swap" else data
        if left:
            raise ConvertError(f"{t.source.name}: shorter than the image says at track {t.no}")


def track_sectors(t: Track, ffmpeg: Optional[str] = None) -> int:
    """How many sectors the track takes in the BIN."""
    if t.read == "wav":
        with wave.open(str(t.source)) as w:
            check_wav(w, t.source.name)
            return -(-w.getnframes() * 4 // SECTOR)
    if t.read == "ffmpeg":
        r = subprocess.run([need_ffmpeg(t, ffmpeg), "-nostdin", "-hide_banner", "-i", str(t.source)],
                           capture_output=True, text=True, errors="replace", **NO_WINDOW)
        # "Duration: 00:03:21.47", hundredths of a second: one sector more covers the rounding
        m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", r.stderr)
        return int((int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3])) * 75) + 1 if m else 0
    if t.sectors is not None:
        return t.sectors
    return -(-(t.source.stat().st_size - t.offset) // t.stride)


def check_space(folder: Path, need: int) -> None:
    free = shutil.disk_usage(folder).free
    if free < need:
        raise ConvertError(f"{folder}: needs {need:,} bytes free, has {free:,}")


def write_bin(tracks: List[Track], out_dir: Path, name: str, ffmpeg: Optional[str] = None,
              progress: Optional[Callable[[float], None]] = None, cancel=None) -> Tuple[int, int]:
    """Write out_dir/name.bin and out_dir/name.cue; returns (sectors in the BIN, sectors of PREGAP).

    progress gets the fraction written, every MB or so and 1.0 at the end; a set cancel event raises Cancelled.
    """
    total = max(1, sum(track_sectors(t, ffmpeg) for t in tracks))
    lines = [f'FILE "{name}.bin" BINARY']
    at = 0          # sectors written to the BIN
    gaps = 0        # sectors of PREGAP so far, on the disc and not in the BIN
    told = 0
    with open(out_dir / f"{name}.bin", "wb") as f:
        for t in tracks:
            lines.append(f"  TRACK {t.no:02d} {'AUDIO' if t.audio else 'MODE1/2352'}")
            if t.pregap:
                lines.append(f"    PREGAP {msf_text(t.pregap)}")
                gaps += t.pregap
            for i, offset in sorted(t.indices.items()):
                lines.append(f"    INDEX {i:02d} {msf_text(at + offset)}")
            stride = SECTOR if t.read == "wav" else t.stride
            rest = b""
            for data in track_bytes(t, ffmpeg):
                if cancel is not None and cancel.is_set():
                    raise Cancelled("cancelled")
                if progress and at - told >= (1 << 20) // SECTOR:
                    progress(min(at / total, 1.0))
                    told = at
                data = rest + data
                whole = len(data) - len(data) % stride
                rest = data[whole:]
                for n in range(0, whole, stride):
                    if stride == USER:
                        f.write(mode1_sector(at + gaps, data[n:n + USER]))
                    else:
                        f.write(data[n:n + SECTOR])
                    at += 1
            if rest:
                if not t.audio:
                    raise ConvertError(f"{t.source.name}: not a whole number of {stride:,}-byte sectors")
                # Audio may end inside a sector: the disc's sector is padded with silence
                f.write(rest[:SECTOR] + bytes(SECTOR - len(rest[:SECTOR])))
                at += 1
    with open(out_dir / f"{name}.cue", "w", newline="\n") as cue:
        cue.write("\n".join(lines) + "\n")
    if progress:
        progress(1.0)
    return at, gaps


RESERVED = {"CON", "PRN", "AUX", "NUL"} | {f"{p}{n}" for p in ("COM", "LPT") for n in range(1, 10)}


def safe_name(name: str) -> str:
    """The name without what Windows and FAT32 refuse in a folder name, and without spaces or dots at its ends."""
    out = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "", name).strip(" .")
    if not out:
        raise ConvertError(f"{name!r}: nothing usable as a folder name")
    head, dot, tail = out.partition(".")
    if head.rstrip().upper() in RESERVED:      # Windows takes CON or CON.x for a device, never for a folder
        out = head + "_" + dot + tail
    return out


def default_name(path: Path) -> str:
    """'Metal Slug (1996)(SNK)(Jp-US)[!]' is 'Metal Slug'; a name that starts with a bracket keeps its whole stem."""
    try:
        return safe_name(re.split(r"\s*[(\[]", path.stem)[0])
    except ConvertError:
        return safe_name(path.stem)


HINTS = {
    ("ffmpeg", "Windows"): "winget install Gyan.FFmpeg, or ffmpeg.exe from ffmpeg.org beside this program",
    ("chdman", "Windows"): "chdman.exe comes with MAME for Windows (mamedev.org): put it beside this program",
    ("ffmpeg", "Darwin"): "brew install ffmpeg",
    ("chdman", "Darwin"): "brew install rom-tools",
    ("ffmpeg", "Linux"): "on Debian and Ubuntu: sudo apt install ffmpeg",
    ("chdman", "Linux"): "on Debian and Ubuntu: sudo apt install mame-tools",
}


def install_hint(tool: str, system: str = platform.system()) -> str:
    """How to get ffmpeg or chdman on this system."""
    return HINTS.get((tool, system)) or HINTS[(tool, "Linux")]


# Where Homebrew and most Unix packages put programs, for a program started without a shell's PATH
EXTRA_DIRS = () if sys.platform == "win32" else ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin")


def find_tool(name: str, configured: Optional[str] = None) -> Optional[str]:
    """The configured path, then beside the script or executable, then the PATH."""
    if configured and Path(configured).is_file():
        return configured
    if getattr(sys, "frozen", False):
        beside = [Path(sys.executable).parent]
        if ".app/Contents/MacOS" in Path(sys.executable).as_posix():
            beside.append(Path(sys.executable).parents[3])      # the folder holding the .app
    else:
        beside = [Path(__file__).resolve().parent.parent]
    path = os.pathsep.join([str(p) for p in beside] + [os.environ.get("PATH", "")] + list(EXTRA_DIRS))
    return shutil.which(name, path=path)
