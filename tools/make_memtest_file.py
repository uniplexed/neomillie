# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The memory test's file, and its SD card package.

  make_memtest_file.py --print N          first N 16-bit words of the file
  make_memtest_file.py --out FILE         write the file
  make_memtest_file.py --zip memtest VER  dist/uniplexed.MemTest_VER.zip from synth/memtest

File: 2^16 little-endian 16-bit words, the low half of an xorshift32 sequence, the same generator
as memtest.sv. A package has the bit-reversed bitstream, pocket/memtest/*.json, the file under
each slot's name and the Platform entry.
"""
import argparse
import json
import pathlib
import struct
import sys
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_icon import icon_bytes  # noqa: E402
from make_platform_image import image_bytes  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEED = 0x4E474D54
WORDS = 1 << 16
AUTHOR = "uniplexed"
FILES = ["memtest_cram0.bin", "memtest_cram1.bin", "memtest_sdram.bin"]     # one per slot, same content
PLATFORM = {"platform": {"category": "Console", "name": "Neo Geo", "manufacturer": "SNK", "year": 1990}}
VARIANTS = {
    "memtest": ("MemTest", "Neo Geo core memory self-test, RD_WAIT 8. Needs no ROMs."),
}


def words(n):
    x = SEED
    for _ in range(n):
        yield x & 0xFFFF
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF


def file_bytes():
    return b"".join(struct.pack("<H", w) for w in words(WORDS))


def bit_reverse(data):
    table = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
    return data.translate(table)


def package(rev, version):
    name, description = VARIANTS[rev]
    core = f"Cores/{AUTHOR}.{name}"
    rbf = ROOT / "synth" / rev / "output_files" / f"{rev}.rbf"
    out = ROOT / "dist" / f"{AUTHOR}.{name}_{version}.zip"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted((ROOT / "pocket" / "memtest").glob("*.json")):
            text = p.read_text()
            if p.name == "core.json":
                j = json.loads(text)
                j["core"]["metadata"].update(shortname=name, description=description, version=version)
                text = json.dumps(j, indent=4)
            z.writestr(f"{core}/{p.name}", text)
        z.writestr(f"{core}/bitstream.rbf_r", bit_reverse(rbf.read_bytes()))
        z.writestr(f"{core}/icon.bin", icon_bytes(False))
        for slot in FILES:
            z.writestr(f"Assets/ng/common/{slot}", file_bytes())
        z.writestr("Platforms/ng.json", json.dumps(PLATFORM, indent=2))
        z.writestr("Platforms/_images/ng.bin", image_bytes("ng"))
    print(f"{out} {out.stat().st_size} bytes")


def selfcheck():
    assert list(words(4)) == [0x4D54, 0x4AE2, 0x2F03, 0x9E96]  # tb_memtest.sv holds the same values
    assert bit_reverse(bytes([0x01, 0x80, 0xF0])) == bytes([0x80, 0x01, 0x0F])
    assert len(file_bytes()) == 131072


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--print", type=int, dest="n")
    ap.add_argument("--out")
    ap.add_argument("--zip", nargs=2, metavar=("REV", "VERSION"))
    args = ap.parse_args()
    selfcheck()
    if args.n:
        print(" ".join(f"{w:04X}" for w in words(args.n)))
    if args.out:
        pathlib.Path(args.out).write_bytes(file_bytes())
    if args.zip:
        package(*args.zip)
    return 0


if __name__ == "__main__":
    sys.exit(main())
