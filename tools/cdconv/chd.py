# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""CHD through MAME's chdman: extractcd into a folder, then the CUE reader."""
import contextlib
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import List

from . import cue
from .disc import Cancelled, ConvertError, Track, NO_WINDOW, check_space, install_hint


def logical_size(path: Path, chdman: str) -> int:
    """The image's size as `chdman info` prints it ("Logical size: 137,088 bytes"), 0 when it does not say."""
    r = subprocess.run([chdman, "info", "-i", str(path)], capture_output=True, text=True, errors="replace",
                       **NO_WINDOW)
    m = re.search(r"Logical size:\s*([\d,]+)", r.stdout)
    return int(m[1].replace(",", "")) if m else 0


@contextlib.contextmanager
def short_dir(folder: Path, name: str):
    """The folder, or on Windows when its path and name are long, a junction to it in the temp folder. chdman opens
    no path of MAX_PATH (260) characters or more, not even with the \\\\?\\ prefix, and Redump names in a deep folder
    get there."""
    if os.name != "nt" or len(str(folder / name)) < 240:
        yield folder
        return
    import _winapi
    link = Path(tempfile.mkdtemp()) / "j"
    _winapi.CreateJunction(str(folder), str(link))
    try:
        yield link
    finally:
        os.rmdir(link)              # removes the junction only, never what it points to
        os.rmdir(link.parent)


def load(path: Path, workdir: Path, chdman: str, cancel=None) -> List[Track]:
    if not chdman:
        raise ConvertError(f"{path.name}: a CHD needs MAME's chdman, on the PATH or beside this program "
                           f"({install_hint('chdman')})")
    workdir.mkdir(parents=True, exist_ok=True)
    path, workdir = path.resolve(), workdir.resolve()
    with short_dir(path.parent, path.name) as src, short_dir(workdir, "x.cue") as out:
        if os.name == "nt" and len(str(src / path.name)) >= 260:
            raise ConvertError(f"{path.name}: a name too long for chdman, which opens no path of 260 characters or "
                               f"more. Give the file a shorter name")
        return extract(src / path.name, workdir, out, chdman, cancel)


def extract(chd: Path, workdir: Path, out: Path, chdman: str, cancel) -> List[Track]:
    """chdman extractcd of chd into out (workdir, or a short way to it), then the CUE reader on workdir's sheet."""
    # The extracted image, then the BIN made from it
    check_space(workdir, 2 * logical_size(chd, chdman))
    p = subprocess.Popen([chdman, "extractcd", "-i", str(chd), "-o", str(out / "x.cue"), "-ob", str(out / "x.bin")],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace", **NO_WINDOW)
    while True:
        try:
            err = p.communicate(timeout=0.2)[1]
            break
        except subprocess.TimeoutExpired:
            if cancel is not None and cancel.is_set():
                p.kill()
                p.communicate()
                raise Cancelled("cancelled")
    if p.returncode:
        raise ConvertError(f"{chd.name}: chdman failed: {err.strip()}")
    return cue.load(workdir / "x.cue")
