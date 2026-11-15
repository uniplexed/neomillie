# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The manual's pictures of each core's menu: docs/img/menu-cart.svg and docs/img/menu-cd.svg.

Drawn from pocket/<core>/interact.json, so the items, their order and their defaults are the core's own. The numbers at the
left are the ones the manual's sections use. The group headings are the manual's: the Pocket shows one plain list.

    python tools/make_menu_images.py
"""
import html
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
GROUPS = {      # an item not named here is a system setting
    "Video": ("PAL Output", "320/304 H Video Output", "Video Scaler output", "Screen X Position", "Screen Y Position"),
    "Audio": ("Stereo Mix", "Mute", "ADPCM-A Channel"),
    "Controls": ("L/R Buttons",),
}
DEBUG_ONLY = ("Lid open (debug)",)      # tools/package.py leaves it out of the release
W, ROW, HEAD, PAD = 560, 26, 30, 22


def group_of(name):
    return next((g for g, names in GROUPS.items() if name in names), "System")


def value_of(v):
    if v["type"] == "action":
        return ""
    if v["type"] == "check":
        return "On" if v.get("defaultval") else "Off"
    if v["type"] == "list":
        return next(o["name"] for o in v["options"] if o["value"] == v.get("defaultval", 0))
    return str(v["graphical"]["defaultval"])


def draw(core, title):
    items = [v for v in json.loads((ROOT / "pocket" / core / "interact.json").read_text())["interact"]["variables"]
             if v["name"] not in DEBUG_ONLY]
    rows, y, last = [], 64, None
    for n, v in enumerate(items, 1):
        g = group_of(v["name"])
        if g != last:
            y += 10 if last else 0
            rows.append(f'<text class="g" x="{PAD + 34}" y="{y + 15}">{g.upper()}</text>')
            y += HEAD - 6
            last = g
        rows.append(f'<circle class="n" cx="{PAD + 11}" cy="{y + 11}" r="10"/>'
                    f'<text class="nt" x="{PAD + 11}" y="{y + 15}" text-anchor="middle">{n}</text>'
                    f'<text class="i" x="{PAD + 34}" y="{y + 16}">{html.escape(v["name"])}</text>'
                    f'<text class="v" x="{W - PAD}" y="{y + 16}" text-anchor="end">{html.escape(value_of(v))}</text>')
        y += ROW
    h = y + 14
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="{W}" role="img">
<title>{html.escape(title)}</title>
<desc>The items of the core's menu in the order the Pocket lists them, each with its default value and the number the manual uses for it.</desc>
<style>
svg{{font-family:system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif}}
.bg{{fill:#141416}}.h{{font-size:17px;font-weight:700;fill:#f4f4f4}}.r{{stroke:#3a3a40}}
.g{{font-size:11px;font-weight:700;letter-spacing:.09em;fill:#8f9097}}
.i{{font-size:15px;fill:#ececec}}.v{{font-size:15px;fill:#a4a5ab}}
.n{{fill:#2c2d33}}.nt{{font-size:11.5px;font-weight:700;fill:#e3e3e3}}
</style>
<rect class="bg" width="{W}" height="{h}" rx="14"/>
<text class="h" x="{PAD}" y="38">{html.escape(title)}</text>
<line class="r" x1="{PAD}" y1="52" x2="{W - PAD}" y2="52"/>
{chr(10).join(rows)}
</svg>
'''


def main():
    out = ROOT / "docs" / "img"
    out.mkdir(parents=True, exist_ok=True)
    for core, name, title in (("neogeo", "menu-cart.svg", "NeoMillie: Core Settings"), ("neogeocd", "menu-cd.svg", "NeoMillieCD: Core Settings")):
        svg = draw(core, title)
        assert "Lid open" not in svg
        (out / name).write_text(svg, encoding="utf-8")
        print(out / name, svg.count("<circle"), "items")


if __name__ == "__main__":
    main()
