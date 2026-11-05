# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Run Quartus map, fit, asm and sta for synth/<revision>, then the fit budget check."""
import pathlib
import subprocess
import sys

QUARTUS_BIN = pathlib.Path(r"C:\altera_lite\25.1std\quartus\bin64")
ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(tool, rev, cwd):
    exe = str(QUARTUS_BIN / f"{tool}.exe")
    # The projects source a shared file: without write_settings_files=off Quartus expands it into the QSF
    cmd = [exe, rev] if tool in ("quartus_asm", "quartus_sta") else [exe, rev, "--read_settings_files=on", "--write_settings_files=off"]
    print(f"== {tool} {rev}", flush=True)
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout + r.stderr


def main(argv):
    if len(argv) != 1:
        sys.exit("usage: build.py <revision>")
    rev = argv[0]
    cwd = ROOT / "synth" / rev
    if not (cwd / f"{rev}.qpf").is_file():
        sys.exit(f"build: {cwd / (rev + '.qpf')} not found")

    timing_ok = True
    for tool in ("quartus_map", "quartus_fit", "quartus_asm", "quartus_sta"):
        rc, out = run(tool, rev, cwd)
        if rc != 0:
            print("\n".join(out.splitlines()[-40:]))
            print(f"FAIL {tool}")
            return 1
        if tool == "quartus_sta":
            bad = [l for l in out.splitlines() if "Timing requirements not met" in l]
            if bad:
                # Still run the budget check below so one run reports everything.
                print(bad[0])
                print("FAIL quartus_sta timing")
                timing_ok = False

    sys.stdout.flush()  # keep our lines ahead of the budget subprocess output
    summary = cwd / "output_files" / f"{rev}.fit.summary"
    budget = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "fit_budget.py"), str(summary),
         "--alm", "16600", "--m10k", "292"]
    ).returncode
    return 0 if timing_ok and budget == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
