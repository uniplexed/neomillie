# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fills the run directory of sim/top: fx68k's microcode, read by name, and the test ROM set."""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
run = pathlib.Path(sys.argv[1])
for name in ("microrom.mem", "nanorom.mem"):
    shutil.copy(ROOT / "upstream/NeoGeo_MiSTer/rtl/cpu/FX68K" / name, run / name)
sys.exit(subprocess.run([sys.executable, str(ROOT / "tools/make_test_roms.py"), str(run)]).returncode)
