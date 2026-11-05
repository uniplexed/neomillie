# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fills the run directory of sim/cdd: commands.txt, and golden.txt from MiSTer's cdd_t run on it."""
import os
import pathlib
import shutil
import subprocess
import sys

BENCH = pathlib.Path(__file__).resolve().parent
run = pathlib.Path(sys.argv[1]).resolve()
src = run / "src"

# The vendored files stay as they are, in the layout of their includes. The harness has what the empty ones hold
for name, where in (("megacdd.cpp", "support/megacd"), ("megacd.h", "support/megacd"), ("cd.h", ".")):
    (src / where).mkdir(parents=True, exist_ok=True)
    shutil.copy(BENCH / "mister" / name, src / where / name)
for name in ("file_io.h", "libchdr/chd.h", "support/chd/mister_chd.h"):
    (src / name).parent.mkdir(parents=True, exist_ok=True)
    (src / name).touch()

shutil.copy(BENCH / "commands.txt", run / "commands.txt")
exe = run / "harness.exe"
# On Linux the zeros in front of cdd (harness.cpp) need the sections sorted by name
link = [] if os.name == "nt" else ["-Wl,--sort-section=name"]
subprocess.run(["g++", "-std=c++17", "-O1", "-w", "-static", *link, "-I", str(src), str(BENCH / "harness.cpp"), "-o", str(exe)], check=True)
with open(run / "golden.txt", "w") as out:
    subprocess.run([str(exe), str(run / "commands.txt")], stdout=out, check=True)
