# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The cartridge core's game list, from MiSTer's romsets.xml: python tools/make_game_jsons.py --selftest

json_files() yields (file name, bytes) of the instance JSONs in Assets/ng/{core}/. Each points at a game folder of
Assets/ng/common/ in the Darksoft layout (slots of pocket/neogeo/data.json) and writes the settings of apf_regs.svh
that MiSTer's loader takes from the same XML attributes. A setting left out keeps its default, as changing game
reloads the bitstream. Not in the XML, so kept here: V2_MASK and PROM1, which MiSTer learns from the files.

Entries with their own <file> list are MAME sets, which these slots cannot load: skipped, but for KEEP.
The MiSTer XML is under upstream/NeoGeo_MiSTer (GPL), a submodule; no ROM is read or needed.
"""
import hashlib
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

XML = pathlib.Path(__file__).resolve().parent.parent / "upstream/NeoGeo_MiSTer/releases/romsets.xml"
TEXT_ATTRS = {"name", "altname", "altnamej", "publisher", "year", "ram"}     # ram is MiSTer's SDRAM size: not used here
ATTRS = TEXT_ATTRS | {"vromb_offset", "rom_wait", "p_wait", "cmc", "sma", "pvc", "ct0", "link", "xram", "ms5p"}
KEEP = {"lasthope"}             # listed as a MAME set, but also found in the Darksoft layout
FOLDER = {"montest": "MonitorTest", "xenocrisis": "XenoCrisis"}     # as the folder is on the SD cards in use
CRAM1_SIZE = 1 << 24            # vroma0 has to fit, so a V2 past it cannot be honoured: xenocrisis, no writes
# V2 ROM address mask of the games with a split V ROM: MiSTer works it out from the file size, a JSON cannot
V2_MASK = {"bjourney": 0xFFFFF, "bstars": 0x7FFFF, "bstarsh": 0x7FFFF, "cyberlip": 0x7FFFF, "gpilots": 0x3FFFFF,
           "gpilotsh": 0x3FFFFF, "joyjoy": 0x7FFFF, "lbowling": 0x7FFFF, "maglord": 0x7FFFF, "maglordh": 0x7FFFF,
           "mahretsu": 0x7FFFF, "minasan": 0xFFFFF, "nam1975": 0x1FFFFF, "ncombat": 0x7FFFF, "ncombath": 0x7FFFF,
           "ridhero": 0x1FFFFF, "ridheroh": 0x1FFFFF, "superspy": 0x3FFFFF, "tpgolf": 0x1FFFFF}
# Folders with a prom1 are the SMA games and these: MiSTer simply tries to open the file
PROM1 = {"kof2003", "kof2003h"}
SLOTS = [(3, "srom"), (4, "prom"), (5, "crom0"), (6, "m1rom"), (7, "vroma0")]
# apf_regs.svh
REG_V2 = (0x30C, 0x310, 0x314)  # USE_PCM (1 is MiSTer's use_pcm = 0), V2_OFFSET, V2_MASK
REG_C1_WAIT, REG_PCHIP_MAIN, REG_PCHIP_SUB, REG_CMC_CHIP, REG_CART_CHIP = 0x400, 0x404, 0x408, 0x40C, 0x410
REG_MS5P, REG_XRAM = 0x500, 0x504
# Folder: (file name, writes, loads prom1). Pinned below as PINNED, for every game
KNOWN = {
    "mslug": ("Metal Slug - Super Vehicle-001", {}, False),
    "nam1975": ("NAM-1975", {0x30C: 1, 0x310: 0x200000, 0x314: 0x1FFFFF}, False),
    "minasan": ("Minasan no Okagesamadesu! Dai Sugoroku Taikai", {0x30C: 1, 0x310: 0x280000, 0x314: 0xFFFFF}, False),
    "gpilots": ("Ghost Pilots", {0x30C: 1, 0x310: 0x200000, 0x314: 0x3FFFFF}, False),
    "ridhero": ("Riding Hero", {0x30C: 1, 0x310: 0x200000, 0x314: 0x1FFFFF, 0x410: 2}, False),
    "fatfury2": ("Fatal Fury 2", {0x410: 1}, False),
    "kof94": ("King of Fighters '94, The", {0x400: 5}, False),
    "fatfury3": ("Fatal Fury 3 - Road to the Final Victory", {0x400: 1}, False),
    "ncommand": ("Ninja Commando", {0x400: 4}, False),
    "garou": ("Garou - Mark of the Wolves", {0x408: 2, 0x40C: 1}, True),
    "kof99": ("King of Fighters '99, The - Millennium Battle", {0x400: 1, 0x408: 1}, True),
    "kof2000": ("King of Fighters 2000, The", {0x400: 1, 0x408: 5, 0x40C: 2}, True),
    "kof2003": ("King of Fighters 2003, The", {0x404: 1, 0x40C: 2}, True),
    "mslug3": ("Metal Slug 3", {0x408: 4, 0x40C: 1}, True),
    "mslug3h": ("Metal Slug 3 (NGH-2560)", {0x40C: 1}, False),
    "svc": ("SNK vs. Capcom - SVC Chaos", {0x404: 1, 0x40C: 2}, False),
    "ms5plus": ("Metal Slug 5 Plus (bootleg)", {0x500: 1}, False),
    "jockeygp": ("Jockey Grand Prix", {0x504: 1}, False),
    "XenoCrisis": ("Xeno Crisis", {}, False),
    "MonitorTest": ("Monitor Test ROM", {}, False),
    "lasthope": ("Last Hope", {}, False),
    "smsh5sph": ("Samurai Shodown V Special (2nd release, less censored)", {}, False),
    "tws96": ("Tecmo World Soccer '96", {}, False),
}
PINNED = "2c0546617a66c8b640bc4521a6129cb75cea5c6e74c3d2de80965fd0c93a5e10"


def games():
    """(folder, file name, writes, prom1) of each game: writes is {register: value}."""
    out = []
    for r in ET.parse(XML).getroot():
        names = r.get("name").split(",")
        if len(r) and names[0] not in KEEP:
            continue
        assert set(r.attrib) <= ATTRS, f"romsets.xml: new attribute in {names[0]}"
        folder = FOLDER.get(names[0], min(names, key=len))      # the Darksoft name, of 8 letters at most, is the short one
        title = re.sub(r"\s*:\s*|\s+/\s+", " - ", r.get("altname")).replace("/", "-").replace("?", "")
        a = {k: int(r.get(k, "0"), 0) for k in ATTRS - TEXT_ATTRS}
        w = {}
        if 0 < a["vromb_offset"] < CRAM1_SIZE:
            w.update(zip(REG_V2, (1, a["vromb_offset"], V2_MASK[names[0]])))
        wait = a["rom_wait"] << 2 | a["p_wait"]                 # cfg[28] and cfg[30:29]
        cart = a["ct0"] or a["link"] * 2                        # 1 PRO-CT0, 2 Link
        for reg, v in ((REG_C1_WAIT, wait), (REG_PCHIP_MAIN, a["pvc"]), (REG_PCHIP_SUB, a["sma"]),
                       (REG_CMC_CHIP, a["cmc"]), (REG_CART_CHIP, cart), (REG_MS5P, a["ms5p"]), (REG_XRAM, a["xram"])):
            if v:
                w[reg] = v
        out.append((folder, title, w, a["sma"] > 0 or folder in PROM1))
    return out


def instance(folder, writes, prom1):
    """The instance JSON, as the Pocket reads it: variant_select is kept as the set that ran on it had it."""
    slots = SLOTS + [(8, "prom1")] * prom1
    return {"instance": {
        "magic": "APF_VER_1",
        "variant_select": {"id": 777, "select": False},
        "data_path": folder,
        "data_slots": [{"id": i, "filename": f} for i, f in slots],
        "memory_writes": [{"address": f"0xF{a:07X}", "data": f"0x{v:08X}"} for a, v in sorted(writes.items())],
    }}


def json_files():
    """(file name, bytes) of the game list."""
    for folder, title, writes, prom1 in sorted(games(), key=lambda g: g[1]):
        yield f"{title}.json", json.dumps(instance(folder, writes, prom1), indent=4).encode()


def selfcheck():
    g = games()
    by_folder = {x[0]: x for x in g}
    for folder, (title, writes, prom1) in KNOWN.items():
        assert by_folder[folder][1:] == (title, writes, prom1), f"{folder} changed: {by_folder[folder]}"
    files = list(json_files())
    assert len(by_folder) == len(g) == len({n.lower() for n, _ in files}), "two games share a folder or a name"
    assert all(re.fullmatch(r"[^\\/:*?\"<>|]+\.json", n) for n, _ in files)
    for _, data in files:
        i = json.loads(data)["instance"]
        assert [s["id"] for s in i["data_slots"]][:5] == [3, 4, 5, 6, 7] and i["magic"] == "APF_VER_1"
    pinned = hashlib.sha256(repr(sorted(g, key=lambda x: x[0])).encode()).hexdigest()
    assert pinned == PINNED, f"a game's parameters changed: new digest {pinned}"


def main(argv):
    if argv != ["--selftest"]:
        sys.exit("usage: make_game_jsons.py --selftest")
    selfcheck()
    print("make_game_jsons: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
