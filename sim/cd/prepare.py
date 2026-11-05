# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fills the run directory of sim/cd with what host_bfm serves, at the card paths the benches name.

Assets/ngcd/common/t/pattern.bin and other.bin: 8 sectors whose byte i is pattern(i), and that xor 0xA5,
so that a read of either file lands somewhere a test can tell apart. tb_cd_host.sv has the same formula.
Assets/ngcd/common/disc/: tools/make_test_disc.py --data-sectors 520, for tb_cd_fetch.sv.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

run = pathlib.Path(sys.argv[1])
SECTOR = 2352


def pattern(i):
    return (i * 13 + (i >> 8) * 7 + (i >> 16) * 3 + 1) & 0xFF


t = run / "Assets" / "ngcd" / "common" / "t"
t.mkdir(parents=True, exist_ok=True)
data = bytes(pattern(i) for i in range(8 * SECTOR))
(t / "pattern.bin").write_bytes(data)
(t / "other.bin").write_bytes(bytes(b ^ 0xA5 for b in data))

subprocess.run([sys.executable, str(ROOT / "tools/make_test_disc.py"), str(run / "Assets/ngcd/common/disc"),
                "--data-sectors", "520"], check=True)
