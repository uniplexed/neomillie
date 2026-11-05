<p align="center"><img src="docs/logo/neomillie.svg" alt="Millie, the NeoMillie logo" width="160"></p>

# NeoMillie

Neo Geo (AES/MVS) and Neo Geo CD cores for the Analogue Pocket, built from the current MiSTer Neo Geo RTL plus a new
Pocket hardware layer.

| Core | What it runs | State |
|---|---|---|
| `uniplexed.NeoMillie` | MVS and AES cartridge games | Works on the games tried |
| `uniplexed.NeoMillieCD` | Neo Geo CD discs, at 1x or as a CDZ at 2x | Early: works on the discs below, more testing needed |

This is the first public release. Everything here was tested on **one Pocket**, so memory timing across units and most
of the library are unknown. Reports are welcome in the issues: say which core, version, BIOS, game and setting.

No BIOS, ROMs or discs are included, and none will be. You need your own.

## Installing

Download the zips from [Releases](https://github.com/uniplexed/neomillie/releases) and unzip each to the root of the
SD card, merging folders. The packages also add the `ng` and `ngcd` platform entries, with their images.

### Neo Geo CD

1. In `Assets/ngcd/common/` put `000-lo.lo` and `uni-bioscd.rom`, the UniBIOS CD, exactly 524,288 bytes. The core
   loads that file by name.
2. Put each disc in its own folder there, with its BIN beside its CUE, for example
   `Assets/ngcd/common/Metal Slug/Metal Slug.cue` and `Metal Slug.bin`.
3. On the Pocket: **openFPGA**, **Neo Geo CD**, **NeoMillieCD**: the BIOS loads. In the Pocket's menu, pick the `.cue`
   on the **Disc** slot.

### Neo Geo cartridges

1. In `Assets/ng/common/` put `uni-bios_4_0.rom`, `000-lo.lo` and `sfix.sfix`, and one folder per game in the Darksoft
   layout (`srom`, `prom`, `crom0`, `m1rom`, `vroma0`, and `prom1` if the game has one). The folder name is the
   `data_path` of the game's JSON file. ROMs and BIOS you already use with the Neo Geo Overdrive core work as they are.
2. On the Pocket: **openFPGA**, **Neo Geo**, then pick a game from the list.

## The CD core

### Speed and the CD/CDZ setting

| CD/CDZ | Reads the disc at | Time per sector |
|---|---|---|
| Off, the default | 1x, 150 KB/s | 13.33 ms |
| On | 2x, 300 KB/s | 6.67 ms |

Changing the setting restarts the core and returns to the BIOS, so unsaved progress is lost. The disc stays mounted.
The Pocket remembers the setting. Speeds above 2x are not offered: at 4x the SD card could not keep up.

### Tested discs

All with `uni-bioscd.rom`, on a Pocket. "Build" is the version the row was run on: 0.5.0 is this release, and 0.3.5 is
a debug build with the same fix for the 2x stop, plus a counter and a separate speed setting, so its 1x rows have
CD/CDZ on, which this release does not offer at 1x.

| Disc | Setting | Result | Build |
|---|---|---|---|
| The King of Fighters '95 | CD/CDZ on, 2x | Plays with music; see "Known issues" | 0.4.1 |
| The King of Fighters '97 | CD/CDZ on, 2x | Works | 0.5.0 |
| The King of Fighters '99 | CD/CDZ on, 2x | A fight finished, no cuts in the music heard | 0.4.0 |
| Metal Slug | CD/CDZ off, 1x | Works | 0.4.0 |
| Metal Slug | CD/CDZ on, 1x | A level cleared | 0.3.5 |
| Samurai Shodown RPG | CD/CDZ on, 1x | Reaches the game; not played further | 0.3.5 |
| Last Blade 2 | CD/CDZ off, 1x | Works | 0.5.0 |

Converted but not yet tried: Crossed Swords II, Fatal Fury 3, Pulstar. Every run is in
[`docs/hw-tests.md`](docs/hw-tests.md), a chronological log of the project's hardware tests.

### BIOS

| File | State |
|---|---|
| `uni-bioscd.rom` | The supported one. All the tests above |
| `top-sp1.bin` | Can be picked in the menu. Works at 1x with CD/CDZ off. Debug builds at 2x loaded very slowly, reading about seven times the sectors. With CD/CDZ on it sees the tray as open |
| `front-sp1.bin` | Can be picked in the menu. Loaded Metal Slug on an early build; little tested |
| `neocd.bin` | Boots, then stops at its disc protection check on protected discs, as the drive does not answer the TOC sub-command that check needs |

### Known issues

- **A silent run:** The King of Fighters '95 ran once with no CD music, on 0.4.1, and had it after a restart. It did not
  happen again, and the cause is not known. If it happens to you, try **Reset Core**, and please report what you did
  before it.
- **The fix for 2x is a tolerance:** the BIOS's directory scan can keep the decoder interrupt masked for longer than a
  sector takes at 2x (8 to 9 ms against 6.67 ms). So this core holds a new sector while that interrupt is masked, for
  at most 50 ms, which real hardware does not do. Simulation found no BIOS or game that depends on the opposite, but
  only two games' programs were searched, and not exhaustively. A held sector can also delay a CD audio track's start
  by up to that long.
- **Brief music cuts** were heard on a debug build, which also writes a counter file to the SD card every 7 seconds.
  None were reported on the short runs of the release builds, which does not prove them gone.
- **Slow SD reads:** a read can take around 450 ms. This slows loading, and in simulation it leaves a silent gap in CD
  audio. The emulated system does not pause for it.

### Disc images

The core reads MODE1/2352 `.cue`/`.bin` only: one `.cue` naming one BIN, with `MODE1/2352` and `AUDIO` tracks, or a raw
`.bin` of one data track. Sets of ISO and WAV files, one file per track, and CHD files need converting first with
`cd_convert.py`, which is attached to each [release](https://github.com/uniplexed/neomillie/releases) and is in `tools/`.
It is one script that needs only Python 3.8 or newer:

    python cd_convert.py DISC.cue OUTDIR [--name NAME]
    python cd_convert.py DISC.chd OUTDIR [--name NAME]

It takes a CUE of MODE1/2048 or MODE1/2352 data tracks and AUDIO tracks, in BINARY or WAVE files, or a CHD. It only reads
them, and writes `NAME.bin` and `NAME.cue` to `OUTDIR/NAME/`. Copy that folder to `Assets/ngcd/common/`. It refuses an
output that would overwrite its source.

A CHD also needs `chdman`, which comes with [MAME](https://www.mamedev.org/), on the PATH or beside the script. The CHD
path was checked with chdman 0.289: Metal Slug and The King of Fighters '95, turned into CHDs and back, gave the same BIN
byte for byte. Metal Slug's CUE was also the same. KOF '95's lost the indexes above 01 in its data track, which a CHD does
not keep, and was not run on a Pocket in that form. CHDs made by other tools have not been tried.

### Slots and menu

| Slot | Required | What it takes |
|---|---|---|
| BIOS | yes | `uni-bioscd.rom`, loaded by name; another `.rom`, `.bin` or `.sp1` of exactly 524,288 bytes can be picked |
| LO | yes | `000-lo.lo` |
| Disc | no | Picked by you: a `.cue`, or a raw `.bin` |
| Disc data | no | Not yours to pick: the core opens the CUE's BIN here |
| Memory Card | no | Up to 8 KB, in `Saves/ngcd/common/`, one file per BIOS, named after it |

Menu: Reset Core, CD/CDZ, Region (US, EU, JP, AS), 304 or 320 wide, and four aspect ratios for the scaler.

### Limits

- A CUE of more than 9,408 bytes is reported as no disc. So is a CUE with a second `FILE`, a `WAVE` file or a MODE1/2048
  track, an ISO of 2,048-byte sectors, and a BIN that is not there.
- BINs go under `Assets/ngcd/`. The core opens the name in the CUE from the CUE's own folder.
- A `PREGAP` before an audio track that follows an audio track plays the next track's first seconds before that track
  starts, as MiSTer does with one BIN. `cd_convert.py` keeps a `PREGAP` as it finds it.
- No CHD, no subcode, no save states, no cheats, and no backup RAM cartridge beyond the 8 KB card.

## The cartridge core

Slots: `Game JSON Setup` is the pick from the list, and the game's JSON file fills SROM, PROG, PROG1, CROM, MROM and
VROM. BIOS, LO and SFIX are the fixed files above. Saves: `Memory Card` and `Backup Ram` (`backup.bak`).

Menu: Reset Core, MVS/AES, PAL output, 304 or 320 wide, and four aspect ratios for the scaler.

Tested on one Pocket and working: Metal Slug 3 (memory card save and read-back after a power cycle), KOF '98, Garou,
Samurai Shodown V Special, The Super Spy, Art of Fighting 1 (jukebox with stereo), changing MVS/AES both ways with a
game running, and Reset Core. On Metal Slug X, first mission, one play, the 68000 lost 1.354% of its clocks waiting for
the ROM memory (worst frame 2.295%). Those ran on earlier builds. On 0.5.0, a game picked from the core's list played and
its memory card save was there after powering off.

Limits:

- The real-time clock (date, time, weekday) was not checked.
- Not in this core yet: screen X/Y position, DIP switch settings, channel mutes, BIOS choice, multitap, spinner and
  mouse, combo buttons, CPU overclock.
- The game list is generated from MiSTer's `romsets.xml`, with the V2 masks of the Overdrive's JSON set. The games named
  above ran with the Overdrive's JSON set, so most of this list has not been tried.
- Saves from the Overdrive core do not load in this one. Its `backup.bak` has the bytes of each 32-bit word reversed,
  its `.sav` has the two halves of each word swapped, and the folder under `Saves/ng/` differs. There is no converter.

## Building from source

    git clone --recurse-submodules https://github.com/uniplexed/neomillie

Simulation (Verilator from OSS CAD Suite, installed under the git-ignored `tools/oss-cad-suite/`):

    python tools/sim.py <bench>        # runs sim/<bench>/tb_*.sv, prints PASS/FAIL

Quartus build (Quartus Prime Lite 25.1) with the ALM and M10K budget check, then the SD card package:

    python tools/build.py neogeo       # or neogeocd
    python tools/package.py neogeo <version>

`neogeocd_wait` builds the CD core's debug version: it keeps CD Speed and Lid open in the menu, and writes counters to
`wait.sav`, which `tools/check_wait_save.py` reads.

Fit of this release on the 5CEBA4F23C8, of 18,480 ALMs and 308 M10K: cartridge core 8,695 ALMs and 272 M10K, CD core
11,611 ALMs and 281 M10K, with no negative slack in either.

## License

GPL-3.0-or-later (see [`LICENSE`](LICENSE)), except where a file's header says otherwise: the CD drive files ported from
MiSTer's `megacdd.cpp` are GPL-3.0-only, which makes the CD core GPL-3.0-only as a whole, and `rtl/top/core_top.v` holds
a part of Analogue's core template under Analogue's EULA.

Neo Geo is a trademark of SNK. This project is not affiliated with or endorsed by SNK, Analogue or the authors of
UniBIOS.

## Credits

Furrtek (Neo Geo core); srg320, Sorgelig, MiSTer-devel, paulb-nl and zakk4223 (MiSTer port, CD subsystem, the CD drive
model, the game list's data); terminator2k2 and Timothee Groleau (the game JSON set for the Overdrive, source of the V2
masks); jotego (jt12, jt49); Jorge Cwik (fx68k); Daniel Wallner (T80); Mazamars312 (Neo Geo Overdrive for Pocket, the
reference for the Pocket memory and loader design); neutralinsomniac (Pocket Mega CD, design reference only); Analogue
(APF framework, under Analogue's own terms). Details and licences are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Developed with [Claude Code](https://claude.com/claude-code).
