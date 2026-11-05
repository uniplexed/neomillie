# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Fail if a source file lacks the GPL-3 notice in its first 40 lines."""
import pathlib
import sys

EXTS = {".sv", ".v", ".vhd", ".py"}
MARKER = "GNU General Public License"
HEAD_LINES = 40
SKIP_DIRS = {"oss-cad-suite"}  # third-party, git-ignored


def main(dirs):
    bad = []
    for d in dirs:
        for p in sorted(pathlib.Path(d).rglob("*")):
            if p.suffix not in EXTS or not p.is_file() or SKIP_DIRS & set(p.parts):
                continue
            with open(p, encoding="utf-8", errors="replace") as f:
                head = [line for _, line in zip(range(HEAD_LINES), f)]
            if not any(MARKER in line for line in head):
                bad.append(p)
    for p in bad:
        print(f"missing GPL-3 header: {p}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["rtl", "sim", "tools"]))
