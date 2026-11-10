# Hardware tests

Results from one Analogue Pocket, run in 2026-11 and reported by the owner, with the date where it is known. Firmware: not
recorded. The debug cores add a 68K wait counter, read on a PC with `tools/check_wait_save.py`.

## Memory test core

A self-test of the Pocket's memory chips and of the way the core talks to them, with no ROMs and no PC. It shows five bands on
screen:

| Band | Test |
|---|---|
| 1 | Both PSRAM chips, both dies, every word, walking and random patterns |
| 2 | The SDRAM, all 64 MB in 4-word bursts, then data left alone for over 5 seconds and read back, with the refresh commands counted and timed |
| 3 | All the memory clients at once at the real rates, checking data and the video deadlines |
| 4 | Whether an access to another address cancels the PSRAM's register sequence on word 3FFFFFh |
| 5 | The test file from the SD card, through the bridge and the loader |

Build 493a551, `RD_WAIT` 8, 2026-11-01: 786 seconds and 29 loops, 0 errors in every band. Worst waits in clocks: fix 21, sprite 20,
68K 20, Z80 40. Largest SDRAM refresh gap 728 clocks, against a limit of 754. An access to another address aborts the 3FFFFFh
sequence on all four dies, so the sequence needs no guard. The save file's read lag is none, and saves are written to
`Saves/ng/<core>/`. `RD_WAIT` 8 covers the PSRAM's tAA with 1.25 ns spare, by the budget in `pocket.sdc`.

## Cartridge core, NeoMillie

| Check | Result |
|---|---|
| UniBIOS menu with a game loaded | Reached, picture and text right |
| Metal Slug | All of level 1, sound good, some slowdown in sprite-heavy places |
| KOF '98 | Runs, reported ok |
| Garou | Large sprites right, `prom1` at 0x800000 works |
| Art of Fighting 1 | No sprite fault in the title; the jukebox plays several songs in stereo |
| Memory card | Metal Slug 3 saves to the card and reads it back after a power cycle; a UniBIOS setting also survives. `backup.bak` is written on Quit |
| MVS and AES | The change from the menu with a game running works both ways, no sound glitch. AES persists across a power cycle |
| Reset Core | The game restarts with correct sprites and sound, and does not reload |
| Menu | Opening it does not reset the game. It shows the core's state: MVS on first boot, PAL, width, scaler |
| PAL | Centred, 16 lines cut at top and bottom, no flicker. The game slows slightly, as on MiSTer |
| 304 wide | No garbage at the edges, and changing the scaler keeps the width |
| Picture position | No difference from `Mazamars312.NeoGeo` |
| P2 coin | A second controller's Select gives a P2 credit, in the dock |
| Z80 and sound | Music keeps time, no sound test crashes |
| Core list | The core lists and loads with an empty `url` in `core.json` |
| Slowdown | Metal Slug 1, level 1, against `Mazamars312.NeoGeo` 0.8.1 (2023-01-17) with no overclock: no faults; by feel the `RD_WAIT` 8 build was slower |
| Real-time clock | Not checked: no clock screen found in the UniBIOS |

Other games that ran well: Metal Slug 3 (SMA, CMC), Metal Slug X (first mission), SVC Chaos (PVC), KOF 2003 (PVC), Samurai
Shodown V (one fight), Samurai Shodown V Special (64 MB of C ROM, two fights), The Super Spy (the logo shows on 3 of 3 starts).
Metal Slug 3's save works in MVS and AES modes, left with Quit (2026-11-09).

### 68K wait counter

Read from the save file, one opening of the core per game, each left with Quit, read lag none, last error 0. With the memory
layout of NeoMillie 0.5.1 (S and M1 copies in the SRAM, work RAM in M10K, two read caches):

| Game, AES mode | Frames | 68K clocks lost | Worst frame |
|---|---|---|---|
| Metal Slug X, first mission | 17,235 | 0 of all 68K clocks, 0.000% | 0 |
| KOF '98 | 23,864 | 0 | 0 |
| Garou | 14,383 | 33,348 of 11,664,626,882, 0.0003% | 40 clocks, behind a fix read |
| KOF 2003 | 11,365 | 28 of 9,217,004,738 | 8 clocks, behind a fix read |

No read waited for the Z80 in any of the three games with a counter. The owner saw no fault in picture or sound.

## CD core, NeoMillieCD

### BIOS boot, no disc, 2026-11-03

| Check | Result |
|---|---|
| The core lists and launches | Pass |
| `top-sp1.bin`, `neocd.bin`, `front-sp1.bin`, `uni-bioscd.rom` | Each reaches its no-disc screen; `uni-bioscd.rom`'s menu is reachable |
| Region | Changes the BIOS language or logo |
| CD/CDZ | The CDZ BIOS screen differs |
| Memory card manager in the BIOS menu | Formats a card, and the card is kept across a power cycle |

With `top-sp1.bin` and no disc, the 68K wait counter over about 4 minutes: 13,890 frames, 638,301,928 BIOS and PROG RAM cycles,
0 clocks lost, every cycle arriving with CRAM0 idle. PROG RAM stays in CRAM0.

### Discs

| Check | Result |
|---|---|
| Metal Slug loads, level 1 and a mid-game load | Pass. The counter reads 0 lost of 519,855,971 cycles, worst frame 0, 12,182 frames, 0 failed sectors |
| Time from the `.cue` pick to the game's logo, Metal Slug, by hand with `uni-bioscd.rom` (2026-11-04) | 37 s with CD/CDZ off at 1x, 18 s with CD/CDZ on at 2x |
| KOF '97 | Loads and plays, music plays, at 1x and at 2x |
| Another disc picked with a game running | The CD screen, then the new game loads |
| Region and CD/CDZ changes | The game loads after each |
| Samurai Shodown RPG | Loads on the first Start Game in both modes (2026-11-08) |
| KOF '99, '97, '95, Pulstar | Work at 2x |
| Fatal Fury 3 | Works almost perfectly at 2x, with a few black frames |
| KOF '98, Art of Fighting, Samurai Shodown IV, Twinkle Star Sprites, Metal Slug 2, Aero Fighters 3 | Play at 2x and sound fine. Converted with `cd_convert.py` from one BIN per track and from a CHD |

Metal Slug and Metal Slug 2 feel slower on CD than on the AES core, with more slowdown only under heavy load, and the music and
sound differ slightly.

### BIOS and console model

The core sets the UniBIOS's console model from CD/CDZ: a top loader with it off, a CDZ with it on, whatever the UniBIOS's own
SYSTEM item says. Bit 12 of FF011C reports a closed tray with the opposite sense on a CDZ and on a top loader, so
`top-sp1.bin` with CD/CDZ on, and `neocd.bin` with it off, each see an open tray.

`neocd.bin` runs the CDZ disc protection check after its boot logo. Metal Slug and KOF '97 carry a "NEO-GEO" block in
`CPY/BIB/ABS.TXT` with flags 03 and expected code 02, and the check at C0D260 needs the drive to answer TOC sub-command 7 with
9,7,0,2. The drive does not answer it, so the check fails. `uni-bioscd.rom` is the same BIOS with the block skipped.

### Memory card

The card is `Saves/ngcd/common/uni-bioscd.sav`, 8 KB. A save made in Samurai Shodown RPG is written on Quit and loaded when the
core opens again, and a second save in another of the game's slots is kept in the same file. The save shows and loads after
Reset Core.

## Fit of the release builds

On the 5CEBA4F23C8, of 18,480 ALMs and 308 M10K, with a budget of 16,600 ALMs and 292 M10K, no negative slack, all clocks met:

| Build | ALMs | M10K |
|---|---|---|
| NeoMillie 0.5.1 | 8,994 | 280 |
| NeoMillieCD 0.5.3 | 11,527 | 281 |

---

NeoMillie is free. If it is useful to you, [donate with PayPal](https://www.paypal.com/donate/?hosted_button_id=A72RAVHX98628).
