# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Build and run a Verilator testbench: python tools/sim.py <bench>

Bench layout: sim/<bench>/tb_*.sv plus sim/<bench>/files.f (one source path per
line, relative to the repo root, '#' comments allowed, may be empty).
Each tb_*.sv is built (module name = file stem) and run; any non-zero exit code
or any output line starting with %Error / %Fatal is a failure.
With a sim/<bench>/prepare.py the bench runs in build/sim/<bench>/run, after that
script has filled it; the script gets the directory as its argument.
SIM_DEFINES adds Verilator options. SIM_TAG suffixes the build directory, so that runs of one bench
with different defines can go at once. SIM_ARGS adds plusargs to the run.
"""
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUITE = ROOT / "tools" / "oss-cad-suite"
GIT_USR_BIN = pathlib.Path(r"C:\Program Files\Git\usr\bin")
IS_WIN = os.name == "nt"


def posix(p):
    """C:\a\b -> /c/a/b, so Cygwin perl does not split PERL5LIB on the drive colon."""
    p = pathlib.Path(p)
    return f"/{p.drive[0].lower()}{p.as_posix()[2:]}" if IS_WIN and p.drive else p.as_posix()


# On Windows the suite's verilator is a perl script, which CreateProcess cannot run directly.
VERILATOR = [str(GIT_USR_BIN / "perl.exe"), posix(SUITE / "bin" / "verilator")] if IS_WIN else ["verilator"]


def make_env():
    env = dict(os.environ)
    extra = [str(SUITE / "bin"), str(SUITE / "lib")]
    if IS_WIN:
        # Verilator is a perl script; the suite ships no perl, make or g++.
        # Use Git for Windows' perl (plus a Pod::Usage stub) and MinGW make/g++ from PATH.
        extra.append(str(GIT_USR_BIN))
        env["PERL5LIB"] = posix(ROOT / "tools" / "perl")
        if not shutil.which("make"):
            env["MAKE"] = "mingw32-make"
    env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    return env


def run_checked(cmd, env, log, show=True, cwd=ROOT):
    """Run cmd; echo its output (always if show, else only on failure); return True when it passed."""
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    out = r.stdout + r.stderr
    bad = [l for l in out.splitlines() if l.startswith(("%Error", "%Fatal"))]
    failed = r.returncode != 0 or bad
    if show or failed:
        print(out, end="")
    if failed:
        print(f"{log}: exit code {r.returncode}", file=sys.stderr)
        return False
    return True


def read_files_f(path):
    lines = (l.split("#", 1)[0].strip() for l in path.read_text().splitlines())
    return [l for l in lines if l]


def run_tb(bench, tb, sources, env):
    top = tb.stem
    bdir = ROOT / "build" / "sim" / (bench + os.environ.get("SIM_TAG", ""))
    mdir = bdir / top
    shutil.rmtree(mdir, ignore_errors=True)
    mdir.mkdir(parents=True)
    rel = lambda p: pathlib.Path(p).relative_to(ROOT).as_posix()
    # -O1 because GCC 16 (-Os, C++20) fails to link std::string's move
    # constructor on the MinGW toolchain; drop the overrides once that is fixed.
    # On Linux, Verilator 5.048 built from source into tools/oss-cad-suite (the suite's Windows build is
    # what this project's builds run). Its function splitting declares a fork's sync variable in one C++ function and
    # uses it in another (sim/mem fails to compile), so it is off there, except for sim/top and sim/topcd, which
    # compile with it (3 and 4 minutes, against more than 35 and more than 60 for one function of the whole core);
    # and it makes BLKANDNBLK
    # an error, which fx68k.sv's Nanod raises (sim/top, sim/topcd), where the Windows build only warned.
    linux = [] if IS_WIN else (["-Wno-BLKANDNBLK"] + ([] if bench in ("top", "topcd") else ["--output-split-cfuncs", "0"]))
    cmd = [*VERILATOR, "--binary", "--timing", "-Wno-fatal", "-j", "0", *linux,
           "-MAKEFLAGS", "OPT_GLOBAL=-O1 OPT_FAST=-O1 OPT_SLOW=-O1",
           *os.environ.get("SIM_DEFINES", "").split(),
           "--top-module", top, "--Mdir", rel(mdir), rel(tb), *sources]
    if not run_checked(cmd, env, f"build {top}", show=False):
        return False
    exe = mdir / (f"V{top}.exe" if IS_WIN else f"V{top}")
    # A bench with a prepare.py runs in its own directory, with what the script puts there
    prepare = ROOT / "sim" / bench / "prepare.py"
    cwd = ROOT
    if prepare.is_file():
        cwd = bdir / "run"
        cwd.mkdir(parents=True, exist_ok=True)
        if not run_checked([sys.executable, str(prepare), str(cwd)], env, f"prepare {bench}", show=False):
            return False
    return run_checked([str(exe), *os.environ.get("SIM_ARGS", "").split()], env, f"run {top}", cwd=cwd)


def main(argv):
    if len(argv) != 1:
        sys.exit("usage: sim.py <bench>")
    bench = argv[0]
    bdir = ROOT / "sim" / bench
    tbs = sorted(bdir.glob("tb_*.sv"))
    if not tbs:
        sys.exit(f"sim: no tb_*.sv in {bdir}")
    files_f = bdir / "files.f"
    sources = read_files_f(files_f) if files_f.is_file() else []
    env = make_env()
    ok = all([run_tb(bench, tb, sources, env) for tb in tbs])
    print(f"{'PASS' if ok else 'FAIL'} {bench}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
