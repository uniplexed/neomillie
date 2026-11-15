# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The licence file that goes inside a converter program:
python tools/third_party_licenses.py OUT TAG COMMIT [LIB...]

Run it on the system that built the program, with the Python and PyInstaller that built it, after the build.
TAG is the release, COMMIT the commit the program was built from. LIB... are the native libraries inside the
program by file name: the .so files on Linux, the .dll files on Windows, the .dylib files and Python on macOS.

OUT gets, in order: what the program is, its licence and where its source is; PyInstaller's licence with its
bootloader exception; the licence file of the Python that built it; tools/licenses/third-party.txt, the libraries
Python's builds carry (OpenSSL, zlib, bzip2, xz, libffi, expat, Tcl and Tk); on Linux, the Debian copyright file
of the package of each other LIB and the common licences those files refer to; on Windows, a note on Microsoft's
runtime files. A LIB this does not know the licence of stops it with an error, so a new library cannot ship
without its licence.
"""
import importlib.metadata
import re
import subprocess
import sys
import sysconfig
from fnmatch import fnmatch
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULE = "=" * 80
# The packages whose files tools/licenses/third-party.txt holds (libssl3 is Ubuntu 22.04's name for libssl3t64)
COVERED = {"libpython3.12-stdlib", "libssl3t64", "libssl3", "zlib1g", "libbz2-1.0", "liblzma5", "libffi8",
           "libexpat1", "libtcl8.6", "libtk8.6"}
# The libraries the Windows and macOS builds carry, all covered by Python's licence, third-party.txt and the
# Microsoft note. A name outside these is a new library whose licence must be added first
KNOWN = {"win32": ["python3*.dll", "tcl86t.dll", "tk86t.dll", "libcrypto-3*.dll", "libssl-3*.dll", "zlib1.dll",
                   "libffi-*.dll", "sqlite3.dll", "vcruntime140.dll", "vcruntime140_1.dll", "ucrtbase.dll",
                   "api-ms-win-*.dll"],
         "darwin": ["Python", "libcrypto.3.dylib", "libssl.3.dylib", "libtcl8.6.dylib", "libtk8.6.dylib"]}
FREETYPE = ("Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights "
            "reserved.")
MICROSOFT = ("VCRUNTIME140.dll and VCRUNTIME140_1.dll come with Python's Windows build, under the \"Additional\n"
             "Conditions for this Windows binary build\" of Python's licence above. ucrtbase.dll and the\n"
             "api-ms-win-*.dll files are Windows' Universal C Runtime, copied unmodified from the build system.\n"
             "These Microsoft files are not under the GPL: they are system libraries of Windows (GPL version 3,\n"
             "section 1), distributed under Microsoft's terms for them, for Windows only.")


def section(title, text):
    return f"\n{RULE}\n{title}\n{RULE}\n\n{text.rstrip()}\n"


def python_licence():
    for p in (Path(sys.base_prefix) / "LICENSE.txt", Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"):
        if p.is_file():
            return p.read_text(encoding="utf-8", errors="replace")
    raise SystemExit("no LICENSE.txt in this Python")


def pyinstaller_licence():
    dist = importlib.metadata.distribution("pyinstaller")
    f = next(f for f in dist.files if f.name.upper().startswith("COPYING"))
    return Path(dist.locate_file(f)).read_text(encoding="utf-8", errors="replace")


def debian_licences(libs, have):
    """Sections for the Debian packages of libs that third-party.txt does not hold, and the common licences
    they refer to that it does not hold either. Only the building Python's own libpython may be from no package."""
    known = {}
    ld = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True, check=True).stdout
    for line in ld.splitlines():
        m = re.match(r"\s*(\S+) .*=> (\S+)", line)
        if m:
            known.setdefault(m[1], m[2])
    out, pkgs, common, loose = [], [], [], []
    for lib in libs:
        path, r = known.get(lib), None
        # dpkg knows a file by the path its package installed, /usr/lib/... where /lib is a link to /usr/lib
        for p in ([path, str(Path(path).resolve()), "/usr" + path] if path else []):
            r = subprocess.run(["dpkg", "-S", p], capture_output=True, text=True)
            if not r.returncode:
                break
        if not r or r.returncode:
            loose.append(lib)
            continue
        pkg = r.stdout.split(":")[0]
        if pkg not in COVERED and pkg not in pkgs:
            pkgs.append(pkg)
    unknown = [lib for lib in loose if not lib.startswith("libpython")]
    if unknown:
        raise SystemExit(f"no package, so no licence, for: {', '.join(unknown)}")
    for pkg in pkgs:
        text = Path(f"/usr/share/doc/{pkg}/copyright").read_text(encoding="utf-8", errors="replace")
        out.append(section(f"{pkg} (Debian copyright file)", text))
        if pkg.startswith("libfreetype"):
            out.append("\n" + FREETYPE + "\n")
        for c in re.findall(r"/usr/share/common-licenses/([A-Za-z0-9.+-]*[A-Za-z0-9+])", text):
            p = Path("/usr/share/common-licenses") / c
            name = p.resolve().name if p.exists() else c      # GPL and LGPL are links to GPL-3 and LGPL-3
            if p.exists() and name not in common:
                common.append(name)
    for c in common:
        if f"\n{c} (as /usr/share/common-licenses/{c})\n" not in have:
            out.append(section(f"{c} (as /usr/share/common-licenses/{c})",
                               (Path("/usr/share/common-licenses") / c).read_text(encoding="utf-8")))
    return "".join(out)


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    out, tag, commit, libs = Path(argv[0]), argv[1], argv[2], argv[3:]
    if sys.platform in KNOWN:
        new = [lib for lib in libs if not any(fnmatch(lib.lower(), k.lower()) for k in KNOWN[sys.platform])]
        if new:
            raise SystemExit(f"a library whose licence is not in the file yet: {', '.join(new)}")
    common = (HERE / "licenses" / "third-party.txt").read_text(encoding="utf-8")
    text = (f"NeoMillieCD Converter, release {tag}, from https://github.com/uniplexed/neomillie\n\n"
            "The converter is free software under the GNU General Public License, version 3 or (at your option) any\n"
            "later version: LICENSE.txt beside this file. This program was built from commit\n"
            f"{commit}, whose source is at https://github.com/uniplexed/neomillie/tree/{commit}:\n"
            "tools/cd_convert.py, tools/cd_convert_gui.py, tools/make_logo.py, tools/make_icon.py and tools/cdconv/,\n"
            "built by .github/workflows/converter.yml with PyInstaller.\n\n"
            "The program carries a Python interpreter and libraries by other authors. Their licences follow.\n")
    text += section("PyInstaller (its bootloader starts the program)", pyinstaller_licence())
    text += section(f"Python {sys.version.split()[0]}", python_licence())
    text += "\n" + common
    if sys.platform.startswith("linux"):
        text += debian_licences(libs, common)
    if sys.platform == "win32":
        text += section("Microsoft runtime files", MICROSOFT)
    out.write_text(text, encoding="utf-8", newline="\n")
    print(out, len(text), "characters")


if __name__ == "__main__":
    main(sys.argv[1:])
