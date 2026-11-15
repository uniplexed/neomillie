# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Turn CD images into what the CD core reads.

    python cd_convert.py SOURCE... DEST [--name NAME] [--overwrite]
    python cd_convert.py --selftest

SOURCE is a disc image or a folder, searched with its subfolders for .cue, .ccd, .mds, .nrg, .cdi and .chd.
Each disc becomes DEST/NAME/NAME.bin, of 2,352-byte sectors, and NAME.cue beside it. NAME is the image's
name up to its first bracket ("Metal Slug (1996)(SNK)(Jp-US)[!]" is "Metal Slug"), or --name with one disc.
For the core's layout on an SD card, DEST is <SD>/Assets/ngcd/common.

The sources are only read. A disc already in DEST is skipped unless --overwrite is given, and a disc that fails
leaves nothing behind. A CHD needs MAME's chdman and compressed audio needs ffmpeg, each on the PATH or beside
this script; the rest needs only Python 3.8 or newer. The work is done by the cdconv package beside this script.
--selftest runs the checks on made-up images, and on CHD and compressed audio when chdman and ffmpeg are there.
"""
import argparse
import pathlib
import sys

sys.dont_write_bytecode = True     # no __pycache__ in tools/
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cdconv  # noqa: E402
from cdconv.disc import SECTOR, ConvertError  # noqa: E402


def main(argv):
    if argv == ["--selftest"]:
        from cdconv import selftest
        selftest.run()
        return 0
    ap = argparse.ArgumentParser(prog="cd_convert.py", description=__doc__.split("\n\n")[0],
                                 usage="python cd_convert.py SOURCE... DEST [--name NAME] [--overwrite]")
    ap.add_argument("paths", nargs="+", metavar="SOURCE... DEST")
    ap.add_argument("--name", help="the disc's name, with one disc only")
    ap.add_argument("--overwrite", action="store_true", help="write over a disc already in DEST")
    args = ap.parse_args(argv)
    if len(args.paths) < 2:
        ap.error("needs at least one SOURCE and a DEST")
    dest = pathlib.Path(args.paths[-1])
    sources = cdconv.find_discs(pathlib.Path(p) for p in args.paths[:-1])
    if not sources:
        ap.error("no disc images found")
    if args.name and len(sources) > 1:
        ap.error(f"--name takes one disc, and {len(sources)} were found")
    failed = False
    for source, name, error in cdconv.assign_names(sources, [args.name] if args.name else None):
        try:
            if error:
                raise ConvertError(error)
            r = cdconv.convert(source, dest, name, overwrite=args.overwrite)
        except (ConvertError, OSError) as e:      # OSError: a DEST that cannot be written, as a full or read-only card
            print(f"{source}: {e}", flush=True)
            failed = True
            continue
        if r.skipped:
            print(f"{name}: already there", flush=True)
        else:
            print(f"{name}: {r.sectors} sectors in the BIN, {r.sectors + r.gaps} on the disc, {r.sectors * SECTOR} bytes",
                  flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
