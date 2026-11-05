# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fills the run directory of sim/topcd: fx68k's microcode, read by name, the CD's test ROM set and two discs."""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
run = pathlib.Path(sys.argv[1])
for name in ("microrom.mem", "nanorom.mem"):
    shutil.copy(ROOT / "upstream/NeoGeo_MiSTer/rtl/cpu/FX68K" / name, run / name)
# The bench's host reads a card path below this directory. The second disc's CUE is longer, as its BIN's name is:
# a mount with the size of the first reads it short
for folder, options in (("disc", []), ("other 'disc', 2", ["--spaces", "--salt", "165"])):
    subprocess.run([sys.executable, str(ROOT / "tools/make_test_disc.py"), str(run / "Assets/ngcd/common" / folder), *options], check=True)
sys.exit(subprocess.run([sys.executable, str(ROOT / "tools/make_test_roms.py"), "--cd", str(run)]).returncode)
