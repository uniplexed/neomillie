# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""SD card package of the core: python tools/package.py neogeo|neogeo8|neogeo6|neogeo_wait|neogeo8_wait|neogeo8_zbuf|neogeocd|neogeocd_wait|neogeocd7|neogeocd6 VERSION

Writes dist/uniplexed.NeoMillie_VERSION.zip from synth/neogeo/output_files/neogeo.rbf and pocket/neogeo:
the bit-reversed bitstream and JSON files, the Platform entry and its image (tools/make_platform_image.py), and the
game list (tools/make_game_jsons.py) under the core's own folder in Assets. Millie's icon (tools/make_icon.py) goes in each core folder, the CD one for neogeocd*. The others are cores of their own, for tests; those built with the wait counter add the
results slot of rtl/test/wait_counter.sv to data.json. neogeocd* are the Neo Geo CD core: its JSON files from
pocket/neogeocd, the ngcd Platform entry and no game list. No ROM, BIOS or disc goes in, and the tool checks that.
"""
import datetime
import json
import pathlib
import re
import sys
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_game_jsons import json_files  # noqa: E402
from make_icon import icon_bytes  # noqa: E402
from make_memtest_file import AUTHOR, PLATFORM, ROOT, bit_reverse  # noqa: E402
from make_platform_image import image_bytes  # noqa: E402

# revision: (core name, description or None, JSON directory under pocket, platform)
REVISIONS = {
    "neogeo": ("NeoMillie", None, "neogeo", "ng"),
    "neogeo8": ("NeoGeo8", "Neo Geo cartridge core, test build with RD_WAIT 8", "neogeo", "ng"),
    "neogeo6": ("NeoGeo6", "Neo Geo cartridge core, test build with RD_WAIT 6", "neogeo", "ng"),
    "neogeo_wait": ("NeoGeoWait", "Neo Geo cart core, debug build, RD_WAIT 7, 68K wait counter", "neogeo", "ng"),
    "neogeo8_wait": ("NeoGeo8Wait", "Neo Geo cart core, debug build, RD_WAIT 8, 68K wait counter", "neogeo", "ng"),
    "neogeo8_zbuf": ("NeoGeoZ80Buf", "Neo Geo cart core, debug, RD_WAIT 8, Z80 buffer, wait counter", "neogeo", "ng"),
    "neogeocd": ("NeoMillieCD", None, "neogeocd", "ngcd"),
    "neogeocd_wait": ("NeoGeoCDWait", "Neo Geo CD core, debug build with the 68K wait counter", "neogeocd", "ngcd"),
    "neogeocd7": ("NeoGeoCD7", "Neo Geo CD core, test build with RD_WAIT 7", "neogeocd", "ngcd"),
    "neogeocd6": ("NeoGeoCD6", "Neo Geo CD core, test build with RD_WAIT 6", "neogeocd", "ngcd"),
}
# As memory test's results slot, which ran on the Pocket: parameters 34 puts the file in the core's Saves folder
WAIT_SLOT = {"name": "Wait counter", "id": "0x103", "required": False, "parameters": 34, "nonvolatile": True,
             "filename": "wait.sav", "extensions": ["sav"], "size_exact": None, "size_maximum": 256,
             "address": "0x80000000"}
ALLOWED = {".json", ".bin", ".rbf_r", ".txt"}
README_CD = """Neo Geo CD core for the Analogue Pocket, built from the MiSTer Neo Geo core.
GPL-3.0-only as a whole: its drive files are ported from MiSTer's megacdd.cpp under that licence. The other sources
are GPL-3.0-or-later or as their headers say. The core's JSON files follow those of Mazamars312's Neo Geo Overdrive.

No BIOS, ROMs or discs are included. Put these in Assets/ngcd/common/ on the SD card:
  uni-bioscd.rom (the UniBIOS CD, 512 KB, the supported BIOS, loaded by name) and 000-lo.lo
  (top-sp1.bin and front-sp1.bin can be picked in the menu, untested at 2x; neocd.bin stops at its CDZ disc protection check)
Each disc goes in its own folder there, as a .cue with one .bin in MODE1/2352. cd_convert.py, attached to the release, makes them from ISO, WAV or CHD.
Pick the .cue on the Disc slot. CD/CDZ off reads the disc at 1x, on at 2x; changing it restarts the core.
The memory card is Saves/ngcd/common/uni-bioscd.sav, written when you Quit the core.
Known issues and tested titles: https://github.com/uniplexed/neomillie
"""
README = """Neo Geo cartridge core for the Analogue Pocket, built from the MiSTer Neo Geo core. GPL-3.0-or-later.

No ROMs are included. Put these in Assets/ng/common/ on the SD card:
  uni-bios_4_0.rom, 000-lo.lo, sfix.sfix
  one folder per game, in the Darksoft layout (srom, prom, crom0, m1rom, vroma0, and prom1 if it has one)

The game list in Assets/ng/{core}/ is generated from MiSTer's romsets.xml (NeoGeo_MiSTer, GPL), with the V2 masks of the
JSON set by terminator2k2 and Timothee Groleau. The core's JSON files follow those of Mazamars312's Neo Geo Overdrive.
Saves go to Saves/ng/{core}/.
"""


def members(rev, version):
    """(path in the zip, bytes) of everything."""
    name, description, json_dir, platform = REVISIONS[rev]
    core = f"{AUTHOR}.{name}"
    for p in sorted((ROOT / "pocket" / json_dir).glob("*.json")):
        if p.stem == platform:      # ngcd.json is the Platform entry, not the core's
            continue
        data = p.read_text()
        if p.name == "core.json":
            j = json.loads(data)
            j["core"]["metadata"]["version"] = version
            j["core"]["metadata"]["date_release"] = datetime.date.today().isoformat()
            j["core"]["metadata"]["shortname"] = name
            if description:
                j["core"]["metadata"]["description"] = description
            data = json.dumps(j, indent=4)
        wait_counter = "NEOGEO_WAIT_COUNTER" in (ROOT / f"synth/{rev}/{rev}.qsf").read_text()
        if p.name == "data.json" and wait_counter:
            j = json.loads(data)
            # The CD core's file is 8 records of 512 bytes, as rtl/cd/cd_host.sv's slot write and rtl/pocket/apf_loader.sv's table word. A new name: the host keeps an old file's size
            j["data"]["data_slots"].append(WAIT_SLOT if platform == "ng" else {**WAIT_SLOT, "size_maximum": 8192, "filename": "waitt.sav"})
            data = json.dumps(j, indent=4)
        if p.name == "interact.json" and platform == "ngcd" and not wait_counter:
            # Debug items. Without the counter the speed follows CD/CDZ (rtl/top/neogeo_pocket.sv), and the lid stays closed
            j = json.loads(data)
            j["interact"]["variables"] = [v for v in j["interact"]["variables"] if v["name"] not in ("CD Speed", "Lid open (debug)")]
            data = json.dumps(j, indent=4)
        yield f"Cores/{core}/{p.name}", data.encode()
    yield f"Cores/{core}/bitstream.rbf_r", bit_reverse((ROOT / f"synth/{rev}/output_files/{rev}.rbf").read_bytes())
    yield f"Cores/{core}/icon.bin", icon_bytes(platform == "ngcd")
    if platform == "ng":
        yield "Platforms/ng.json", json.dumps(PLATFORM, indent=2).encode()
    else:
        yield f"Platforms/{platform}.json", (ROOT / "pocket" / json_dir / f"{platform}.json").read_bytes()
    yield f"Platforms/_images/{platform}.bin", image_bytes(platform)
    # Named per core: both zips unzip to the card's root, and the second would overwrite a shared name
    yield f"{AUTHOR}-{name}-README.txt", (README if platform == "ng" else README_CD).format(core=core).encode()
    yield f"{AUTHOR}-LICENSE.txt", (ROOT / "LICENSE").read_bytes()
    if platform == "ng":
        for game, data in json_files():
            yield f"Assets/ng/{core}/{game}", data


def main(argv):
    if len(argv) != 2 or argv[0] not in REVISIONS:
        sys.exit(f"usage: package.py {'|'.join(REVISIONS)} VERSION")
    rev, version = argv
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit("version must be digits: a core with 0.2.0-gate did not list on the Pocket")
    core_name = REVISIONS[rev][0]
    platform = REVISIONS[rev][3]
    out = ROOT / "dist" / f"{AUTHOR}.{core_name}_{version}.zip"
    out.parent.mkdir(exist_ok=True)
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in members(rev, version):
            if pathlib.PurePosixPath(name).suffix not in ALLOWED:
                sys.exit(f"package: {name} has no place in the package")
            z.writestr(name, data)
            n += 1
    with zipfile.ZipFile(out) as z:
        assert z.testzip() is None
        names = z.namelist()
    assert f"Cores/{AUTHOR}.{core_name}/bitstream.rbf_r" in names
    assert not [x for x in names if x.startswith("Assets/ng/common/")], "ROM folder in the package"
    if platform == "ngcd":
        assert not [x for x in names if x.startswith("Assets/")], "game list in the CD package"
    print(f"{out} {out.stat().st_size} bytes, {n} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
