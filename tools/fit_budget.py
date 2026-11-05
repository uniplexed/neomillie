# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Check an FPGA fit summary against ALM and M10K budgets."""
import argparse
import re
import sys


def read_used(text, label):
    m = re.search(rf"{re.escape(label)}\s*:\s*([\d,]+)\s*/\s*[\d,]+", text)
    if not m:
        sys.exit(f"fit_budget: '{label}' not found in summary")
    return int(m.group(1).replace(",", ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("summary", help="Quartus .fit.summary file")
    ap.add_argument("--alm", type=int, default=16600)
    ap.add_argument("--m10k", type=int, default=292)
    args = ap.parse_args()

    text = open(args.summary, encoding="utf-8", errors="replace").read()
    alm = read_used(text, "Logic utilization (in ALMs)")
    m10k = read_used(text, "Total RAM Blocks")
    ok = alm <= args.alm and m10k <= args.m10k
    print(f"ALMs {alm}/{args.alm} M10K {m10k}/{args.m10k} {'OK' if ok else 'OVER'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
