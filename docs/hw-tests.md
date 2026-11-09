# Hardware tests

## First fit of the real core (no hardware)

`python tools/build.py neogeo`: the real `rtl/top/neogeo_pocket.sv` with the loader, video and audio
blocks replaced by the stubs in `synth/neogeo/core_top.v`. Quartus 25.1 Lite, 5CEBA4F23C8. Nothing here
ran on a Pocket.

| Resource | Used | Device | Budget |
|---|---|---|---|
| ALMs | 8,056 | 18,480 | 16,600 |
| M10K blocks | 269 | 308 | 292 |
| Block memory bits | 2,015,059 | 3,153,920 | |
| DSP blocks | 5 | 66 | |

Estimate with the missing blocks: about 9,300 ALMs and 276 M10K, under budget. The basis is the fit of
the Overdrive in its own Quartus project: its `apf_io` is 871 ALMs and 3 M10K, 787 without the bridge
peripheral that is already counted, plus about 200 ALMs and 2 M10K for the block reorder buffers
of the fix and sprite conversions; `video_out` about 150 ALMs and 1 M10K; its `i2s` is 50 ALMs and 1 M10K.

Timing, ns of slack (the 48 and 96 MHz clocks are analysed together, no asynchronous group between them):

| Clock | Fmax Slow 85C | Setup Slow 85C | Setup Slow 0C | Setup Fast 85C | Setup Fast 0C | Hold, worst corner |
|---|---|---|---|---|---|---|
| CLK_96M | 99.16 MHz | +0.259 | +0.279 | +1.534 | +1.680 | +0.158 |
| CLK_48M | 49.50 MHz | +1.951 | +2.007 | +4.462 | +4.811 | +0.030 |
| dram_clk | | +1.956 | +1.941 | +2.449 | +2.461 | +3.883 |
| clk_74a | 139.31 MHz | +6.290 | +6.314 | +8.997 | +9.240 | +0.149 |
| CLK_PIX | | +17.541 | +17.763 | +18.888 | +19.127 | +0.197 |

CLK_96M and CLK_48M Fmax here include the pad windows of `pocket.sdc`, which are their worst paths: CLK_48M's
49.50 MHz is the SRAM read path, a four-clock path by constraint, and CLK_96M's worst path is `cram1_dq`
output enable. Worst 48 to 96 MHz path +1.796 ns, worst 96 to 48 MHz path +2.073 ns (Slow 85C). Hold on the 48 to 96 MHz paths is the
thin one, and it moves with placement: the fitter is told to aim 0.2 ns past it (`pocket.sdc`), and timing analysis
checks the true requirement.

## Memory test core

A self-test of the Pocket's memory chips and of the way this core talks to them. It needs no ROMs and
no PC. Everything it finds is on screen. This section says what to expect from the design;
what the Pocket really did is under Results below.

There are two cores. **MemTest** reads the memory the way the data sheet asks. **MemTest7** reads it one
clock faster, the way another Neo Geo core for the Pocket does: it breaks the data sheet on paper, and
whether real chips mind is the question. Red rows in MemTest7 are an answer, not a fault.

### What to copy

1. Take the SD card out of the Pocket and put it in a computer.
   If an earlier build is on the card, delete `Assets/ng/common/memtest.bin` and any old
   `Saves/ng/pocket-neogeo.MemTest*/memtest.sav`: the layout of the save changed between builds.
2. Unzip `dist/pocket-neogeo.MemTest_0.1.0.zip` to the root of the card, merging folders, not into a folder
   of its own. Do the same with
   `dist/pocket-neogeo.MemTest7_0.1.0.zip`. They add:
   - `Cores/pocket-neogeo.MemTest/` and `Cores/pocket-neogeo.MemTest7/`
   - `Assets/ng/common/memtest_cram0.bin`, `memtest_cram1.bin`, `memtest_sdram.bin`, the test files
   - `Platforms/ng.json` and its image. If the card already has them, overwriting is fine.
3. Put the card back in the Pocket.

### What to run

1. On the Pocket: **openFPGA**, then **Neo Geo**. If it lists several cores, pick **MemTest**.
2. It should not need to ask for anything. If it does ask for a file, up to once for each of the three
   test files, pick the one the Pocket names: `memtest_cram0.bin`, `memtest_cram1.bin`, `memtest_sdram.bin`.
3. Do not press anything else. The core does not use the controls.
4. Leave it for **at least 10 minutes, and until the Pocket feels warm**. A full round of all tests takes
   about 30 seconds. Heat is part of the test: faults often show only when warm.
5. Photograph the screen, then quit from the Pocket's menu (not by holding the power button): the
   results file is written when leaving the core.
6. Do the same with **MemTest7**.

### What you see

Five bands, one per test, numbered on the left, on a 320 x 224 screen:

| Colour | Meaning |
|---|---|
| **Green** | Passed at least once and has never failed |
| **Yellow** | Running now, with no failure so far |
| **Grey** | Has not finished once yet (normal for a few seconds after starting) |
| **Red** | Failed at least once. It stays red |
| **Blue** | Band 4 only: it has its answer, and its title says which |

Good means: band 5 turns green within a second or two and stays green. Then bands 1 to 3 turn yellow in
turn, and green after it; band 4 turns blue. One band is yellow at any moment, and PASSES keeps counting up.
If the same band stays yellow with no change in its PASSES for over a minute, the core has hung: photograph
it. `SECONDS` keeps counting in that case, so a moving `SECONDS` does not tell you it is fine.

| Band | Test | Takes |
|---|---|---|
| 1 | Both PSRAM chips, both dies, every word, walking and random patterns | about 12 s |
| 2 | The SDRAM, all 64 MB in 4-word bursts, then data left alone for over 5 seconds and read back. All the time, refresh commands are counted and timed | about 14 s |
| 3 | All the memory clients at once at the real rates, checking data and the video deadlines | about 1.5 s |
| 4 | A question, not a pass or fail: does an access to another address cancel the PSRAM's register sequence on word 3FFFFFh? | instant |
| 5 | The test file from the SD card, through the bridge and the loader. Once, at the start | instant |

Each band has two more lines, all in hexadecimal:

- `PASSES` and `ERRORS` are counts.
- `FIRST` is the first failing address. Its first digit says which part of the test failed, the rest is
  the byte address in the chip. `GOT` is what was read and `EXP` what should have been.

| Band | First digit of FIRST |
|---|---|
| 1 | 0 CRAM0 walking, 1 CRAM0 random, 2 CRAM1 walking, 3 CRAM1 random |
| 2 | 0 bursts, 1 retention, 2 refresh gap (`GOT` is the gap, `EXP` the limit, in clocks) |
| 3 | 0 fix, 1 sprite, 2 68K, 3 Z80 |
| 4 | 0 CRAM0 die 0, 1 CRAM0 die 1, 2 CRAM1 die 0, 3 CRAM1 die 1. 4 if the dies disagree |
| 5 | 0 CRAM0, 1 CRAM1, 2 SDRAM |

At the top: `RD WAIT` tells which core this is, `SECONDS` is the run time (258 in hexadecimal is 10
minutes), `LOOPS` the full rounds, `OVF` must stay 0. At the bottom, `WORST` is the longest wait in clocks of each
video and CPU client; fix must stay at or under 17 and sprite at or under 1B (hexadecimal). `REFRESH` counts the
SDRAM refresh commands as they leave the controller, `MAX GAP` is the longest time between two of them, in clocks,
and must stay at or under 2F2 (7.8 us). Band 2 goes red if it does not. `MIXED LAST` is the most recent failure of
band 3 and the second it happened; the last eight, with what the other memory clients were doing, are in the results file.

**Band 4 answers a question, and both answers are fine.** Its title says `ABORTS` or `SURVIVES`, and `DIES` shows
which of the four dies survive, as a hexadecimal digit: 0 or F. `ABORTS` means an access to another address cancels
the chip's register sequence. `SURVIVES` means it does not, so the core will need a small guard around that word;
`FIRST`, `GOT` and `EXP` then show the die and what it returned. Either way, write down which one you saw. Band 4 is
red only if something does not add up: the dies disagree, the answer changes between loops, or the word
does not work as memory afterwards. On MemTest, a red band is a real problem. On MemTest7, a red band in 1, 3 or 5
may only be the answer to its question: that core breaks the data sheet on purpose.

No picture at all, or a Pocket error message, is also a result: write down the exact text.

### What to photograph

One photo of each core after at least 10 minutes, with the whole screen readable, and one more of any
red band as soon as you see it. If a band goes red early, note how many seconds in.

### The results file (optional, later, on a PC)

Each core leaves a file on the SD card, `Saves/ng/pocket-neogeo.MemTest/memtest.sav` and
`Saves/ng/pocket-neogeo.MemTest7/memtest.sav`. If they are not there, look under `Saves/ng/`. With a
copy of this repository and Python:

    python tools/check_memtest_save.py memtest.sav

It prints the same results, including the answer of band 4, and it checks a counting pattern in the file: `read lag: none` means that the way
the core answers the bridge's reads matches what the Pocket does, which save files will depend on.
`ALL GOOD` at the end means no failures. A file that says `FAIL` on the read lag still gives its results.

### Results

Tested in 2026-11 on one Pocket, from photos of the screen. Firmware: not recorded. The figures of the final build are under Results below.

First run, of an earlier build of MemTest (RD_WAIT 8), at 480 s and 22 loops: bands 1, 2 and 5 with no errors, band 4
showing that another address aborts the sequence, fix 0x15 and sprite 0x14 as in simulation, loader overflow 0. Band 3
showed one error: expected the fix word C951, got the word before it, at the start of the S ROM region. A cycle-exact
model of that build predicts this error exactly as a phantom fetch at the end of the test's mixed step, fixed since.

### How this was checked without hardware

`python tools/sim.py memtest` runs the test against models of the three chips with their data sheet timing,
through the real memory mux, with each sweep shortened to the ends of each die. Each test passes on good
memory and fails on an injected fault: flipped words at the top of each die, swapped burst words, data lost
during the retention wait, refresh stopped, late fix and sprite data, dies that disagree on the register sequence,
a byte-swapped and a corrupted test file. Every band is also run with chip models of both kinds, a sequence that
aborts and one that survives, from start-up and over several loops. `tools/check_memtest_save.py` read the save file that bench produced through a model of
the bridge's read timing. The timing of both cores is in the table below.

| Core | ALMs | M10K | 96 MHz setup, Slow 85C / Slow 0C / Fast 85C / Fast 0C | 96 MHz hold, worst | All clocks |
|---|---|---|---|---|---|
| MemTest (RD_WAIT 8) | 3,156 | 10 | +0.100 / +0.127 / +1.429 / +1.631 | +0.074 | met |
| MemTest7 (RD_WAIT 7) | 3,135 | 10 | +0.105 / +0.134 / +1.466 / +1.631 | +0.125 | met |

Static timing checks the delay from registers to pads, not the chip. By the budget in `pocket.sdc`,
RD_WAIT 8 covers tAA with 1.25 ns spare (82.72 ns against 81.47, with the wider window `synth/memtest/memtest.sdc`
gives this top) and RD_WAIT 7 misses it by 9.09 ns (72.38 ns against 81.47), though most of that budget is worst-case
pad delay and assumed flight. So
"met" says nothing about whether MemTest7 reads correctly: only the Pocket can.

## Results

Build 493a551, one Analogue Pocket, 2026-11-01. Both cores report `ALL GOOD` from the save file checker.

| Core | Seconds | Loops | Errors, all rows | Worst fix / sprite / 68K / Z80 (clocks) | Largest refresh gap (limit 754) |
|---|---|---|---|---|---|
| MemTest (`RD_WAIT` 8) | 786 | 29 | 0 | 21 / 20 / 20 / 40 | 728 |
| MemTest7 (`RD_WAIT` 7) | 1200 | 45 | 0 | 18 / 20 / 18 / 37 | 728 |
| MemTest6 (`RD_WAIT` 6) | 1933 | 75 | 0 | 17 / 20 / 16 / 34 | 728 |

- The 3FFFFFh sequence is aborted by an access to another address on all dies, so no guard is needed.
- The bridge read lag check passes, and saves are written to `Saves/ng/<core>/`.
- The single row 3 error in the earlier build repeated on a second run with the same address and values, and was gone in this build, which fixed the end-of-step faults in the test.

One unit at room temperature, so `RD_WAIT` 7 passing does not make it safe across units: it still misses tAA on paper.

## Loader checks for the first real core run

Most of these were checked on hardware through the checklist below (lines d, g, i, j, k, q, r and s). Not checked: the RTC and the clock holding the time of boot (line l), and a BIOS reload.

- RTC: in an MVS game or UniBIOS clock screen the date, time and weekday must match the Pocket's. The core takes the date word as `0xYYYYMMDD` and the time word as `[27:24]` weekday, `[23:0]` `0xHHMMSS`, and adds 1 to the weekday for the uPD4990. Analogue's page lists the weekday bits without saying which word holds them or which day is 0. A wrong weekday alone means the weekday mapping; a wrong date or time means the words.
- The clock holds the time of boot: the host sends it once and the core does not count it on.
- Memory card and backup saves survive a power cycle. The core answers bridge reads as the memory test did, whose save file showed no read lag.
- Persisted AES: set MVS/AES to AES, power cycle, load a game. Then, with a game running, change MVS/AES from the menu both ways. Analogue's docs restore persistent values on boot immediately before Reset Exit (0x0011), after the slots, and no game JSON writes this setting, so the change never lands during a load: the PLL relocks with the ROMs already in, and the memories go through `MEM_INIT` (`~locked`). All ROMs must come through it intact: sprites, fix, sound and P ROM. This relock is AES's normal path; lines i and j passed it on hardware. A game wrong only in AES mode, or only after a change, points here.
- Reset Core and a BIOS reload restart a running game with correct sprites and sound, and the ROM masks stay.
- The menu shows the core's state: MVS on first boot, the PAL, width and scaler choices as set, and changing the scaler keeps the width. Opening the menu does not reset the game.
- The core shows up and loads with an empty `url` in `core.json`: the docs give only a maximum length, and no other core here has an empty one.
- `prom1`: Garou, KOF 99, KOF 2000, KOF 2003, Metal Slug 3 boot past the P ROM check with `prom1` at 0x800000.

## Hardware test 1: the real core

Run in 2026-11 on one Pocket. The checklist holds what was reported for each line; line l was not checked.

### What to copy

1. Take the SD card out of the Pocket and put it in a computer.
2. Unzip `dist/pocket-neogeo.NeoGeo_0.1.0.zip` to the root of the card, merging folders, not into a folder of its
   own. It adds:
   - `Cores/pocket-neogeo.NeoGeo/`, the core
   - `Assets/ng/pocket-neogeo.NeoGeo/`, the game list: the JSON set terminator2k2 and Timothee Groleau made for the Overdrive
   - `Platforms/ng.json` and its image. If the card already has them, overwriting is fine.
3. The zip holds no ROMs. In `Assets/ng/common/` the card needs, as for the Overdrive:
   - `uni-bios_4_0.rom`, `000-lo.lo`, `sfix.sfix`
   - one folder per game in the Darksoft layout: `mslug/` with `srom`, `prom`, `crom0`, `m1rom`, `vroma0`, and `prom1` if the game has one. The folder name is the `data_path` of its JSON.
   If you already have these for the Overdrive, nothing needs copying.
4. Put the card back in the Pocket. On the Pocket: **openFPGA**, **Neo Geo**, and pick this core if it lists several. It asks for a game: pick one from the list.

Keep `Mazamars312.NeoGeo` or `Mazamars312.NeoGeo_Overdrive` on the card: the slowdown and picture checks compare against it. If it is the Overdrive, turn "CPU 24mhz PCN Turn On" off for the slowdown check. Saves of the two cores do not mix (see `README.md`).

### Checklist

Write pass or fail, and for a fail what you saw. A photo helps.

| # | Check | Result |
|---|---|---|
| a | UniBIOS menu with no game running (UniBIOS test mode or menu reached, picture and text right) | pass: UniBIOS menu reached with a game loaded. `data.json` makes the game slot required, so a start with no game may be impossible on the Pocket; `test_start_without_game` covers the loader |
| b | Metal Slug: attract mode, play 2 minutes, sound | pass: all of level 1 with no faults, sound good, some slowdown in sprite-heavy places (see h) |
| c | KOF '98: character select sprites, music | pass at first look, on the `RD_WAIT` 7 test build; character select and music not confirmed |
| d | Garou: large sprites, no slowdown in stage 1. Also shows `prom1` at 0x800000 works | pass, reported good, on the `RD_WAIT` 7 test build, so `prom1` works |
| e | Art of Fighting 1: title sprites correct (a known fault of the Overdrive) | pass on the `RD_WAIT` 7 test build, no sprite fault seen. The reference core showed none either, so this shows no improvement over it |
| f | MVS to AES and back from the menu, PAL on and off | pass, by lines j and n |
| g | Memory card: save in a game, power the Pocket off and on, the save is there | pass on the `RD_WAIT` 7 test build: Metal Slug 3 saves to the memory card and reads it back after a power cycle, as on `Mazamars312.NeoGeo`; a UniBIOS setting also survived a power cycle |
| h | Slowdown: Metal Slug 2 or X in a heavy scene, same scene against the Overdrive. Say which feels slower | pass, by feel: Metal Slug 1, level 1, against `Mazamars312.NeoGeo` 0.8.1 (2023-01-17), no overclock: `RD_WAIT` 8 slower, 7 and 6 very close, that core between them, no faults. The core then built 7 and now builds 8 (see below). Metal Slug 2 or X not yet compared |
| i | Persisted AES: set AES, power cycle, load a game: sprites, fix, sound and P ROM all right | pass, reported working, on the `RD_WAIT` 7 test build |
| j | MVS/AES change from the menu with a game running, both ways: the game restarts, nothing corrupt in sprites, fix or sound | pass, both ways, no sound glitch, on the `RD_WAIT` 7 test build |
| k | Reset Core from the menu keeps the game: it restarts with correct sprites and sound, without reloading | pass, reported working, on the `RD_WAIT` 7 test build |
| l | RTC: in an MVS game or the UniBIOS clock screen, date, time and weekday match the Pocket's. A wrong weekday alone means the weekday mapping; a wrong date or time means the words | not checked: no clock screen found in the UniBIOS menu. The weekday word stays inferred |
| m | Picture position against the Overdrive: same game, same screen. This core is expected about 2 pixels to the right | pass: no difference noticed against `Mazamars312.NeoGeo` |
| n | PAL picture: centred vertically, 16 lines cut at top and bottom, no flicker | pass, on the `RD_WAIT` 7 test build: the game slows slightly when PAL is on, no restart, as MiSTer. Centring not checked separately |
| o | P2 coin: a second controller's Select gives a P2 credit | pass in the dock, on the `RD_WAIT` 7 test build |
| p | Z80 and sound: music keeps time and no sound test crashes, in two or three games. The real Z80 core runs for the first time here (see below) | pass, reported good, on the `RD_WAIT` 7 test build |
| q | 304 wide setting: no garbage at the edges, and changing the scaler keeps the width | pass, reported working, on the `RD_WAIT` 7 test build |
| r | Opening the menu does not reset the game, and the menu shows the core's state (MVS on first boot, PAL, width, scaler as set) | pass on the `RD_WAIT` 7 test build |
| s | The core shows up and loads with the empty `url` in `core.json` | pass: the test builds, with the same empty `url`, show up and load |

Other games reported good, on the `RD_WAIT` 7 test build: Metal Slug 3 (SMA, CMC), SVC Chaos (PVC), KOF 2003 (PVC), Samurai Shodown V (one fight played), Samurai Shodown V Special (64 MB of C ROM, one round played), The Super Spy (logo shown on 3 of 3 starts, a known intermittent fault of the Overdrive), Metal Slug X (first mission finished, some slowdown, not yet measured).

Final build `pocket-neogeo.NeoGeo` (`RD_WAIT` 7, bitstream SHA-256 of the `.rbf` 50a4210a6dc26157): Metal Slug X, first mission finished, performance similar to the test build, no glitches.

The release then moved to `RD_WAIT` 8 with the Z80's word buffer, on the wait counter's numbers below (`.rbf` 2663b38659db3d35). The lines above ran on `RD_WAIT` 7. Metal Slug X, first mission, was played twice on the debug build of this configuration: sound good, no faults.

Re-test of this exact release build (`RD_WAIT` 8 with `READY_COMB` and the Z80 word buffer, `.rbf` 2663b38659db3d35) by the owner on one Pocket, 2026-11-02. All pass: Metal Slug 3, memory card save and read-back after a power cycle; KOF '98; Garou; Samurai Shodown V Special, two fights; The Super Spy; Art of Fighting 1 jukebox, several songs with stereo; MVS/AES change both ways; Reset Core. KOF '98 and The Super Spy were reported only as "ok", with no more detail. Metal Slug 3's slowdown feels close to the earlier `RD_WAIT` 7 test build, by feel only, not measured.

Firmware: not recorded. Tested in 2026-11; the re-test of the release build was on 2026-11-02.

### The 68K wait counter on a real game

Metal Slug X, first mission, one play on each debug build, read with `tools/check_wait_save.py`.

| | `NeoGeo8Wait` (`RD_WAIT` 8) | `NeoGeoWait` (`RD_WAIT` 7) |
|---|---|---|
| Frames | 15,701 | 17,836 |
| 68K clocks lost | 2.019% | 2.068% |
| Worst frame | 3.779% | 3.673% |
| ROM zone reads that took a wait state | 12.73% | 12.89% |
| Share of the loss: fix / Z80 | 31.09% / 68.91% | 30.98% / 69.02% |

Each read that finds CRAM0 busy costs one wait state, 4 68K clocks, on both builds. A read that finds it idle costs none. `RD_WAIT` 7 gives the 68K no measurable gain over 8, and one play of each cannot separate a difference this small from how each play went.

The Z80's word buffer (`Z80_WORD_BUF`, build `neogeo8_zbuf`, `NeoGeoZ80Buf`) keeps the last M1 word, so a read of its other byte takes no CRAM0 access. Same mission, one play, `RD_WAIT` 8, against `NeoGeo8Wait`:

| | Without | With the buffer |
|---|---|---|
| Frames | 15,701 | 12,672 |
| 68K clocks lost | 2.019% | 1.354% |
| Worst frame | 3.779% | 2.295% |
| ROM zone reads that took a wait state | 12.73% | 8.28% |
| Reads per frame that found the Z80 on CRAM0 | 2,821 | 1,675 |
| Reads per frame that found the fix on CRAM0 | 1,273 | 1,071 |

`python tools/sim.py top` shows 2.100% against 0.002% for the same change. Its program is a short regular loop and says nothing of the size of the gain in a game; only the counter above does.

### The build

`python tools/build.py neogeo`, Quartus 25.1 Lite, 5CEBA4F23C8: 8,704 ALMs of 16,600 budget, 272 M10K of 292, 5 DSP. All clocks are met at all four corners. Slack in ns:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.259 | +0.279 | +1.536 | +1.682 | +0.430 | +0.414 | +0.176 | +0.162 |
| CLK_48M | +0.947 | +0.847 | +4.195 | +4.604 | +0.265 | +0.109 | +0.136 | +0.090 |
| CLK_PIX | +6.078 | +6.224 | +8.008 | +8.271 | +0.421 | +0.364 | +0.144 | +0.105 |
| dram_clk | +1.956 | +1.941 | +2.449 | +2.461 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +4.501 | +4.778 | +8.930 | +9.173 | +0.360 | +0.344 | +0.148 | +0.077 |
| bridge_spiclk | +9.861 | +10.106 | +11.454 | +11.676 | +0.538 | +0.561 | +0.210 | +0.201 |

Thinnest hold of the build: +0.077, on clk_74a at Fast 0C.

### What simulation showed, and what it did not

`python tools/sim.py top` runs the real top with the real 68000 core against models of the three chips. It cannot show anything about real chips, real games or the Pocket's scaler, and its small program is not a BIOS. The Z80 in that bench is a small model, as the real one (T80) is VHDL and the simulator reads only Verilog: real Z80 instruction timing and any game's sound driver are first exercised by lines b, c and p above.

## Milestone 2: the CD core

### Task 3: first fit of the CD top

`python tools/build.py neogeocd` (RD_WAIT 8, `READY_COMB`, no Z80 word buffer), Quartus 25.1 Lite, 5CEBA4F23C8, with `cd_sys`, the `cdd_drive` stub, 64 KB of Z80 RAM in block RAM and no disc path: 8,893 ALMs of 16,600 budget, 275 M10K of 292, 5 DSP. All clocks are met at all four corners. Nothing here ran on a Pocket.

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.276 | +0.294 | +1.537 | +1.683 | +0.463 | +0.465 | +0.176 | +0.124 |
| CLK_48M | +0.103 | +0.320 | +5.183 | +5.678 | +0.293 | +0.188 | +0.135 | +0.103 |
| CLK_PIX | +5.749 | +6.007 | +7.833 | +8.114 | +0.471 | +0.413 | +0.146 | +0.105 |
| dram_clk | +1.952 | +1.936 | +2.447 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +5.380 | +5.462 | +9.456 | +9.670 | +0.477 | +0.465 | +0.178 | +0.167 |
| bridge_spiclk | +10.748 | +10.856 | +12.400 | +12.490 | +0.500 | +0.528 | +0.212 | +0.201 |

Thinnest setup: +0.103, CLK_48M at Slow 85C, against +0.947 in the cart. The worst paths start on CLK_96M, in the mux's `c0_owner` and `dq_in`, and end through `READY_COMB`'s `PROM_DATA` and the 68K bus on `neo_sma`, `jt10` and, new in this build, the Z80 RAM's data inputs. Thinnest hold: +0.103, CLK_48M at Fast 0C.

`python tools/sim.py topcd`, the 68K's cost at this point. A bus cycle with no wait state keeps `nAS` low for 10 CLK_48M, measured with the real fx68k, and lost clocks are `len - 10`. Over the program's PROG phase, a 1,024 word copy: 90,336 CLK_48M with 2,823 fix reads, 0 lost, 0.00%, limit 25%. PROG RAM reads `len` 10 on average and at worst, `rdy` 9. PROG RAM writes `len` 10 on average and at worst.

That says little about the chip's real cost. `sim/topcd` is phase locked with the fix, 68K requests landing 14, 30, 46 or 62 CLK_96M after a fix request, and its Z80 has its own RAM, so there is no Z80 on CRAM0: it shows almost no contention. `sim/mem`, at random alignment, is the pessimistic bound: `rdy` 20. Only the wait counter on hardware gives the real loss.

### Task 5: size of the CDD drive

`quartus_map neocd_delta -c cdd_drive`, Quartus 25.1 Lite, 5CEBA4F23C8, map only, each module standalone with its ports as pins. `cdd_tick` is measured by pointing the revision's top at it for one run.

| Module | Combinational ALUTs | Registers | ALMs (estimate) | DSP | M10K |
|---|---|---|---|---|---|
| `cdd_drive` | 1,379 | 298 | 892 | 0 | 0 |
| `cdd_tick` | 43 | 20 | | 0 | 0 |
| Total | 1,422 | 318 | | 0 | 0 |

Under the plan's 1,500 ALUTs, and under the 2,232 ALUTs and 10 DSP of the Pocket Mega CD drive. Its multiplies and divides are sequential, on one register and a table of constants, so there is no multiplier. This is not a fit, so the timing of `CLK_48M`, at +0.103 at Task 3, is not measured with this body yet.

### Task 10: FIX, SPR and PCM RAM, the cartridge chips out

`python tools/build.py neogeocd`, Quartus 25.1 Lite, 5CEBA4F23C8, with the real `cdd_drive`, FIX RAM in the SRAM through `cd_fix_sram`, SPR RAM in the SDRAM, PCM RAM in CRAM1 and the cartridge-only chips compiled out: 9,050 ALMs of 16,600 budget, 258 M10K of 292, 5 DSP. All clocks are met at all four corners. There is still no disc path, and nothing here ran on a Pocket.

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.274 | +0.264 | +1.535 | +1.687 | +0.482 | +0.476 | +0.174 | +0.132 |
| CLK_48M | +0.720 | +0.783 | +4.287 | +5.005 | +0.278 | +0.167 | +0.134 | +0.071 |
| CLK_PIX | +6.758 | +6.851 | +8.335 | +8.548 | +0.449 | +0.377 | +0.171 | +0.110 |
| dram_clk | +1.953 | +1.938 | +2.448 | +2.459 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +4.445 | +4.754 | +9.213 | +9.551 | +0.360 | +0.359 | +0.165 | +0.149 |
| bridge_spiclk | +10.735 | +10.962 | +12.262 | +12.389 | +0.500 | +0.511 | +0.182 | +0.171 |

Thinnest setup: +0.264, CLK_96M at Slow 0C. `CLK_48M`, at +0.103 at Task 3, is now +0.720. Thinnest hold: +0.071, `CLK_48M` at Fast 0C. The SRAM's pins, by `pocket.sdc`'s windows, worst of four corners: pad to `rdata` setup +2.231 and hold +0.160, register to pad setup +7.315 and hold +2.942.

What tying `xram`, `ms5p_bank`, `cart_pchip`, `cart_chip` and `cmc_chip` to 0 freed, by the fit's entity table against Task 3's:

| Entity | ALMs at Task 3 | ALMs now | M10K at Task 3 | M10K now |
|---|---|---|---|---|
| `neo_cmc` | 238.7 | gone | 0 | 0 |
| `neo_sma` | 107.3 | gone | 0 | 0 |
| `neo_pvc` | 81.2 | 5.5, what is left of the 68K bus mux under its name | 8 | 0 |
| `XRAML`, `XRAMU` | 0 | gone | 8 | 0 |
| `ZMC2DOT` | 25.7 | gone | 0 | 0 |
| `COM` | 1.0 | gone | 0 | 0 |
| Total | 453.9 | 5.5 | 16 | 0 |

448 ALMs and 16 M10K. `neo_273` stays, at 6.3 ALMs: it is the `S_LATCH` and `C_LATCH` of every build, cart or CD. The total M10K moved from 275 to 258: those 16, and the CD write queue, 1 M10K at Task 3, now in registers, as its 41 bits would have taken 2.

`python tools/sim.py mem`, on the 55 ns SRAM model: a fix read reaches `SROM_DATA` 13 clocks of CLK_96M after PCK2 falls on a `CLK_48M` edge, 14 off one, against `FIX_DEADLINE`'s 23. `python tools/sim.py topcd`, with the real core: 13 at worst over 329,888 reads. The 68K there, with the fix off CRAM0: every PROG RAM read and write in 10 clocks of `CLK_48M` of `nAS` low, no wait state, ready 9 clocks of CLK_96M after the strobe, and nothing lost in the PROG phase. A FIX write by the CPU costs 18 to 22 clocks of `nAS`, as it holds DTACK until it is in the chip. These bench numbers have no Z80 on CRAM0, which is this core's real case; `sim/mem`'s stress case with one, worst `rdy` 20, is not it.

DMA writes in `sim/mem`, one word per 35 clocks, 5.53 MB/s of SPR and 2.76 MB/s of PCM. SPR, with the sprite client at full rate, which the core itself does not do as `CD_USE_SPR` turns it off for an upload: `DMA_SDRAM_BUSY` 16.1% of the time, no word stalled the engine, sprite worst 26 clocks against 27, no miss. A SPR write reaches the chip 15 clocks after its edge at worst, against a read's edge at 24. PCM, with ADPCM-A at its rate: 32.3%, no stall, ADPCM-A worst 21 against 128.

The cart. Fitted before the fix below: `python tools/build.py neogeo`, 8,736 ALMs, 272 M10K, thinnest setup +0.259 and hold +0.064, all met, against 8,695 ALMs for the commit before this task. CD logic did survive in it: its registers were found stuck too late, so `prom_data_r` kept a 3-input mux and `c1_owner` synthesised with 4 states. The mux now has a `CD_BUILD` parameter, and a condition on it goes at elaboration. `quartus_map neogeo` against that commit, `ad30db5`:

| | ad30db5 | Now |
|---|---|---|
| Combinational ALUTs, whole core | 13,969 | 13,969 |
| Registers, whole core | 8,067 | 8,067 |
| Mux's own ALUTs and registers | 463 and 371 | 463 and 371 |
| Mux's state machines | `c1_owner` with 3 states | the same |
| Mux restructuring table | | the same |

The only difference left is the generated names of two `altshift_taps`, which swap. Gating on `SYSTEM_CDx` alone, as a first attempt, left the mux at 483 ALUTs with an `fx_owner` state machine. Renaming a signal in `ad30db5` gives an identical report, so these reports do not move for no reason. The cart is compared by synthesis, as the owner has ruled, not by fitted ALMs. Both builds' fits above predate this fix; the next build measures them.

`sim/topcd`'s `test_dma_pcm`: a DMA from PROG RAM into the PCM window, by microcode F2DD as `UploadPCMDMABytes`, read 00 for every byte, where the source held A1 B2 C3 D4. That is MiSTer's: `TR_ZONE` in `cd.sv` looks at `DMA_ADDR_OUT` alone, so `CD_TR_RD_PCM` is up with `CD_EXT_RD`, and `DMA_DATA_IN` takes `ADPCMA_DOUT`. Fixed in the top, tagged `POCKET`, to report upstream. The test now passes.

### Tasks 4 and 6: the three builds of the milestone

`python tools/build.py neogeocd`, `neogeocd_wait` and `neogeo`, one run each, in parallel, Quartus 25.1 Lite, 5CEBA4F23C8. All three meet timing at all four corners and the budget. Nothing here ran on a Pocket.

| Build | RD_WAIT | ALMs of 16,600 budget | M10K of 292 | DSP | `.rbf` SHA-256 (first 16) | Thinnest setup | Thinnest hold |
|---|---|---|---|---|---|---|---|
| `neogeocd`, `NeoMillieCD` | 8 | 9,025 | 258 | 5 | cf291ac7d21d54c1 | +0.274, CLK_96M, Slow 85C | +0.091, CLK_48M, Fast 0C |
| `neogeocd_wait`, `NeoGeoCDWait` | 8 | 9,792 | 259 | 5 | 7abfc9e5ed87d6f7 | +0.276, CLK_96M, Slow 85C | +0.053, CLK_48M, Fast 0C |
| `neogeo`, `NeoMillie` | 8 | 8,695 | 272 | 5 | 109abd1e332d73df | +0.276, CLK_96M, Slow 85C | +0.103, CLK_48M, Fast 0C |

Slack in ns, `neogeocd`:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.274 | +0.295 | +1.536 | +1.682 | +0.448 | +0.432 | +0.171 | +0.109 |
| CLK_48M | +0.903 | +1.126 | +4.219 | +4.558 | +0.284 | +0.160 | +0.132 | +0.091 |
| CLK_PIX | +7.183 | +7.246 | +8.707 | +8.861 | +0.436 | +0.408 | +0.147 | +0.101 |
| dram_clk | +1.953 | +1.938 | +2.448 | +2.459 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +5.629 | +5.776 | +9.545 | +9.649 | +0.396 | +0.379 | +0.177 | +0.151 |
| bridge_spiclk | +11.180 | +11.367 | +12.596 | +12.677 | +0.507 | +0.509 | +0.212 | +0.200 |

`neogeocd_wait`:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.276 | +0.295 | +1.534 | +1.680 | +0.466 | +0.433 | +0.179 | +0.142 |
| CLK_48M | +0.621 | +0.716 | +4.074 | +4.456 | +0.272 | +0.161 | +0.082 | +0.053 |
| CLK_PIX | +6.529 | +6.746 | +8.148 | +8.411 | +0.483 | +0.438 | +0.149 | +0.107 |
| dram_clk | +1.952 | +1.936 | +2.447 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +5.520 | +5.523 | +9.561 | +9.676 | +0.384 | +0.373 | +0.176 | +0.155 |
| bridge_spiclk | +10.377 | +10.494 | +12.147 | +12.291 | +0.546 | +0.546 | +0.183 | +0.170 |

`neogeo`, the cart:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.276 | +0.295 | +1.534 | +1.680 | +0.464 | +0.467 | +0.176 | +0.167 |
| CLK_48M | +0.902 | +0.750 | +4.266 | +4.578 | +0.292 | +0.146 | +0.134 | +0.103 |
| CLK_PIX | +6.558 | +6.740 | +8.362 | +8.572 | +0.408 | +0.387 | +0.172 | +0.119 |
| dram_clk | +1.952 | +1.936 | +2.447 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +4.825 | +4.872 | +8.983 | +9.246 | +0.387 | +0.377 | +0.178 | +0.160 |
| bridge_spiclk | +10.482 | +10.745 | +12.191 | +12.328 | +0.528 | +0.540 | +0.185 | +0.177 |

The CLK_48M worst path of `neogeocd`, setup at Slow 85C, +0.903 ns (it was +0.720 at Task 10): from `u_cram0|dq_in[8]` on CLK_96M, through `PROM_DATA[8]` (`READY_COMB`) and the 68K bus mux `F0|M68K_DATA[0]` and `SDD_OUT[0]`, to the data input of the work RAM `WRAMU` (a M10K block), data delay 8.07 ns against a 10.34 ns relationship, clock skew -1.25 ns. That is the CD core's own path, not the Z80 RAM's (`CD_TR_WR_Z80`), so the `set_false_path` of the plan has no cause to be written.

The cart, by synthesis against `ad30db5`: `quartus_map neogeo` gives 13,969 combinational ALUTs and 8,067 registers, the same as `ad30db5`. The fitted ALMs, 8,695, are 9 below the 8,704 of hardware test 1; M10K is 272 as before. ALMs vary with the fitter and are not a failure.

The wait counter's cost: its entity is 675 ALMs in `neogeocd_wait` and 613 in `neogeo_wait`. The CD file's extra words (the last CDD command and status, the drive state, five counts, `disc_bin_size`) are the 62 ALMs of the difference and no M10K; the one M10K of `neogeocd_wait` over `neogeocd` is the counter's copy RAM, which the cart's counter has too.

### Gate: PROG RAM in CRAM0

Decision 2 keeps PROG RAM (2 MB) in CRAM0, behind the 68K's reads. This gate measures what that costs the 68K on the Pocket, with the wait counter of the cart builds (`rtl/test/wait_counter.sv`, file layout 2). The CD build counts the 68K's cycles in the BIOS and PROG RAM only, `nSROMOE`, `nROMOE`, `nPORTOE`, `CD_EXT_RD` and `CD_EXT_WR`; the holds of FIX, SPR and PCM transfers are not counted, and the thresholds are for this zone. A bus cycle of it with no wait state keeps `nAS` low for 10 CLK_48M, reads and writes alike (measured with the real fx68k in `sim/topcd`); a TAS on PROG RAM is 34 and counts 24 lost clocks, so a BIOS that uses it there adds to the loss (the bench's program has three). Code 0 of the arrival table is the CD write queue; codes 2 and 3 never happen in the CD build, and a count there is a fault. A write has no 68K read request of its own, so it is filed under the code of the last read: the totals and the worst frame are exact, the split by code is not for writes.

RD_WAIT 8 only: the owner decided not to build `neogeocd7` and `neogeocd6`, and to run no delivery check at RD_WAIT 7. On the cart, 7 gave the 68K no measurable gain over 8 (the wait counter's table above).

Simulation, step 1. `python tools/sim.py topcd` at HEAD, RD_WAIT 8 and the 70 ns PSRAM model, with the fix reading the SRAM and the Z80 on its own RAM. `lost` is `len - 10`.

| Class | Cycles | `len` average | `len` worst | `rdy` worst, CLK_96M | Lost | Threshold |
|---|---|---|---|---|---|---|
| BIOS read | 569,520 | 10.00 | 10 | 9 | 0 | |
| PROG RAM read | 42,000 | 10.00 | 10 | 9 | 0 | `len` average at most 14, `rdy` at most 20 |
| PROG RAM write | 5,036 | 10.00 | 10 | | 0 | `len` average at most 14, worst at most 20 |
| FIX write (not counted) | 64 | 18.12 | 22 | | 520 | |
| The program's PROG phase | 90,336 CLK_48M | | | | 0 (0.00%) | at most 25% |

Inside every threshold. `sim/topcd` is phase locked with the fix and has no Z80 on CRAM0, so this is the optimistic end; `sim/mem`'s `rdy` of 20 at random alignment is the pessimistic one. Only the counter on hardware gives the real loss.

The counter against the bench, `python tools/sim.py topcd` with `+define+NEOGEO_WAIT_COUNTER`, run twice, early and at the end (`test_wait_counter`): the total, the cycles and the lost clocks by code are exactly the bench's own count, and the file read through the bridge (and the slot write of 256 bytes to slot 0x103) agrees to within the clocks of the copy. Five mutations each made it fail: dropping `CD_EXT_WR` from the zone, dropping `CD_EXT_RD`, forcing the arrival code to 0, `IDEAL_LEN` 11 for 10, and counting FIX writes on the SPR strobe. The cart's `tb_top` with the same define passes with its checks unchanged.

Hardware, step 3, the owner. Cores: `NeoGeoCDWait` for every line here. Copy `dist/uniplexed.NeoGeoCDWait_0.2.0-gate.zip` to the root of the SD card, merging folders. `Assets/ngcd/common/` needs `000-lo.lo` and the BIOS files `top-sp1.bin`, `neocd.bin`, `front-sp1.bin`, `uni-bioscd.rom`. No disc is mounted, so each BIOS shows its no-disc screen.

1. On the Pocket: **openFPGA**, **Neo Geo CD**, **NeoGeoCDWait**; pick `top-sp1.bin` when it asks for a BIOS. [a]
2. Let it sit at the screen it reaches for 3 minutes, then leave the core with **Quit** (not by switching the Pocket off), so the save is written. [b]
3. Put the card in a PC, take `Saves/ngcd/uniplexed.NeoGeoCDWait/wait.sav` (look under `Saves/` if it is not there), and run `python tools/check_wait_save.py wait.sav`. It must print FILE GOOD. [b]
4. Write down "Lost ... % of all 68K clocks" and "worst frame ... %". [b]
5. Repeat 1 to 4 with `neocd.bin`, then with `uni-bioscd.rom`; each time Quit, and keep each `wait.sav` under its own name. [c]
6. Paste the three outputs back: besides the percentages, the `CD drive:` line and the line below it say how far the BIOS got.

| # | Check | Result |
|---|---|---|
| a | `NeoGeoCDWait` with `top-sp1.bin`, no disc: the BIOS reaches its menu or CD player screen | not run |
| b | The wait counter's readout at that screen: the lost percentage on average and in the worst frame | not run |
| c | The same with `neocd.bin` and with `uni-bioscd.rom` | not run |

Thresholds, the owner's: at most 2% of the 68K's clocks lost on average and at most 4% in the worst frame passes. Between 2% and 5% the owner judges by play. Above 5%, try the backlog's read buffer, then reopen PROG RAM's place (the alternative is SDRAM behind the sprite fetch, as MiSTer's map). The same readout is taken again in Metal Slug CD level 1 (Task 12).

What the owner may see when a line fails, and what it points at:

| What you see | What it points at |
|---|---|
| Black screen, no video | PLL, reset, the 68K not fetching from CRAM0 |
| The logo without text, or garbage text | The FIX upload to the SRAM, or `CD_USE_FIX` |
| Text, but no logo sprites | SPR RAM, the DMA, `DMA_SDRAM_BUSY` |
| The logo, but no sound | Z80 RAM, PCM RAM, the T80 |
| Stuck on the logo | The CDD exchange, CRC, interrupt 22 |
| The menu, then a hang on the card manager | The 8 KB memory card |

In `wait.sav` the `CD drive:` line shows these without a screen: the last CDD command and status words, the drive state and LBA, and the counts of CDD exchanges and of writes to the transfer area (FIX, SPR, PCM, Z80). No CDD exchange at all points at the drive's interrupt; no FIX writes at the FIX upload.

Decision line: not decided. The gate waits for the owner's hardware run above; nothing after it starts until then.

Result, 2026-11-03, `NeoGeoCDWait`, `top-sp1.bin`, no disc, about 4 minutes at the BIOS's screen (FILE GOOD): 13,890 frames, 638,301,928 BIOS and PROG RAM cycles, **0 lost clocks, 0.000%**, worst frame 0, every cycle arriving with CRAM0 idle. Last CDD command `A000000000`, status `D00020000B`, drive state 0, 589 exchanges modulo 1,024, transfer writes 0 FIX, 0 SPR, 0 PCM, 688 Z80, each modulo 1,024.

**Decision: pass at the BIOS's screen (limit 2% average, 4% worst frame). PROG RAM stays in CRAM0.** This is an idle BIOS, with no disc and no DMA: Task 12 (f) re-checks it in a game. Three FIX, SPR and PCM counts of 0 with text on screen: see "The FIX count of the gate" under milestone 3. They don't touch the lost clocks.

`NeoGeoCDWait` did not list on the Pocket with version `0.2.0-gate` and a 68-character description, and did with `0.2.0` and 54 characters, edited on the card. The cart's wait cores listed with 75-character descriptions, so the version's suffix is the likely cause, not proven.

Reading the file:

- Take `wait.sav` off the card before the next BIOS: a run that fails before its first save, about 7 s in, leaves the previous file, which still reads FILE GOOD.
- "last error 2" is normal: the cart's accepted files show it too. The file comes from the read at Quit.
- The worst frame includes the boot, whose PROG RAM and FIX writes can pass 4% with a low average. Read the two together, and repeat before deciding the gate on a high worst frame alone.
- The CD counts wrapped at 1,024 in the build of this test. Milestone 3 explains the zeros and widens them.
- A TAS on PROG RAM counts 24 lost clocks, so a BIOS that uses it often reads slightly higher.
- The file browser should start in `Assets/ngcd/common/`, and a BIOS file not of exactly 524,288 bytes is refused. This core is the first with a browsed BIOS here: say what the Pocket does.

### Hardware test 2

The CD BIOS boots with an empty drive. Cores: `NeoMillieCD` for lines a to h, and `NeoMillie` (the cart core) for line j. Copy `dist/uniplexed.NeoMillieCD_0.2.0.zip` and `dist/uniplexed.NeoMillie_0.2.0.zip` to the root of the SD card, merging folders; the cart core keeps its BIOS and games in `Assets/ng/common/` as in hardware test 1. For the CD core `Assets/ngcd/common/` holds `000-lo.lo` and four BIOS files, `top-sp1.bin`, `neocd.bin`, `front-sp1.bin`, `uni-bioscd.rom`; discs go there later. No disc is mounted in this test, so a BIOS shows its no-disc screen. Leave each core with **Quit**, so the memory card and settings are written.

1. **openFPGA**, **Neo Geo CD**, **NeoMillieCD**: it lists and launches, and asks for a BIOS. [a]
2. Pick `top-sp1.bin`: it reaches its no-disc screen. [b]
3. Quit, start again with `neocd.bin`, and then with `front-sp1.bin`: the same. [c]
4. Quit, start with `uni-bioscd.rom`: the same, and its menu can be reached. [d]
5. Menu, **Region**: US, EU, JP, AS; the BIOS language or logo changes (a reset may be needed). [e]
6. Menu, **CD/CDZ** on and off: the CDZ BIOS screen differs (the lid state is inverted on a CDZ). [f]
7. In the BIOS menu open the memory card manager, format the card, Quit, start again: the card is kept. [g]
8. Menu, **Lid open (debug)** on: the BIOS reports the tray open. [h]
9. Quit; **openFPGA**, **Neo Geo**, **NeoMillie**, Metal Slug level 1: it runs as in hardware test 1. [j]

| # | Check | Result |
|---|---|---|
| a | `Assets/ngcd/common/` holds `000-lo.lo` and the BIOS files; the core lists and launches | pass, reported by the owner, 2026-11-03 |
| b | `top-sp1.bin`: the no-disc screen, no disc | pass, reported by the owner, 2026-11-03 |
| c | `neocd.bin`, and `front-sp1.bin`: the same | pass, reported by the owner, 2026-11-03 |
| d | `uni-bioscd.rom`: the same, and its menu is reachable | pass, reported by the owner, 2026-11-03 |
| e | The region setting changes the BIOS language or logo | pass, reported by the owner, 2026-11-03 |
| f | CD/CDZ: the CDZ BIOS screen differs (lid state inverted on CDZ, `neogeo.sv:773`) | pass, reported by the owner, 2026-11-03 |
| g | The memory card manager in the BIOS menu formats a card and keeps it across a power cycle | pass, reported by the owner, 2026-11-03 |
| h | The lid debug setting open: the BIOS reports the tray open | pass, reported by the owner, 2026-11-03 |
| i | Removed: it was line b on `neogeocd7` and `neogeocd6`, which are not built (RD_WAIT 8 only, see the gate) | not applicable |
| j | The cart core `NeoMillie` still runs Metal Slug level 1 (unchanged RTL, rebuilt) | pass, reported by the owner, 2026-11-03 |

The failure table of the gate applies here too. Findings are fixed one commit each, with the observation in the message, and the lines are run again until a to h and j pass. The commit `feat(cd): milestone 2, the CD BIOS boots with an empty drive` and its tag `m2-cd-skeleton` wait for that; no line has been marked as passed.

## Milestone 3: a disc

### Task 11: the three builds

`cd_mount`, `cd_fetch` and `cd_host` are wired in: the CD data path is complete, and CD audio goes through the mix already there, with no muting. `python tools/build.py neogeocd`, `neogeocd_wait` and `neogeo`, one run each, in parallel, Quartus 25.1 Lite, 5CEBA4F23C8. All three meet timing at all four corners and the budget. Nothing here ran on a Pocket.

| Build | RD_WAIT | ALMs of 16,600 budget | M10K of 292 | DSP | `.rbf` SHA-256 (first 16) | Thinnest setup | Thinnest hold |
|---|---|---|---|---|---|---|---|
| `neogeocd`, `NeoMillieCD` | 8 | 11,614 | 281 | 5 | f023f042650ab059 | +0.271, CLK_96M, Slow 0C | +0.105, CLK_PIX, Fast 0C |
| `neogeocd_wait`, `NeoGeoCDWait` | 8 | 12,461 | 282 | 5 | 16a70067dae407a0 | +0.276, CLK_96M, Slow 85C | +0.046, CLK_48M, Fast 0C |
| `neogeo`, `NeoMillie` | 8 | 8,695 | 272 | 5 | 109abd1e332d73df | +0.276, CLK_96M, Slow 85C | +0.103, CLK_48M, Fast 0C |

Slack in ns, `neogeocd`:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.274 | +0.271 | +1.535 | +1.687 | +0.392 | +0.372 | +0.176 | +0.142 |
| CLK_48M | +0.748 | +0.793 | +4.550 | +4.837 | +0.292 | +0.283 | +0.136 | +0.119 |
| CLK_PIX | +7.379 | +7.478 | +8.843 | +8.977 | +0.450 | +0.394 | +0.150 | +0.105 |
| dram_clk | +1.951 | +1.934 | +2.446 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +2.867 | +2.170 | +9.124 | +9.410 | +0.360 | +0.351 | +0.163 | +0.151 |
| bridge_spiclk | +11.051 | +11.207 | +12.547 | +12.628 | +0.508 | +0.511 | +0.187 | +0.176 |

`neogeocd_wait`:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.262 | +0.285 | +1.533 | +1.680 | +0.461 | +0.446 | +0.177 | +0.167 |
| CLK_48M | +0.661 | +0.823 | +4.292 | +4.604 | +0.289 | +0.198 | +0.132 | +0.078 |
| CLK_PIX | +5.954 | +6.139 | +8.169 | +8.442 | +0.450 | +0.408 | +0.158 | +0.108 |
| dram_clk | +1.955 | +1.939 | +2.448 | +2.460 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +2.357 | +1.793 | +9.002 | +9.301 | +0.318 | +0.306 | +0.145 | +0.133 |
| bridge_spiclk | +10.831 | +10.888 | +12.550 | +12.615 | +0.371 | +0.355 | +0.173 | +0.159 |

`neogeo`, the cart:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.276 | +0.295 | +1.534 | +1.680 | +0.464 | +0.467 | +0.176 | +0.167 |
| CLK_48M | +0.902 | +0.750 | +4.266 | +4.578 | +0.292 | +0.146 | +0.134 | +0.103 |
| CLK_PIX | +6.558 | +6.740 | +8.362 | +8.572 | +0.408 | +0.387 | +0.172 | +0.119 |
| dram_clk | +1.952 | +1.936 | +2.447 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +4.825 | +4.872 | +8.983 | +9.246 | +0.387 | +0.377 | +0.178 | +0.160 |
| bridge_spiclk | +10.482 | +10.745 | +12.191 | +12.328 | +0.528 | +0.540 | +0.185 | +0.177 |

The cart: `quartus_map neogeo` gives 13,969 combinational ALUTs and 8,067 registers, the mux 463 ALUTs and 371 registers with `c1_owner` of 3 states, all as the commit before. M10K 272. Its bitstream's hash is the one in the milestone 2 table, so it is the same bitstream.

M10K: 281 against the plan's forecast of about 279. The first fit was 297, over: `cd_host` read and wrote the bank at two addresses on its clk_74a port, so Quartus made two RAMs of 10 blocks each. One address on that port makes one true dual-port RAM, 10 blocks, with all four prefetch slots. The TOC and the path buffers were in MLAB from the start. So neither of the owner's two steps was needed: the 3-slot bank was not taken.

Timing: the first fit also missed clk_74a by 0.300 ns at Slow 0C, on `cd_mount`'s multiply of the next CUE piece's offset feeding a subtract and a compare in one clock. That multiply is registered now, and clk_74a has +2.170. The CLK_48M hold moves with the fit: +0.031 at Fast 0C in the 0.3.0 `neogeocd`, +0.119 in this one, +0.046 in `neogeocd_wait`: met, but worth a look if a later fit goes negative.

ALMs: 2,589 up from 9,025 at milestone 2, of which `cd_mount` was 1,255, `cd_host` 338 and `cd_fetch` 326 before the pick's size. Under the budget by 4,986.

These are the 0.3.1 builds. 0.3.0 mounted a picked disc with the size in the data table; a review found the host's order of that word and its 0x8A command unknown, so a pick now uses the command's size (`apf_loader.sv`). 0.3.0 did not go to the card.

`sim/topcd` with a disc, at the host's real rate and 1 ms of latency: mounted 26.2 ms after `dataslot_allcomplete`; PLAY to the sector in PROG RAM 115 ms, and 137 ms with a host of 20 ms; a DMA word every 23 CLK_48M; a swap with a data read under way mounted in 46 ms (a swap during CD audio is not simulated yet). Simulation uses T80's model and no real BIOS, so none of this says what a real BIOS does.

### The FIX count of the gate

The gate's file showed 0 FIX, 0 SPR and 0 PCM writes with text on screen. `sim/topcd`'s program now uploads 32 FIX bytes by the 68K and 32 by DMA (microcode F2DD, as `UploadFIXDMABytes`), and the counter finds exactly 64 per run of the program; with the DMA path masked it finds 32 and the test fails. Each DMA word raises and drops the strobe, so a DMA counts word by word; the comment that said otherwise was wrong. **The counter misses no path.**

So the zeros were not real zeros. The FIX RAM has one writer, `CD_TR_WR_FIX`, and text on screen came from it: the count was a multiple of 1,024, which is what whole blocks give (128 KB of FIX is 131,072 writes). SPR and PCM at 0 say nothing either way. This is reasoning from the RTL, as no real BIOS has run in simulation; the next `wait.sav` shows the real numbers, as the counts are now 24 bits for FIX, SPR and PCM and 16 for the Z80 and the exchanges. The file also says why the last mount ended and how many sectors failed. `tools/check_wait_save.py` reads this layout only, so its count lines are wrong for a save from a core before 0.3.0, such as the one above.

### Hardware test 3

A disc loads and plays. Copy `dist/uniplexed.NeoMillieCD_0.3.1.zip`, `dist/uniplexed.NeoGeoCDWait_0.3.1.zip` and `dist/uniplexed.NeoMillie_0.3.1.zip` to the root of the SD card, merging folders. `Assets/ngcd/common/` keeps `000-lo.lo` and the BIOS files, and holds the discs, each made by `tools/cd_convert.py`: `Metal Slug/Metal Slug.cue` and `King of Fighters 97/King of Fighters 97.cue`, each with its BIN beside it. Leave each core with **Quit**, so the card and the counter's file are written.

1. **Core `NeoMillieCD`**, BIOS `top-sp1.bin`: pick it in `Assets/ngcd/common/`, not inside a game's folder. The BIOS slot lists `.bin` files but no `.cue`, and a game's BIN there gives "File ID 0 size bad". Then, in the Pocket's menu, on the **Disc** slot, pick `Metal Slug/Metal Slug.cue`. Time it from the pick. Expect "CHECKING DISC", then the game's logo. Write down the seconds, and whether the core restarted at the pick. If the BIOS stays on its no-disc screen, Quit and start the core again: the disc then mounts at boot. [a, i]
2. **`NeoMillieCD`**: leave the attract mode for 2 minutes. Expect it to run on, with picture and sound. [b]
3. **`NeoMillieCD`**: start the game, play level 1 for 2 minutes. Expect sprites and text right, sound effects and voices, and CD music. A music fault goes on the list and does not stop the test. [c]
4. **`NeoMillieCD`**: play on to the next load. Expect "loading", then the next part. [d]
5. **`NeoMillieCD`**: Menu, **Region**, then **CD/CDZ**, one change each, restarting the game after each. Expect the game to load each time. [g]
6. **`NeoMillieCD`**: Quit, start again, pick `King of Fighters 97/King of Fighters 97.cue`. Expect it to load, and a match to play. [e]
7. **`NeoMillieCD`**: with KOF '97 running, pick `Metal Slug/Metal Slug.cue`. Write down which happens: the core resets to the BIOS, which then loads Metal Slug; or no reset, the game stops or the BIOS takes over, and the disc reads after a Reset Core. Either is fine. A frozen Pocket menu, or a disc that never reads again, is not. [h]
8. **Core `NeoGeoCDWait`**, `top-sp1.bin`, Metal Slug, level 1 for 3 minutes, then Quit. On a PC, `python tools/check_wait_save.py` on `Saves/ngcd/uniplexed.NeoGeoCDWait/wait.sav`. Expect FILE GOOD, "Lost" at most 2% and the worst frame at most 4%. Keep the file. Its `disc BIN size` is the table's size word for slot 3 after the openfile: write it down, 0 included. [a, f]
9. **Core `NeoMillie`**, the cart core, Metal Slug level 1. Expect it to run as in hardware test 1. [j]

| # | Check | Result |
|---|---|---|
| a | Metal Slug: "CHECKING DISC", then the game's logo; the size word recorded | Passed, owner, 2026-11-03: the game loads. "CHECKING DISC" and the logo not reported one by one. Size word 676,762,128, the BIN's size |
| b | The attract mode runs | Passed, owner, 2026-11-04, on `NeoGeoCDWait` 0.3.2 with `uni-bioscd.rom`, CD/CDZ on, 1x: "Demonstration" from the game's menu plays mission 1 and loads mission 2, with sound effects and no CD music; Game Start afterwards plays mission 1 with its CD music. Whether the game's demo plays CD music at all is not known, so the silence is not held against the core |
| c | Level 1 for 2 minutes: sprites, fix, sound, CD music (music faults noted for Task 14) | Passed, owner: all well, CD music plays |
| d | A mid-game load completes | Passed, owner: second level reached |
| e | KOF '97 loads and plays | Passed, owner: a fight played, music plays |
| f | `NeoGeoCDWait` in level 1: at most 2% lost on average, at most 4% in the worst frame | Passed: 0 lost of 519,855,971 cycles, worst frame 0, 12,182 frames, 0 failed sectors, mounted. Taken from the card after the owner also tried other BIOSes: if those ran on this core, this is the last run's file, so a clean run of level 1 is to repeat. Repeated on 0.3.2: rows 1, 4 and 5 of the CD Speed table are clean runs of level 1, each 0 lost of all 68K cycles, worst frame 0, 0 failed sectors |
| g | Region and CD/CDZ changes keep the game loading Region passed. `neocd.bin` with CD/CDZ on fails, see below |
| h | Another disc picked with a game running: a core reset, or tray open then closed | Passed, owner: KOF '97 running, Metal Slug picked: the CD screen, then it loaded. Whether the core reset not reported |
| i | Seconds from the pick to the logo, against MiSTer's if known | Timed by the owner, 2026-11-04, on `NeoGeoCDWait` 0.3.2 with `uni-bioscd.rom`, Metal Slug, hand stopwatch from the `.cue` pick to the game's logo: 37 s with CD/CDZ off at 1x, 18 s with CD/CDZ on at 2x. MiSTer's not known |
| j | The cart core still runs Metal Slug | Passed, owner |

The CD/CDZ finding, Metal Slug on `NeoMillieCD` and `NeoGeoCDWait` 0.3.1, as the owner saw them:

| BIOS | CD/CDZ | Other settings tried | Result |
|---|---|---|---|
| `top-sp1.bin` | off | Region changed | Loads and plays |
| `top-sp1.bin` | on | | Does not start: the BIOS's pause mark flashes red and black |
| `neocd.bin` | off | | "NOW LOADING", then the pause mark |
| `neocd.bin` | on | CD Speed 2x; Region JP | The same |
| `uni-bioscd.rom` | on | CD Speed 2x | Loads and plays, reported the next day |

The owner then wrote that these runs may have been their own error, as they were made while drunk. `neocd.bin` then ran again sober on `NeoGeoCDWait`, with CD/CDZ saved on and Region saved EU: the pause mark again, with the same FIX, SPR, PCM and Z80 counts as the first failing file, so the stop repeats exactly. The owner pressed Reset Core after the change, which takes the setting. The file itself does not record the setting. After a minute with the Pocket off, as the first core of the session, with Reset Core: the same result, so a previous game's data in memory is not what stops it. MiSTer's 0xAA fill of PROG RAM, which we don't do, is still not ruled out. The two mismatched rows fail by design: bit 12 of FF011C means a closed tray with the opposite sense on a CDZ and on a top loader, so `top-sp1.bin` with CD/CDZ on, and `neocd.bin` with it off, each see an open tray. MiSTer never makes those pairs, as its Main picks the BIOS by the setting; here both are picked apart.

`neocd.bin`'s CRC is df9de490, as `neocdz` in MAME. Its file: mounted, 0 failed sectors, status word's low nibble 4, PAUSE, 4,749 frames; 65,536 FIX, 35,840 SPR, 131,072 PCM and 65,274 Z80 writes. Those counts are the BIOS's own uploads from its ROM (C0A746), which a simulation with the real BIOS reaches before the drive has answered any command: no file of the game was loaded. In this core CD/CDZ acts only through `CD_LID(~status[15] ^ SYSTEM_CDZ)`, as MiSTer. MiSTer's README lists `neocd.bin` as the CDZ BIOS.

Also seen in both files: "drive state 0 STOP at LBA 0" while the status word says PLAY or PAUSE, which that line does not explain. Not understood yet.

Root cause, from the simulation with the real BIOS (2026-11-04): not a Pocket fault. `neocd.bin` runs the CDZ disc protection check after its boot logo. Metal Slug and KOF '97 carry a "NEO-GEO" block in `CPY/BIB/ABS.TXT` with flags 03 and expected code 02, and the check at C0D260 needs the drive to answer TOC sub-command 7 with 9,7,0,2. Neither MiSTer's `megacdd.cpp` nor our `cdd_drive.sv` answers sub-command 7, so $10F786 stays 0 (eight polls, always 0 in simulation; a local drive variant that answers sets it to 02) and the check fails. A second test then reads a sector near the lead-out, which is audio and never reaches the LC8951. After the check, pass or fail, the BIOS sends the table 02,13,23,33,43,53,63,E2, which gives exactly the `A000000000` / `2400000004` words in the ring; the flashing pause mark is the BIOS's CD player icon while the drive sits in PAUSE. `uni-bioscd.rom` is this BIOS with `bne` changed to `bra` at C0D25E, skipping the block, which is why it loads. MiSTer's Main loads `uni-bioscd.rom` before `neocd.bin` when that file exists, so "CDZ works on MiSTer" does not show `neocd.bin` passing this check there. The 0xAA fill of PROG RAM is ruled out: the check only uses RAM at $100000 and above, and the simulation saw no read of $000000-$01FFFF before a write. Passing the check with `neocd.bin` would need a TOC 7 answer in `cdd_drive` (a few lines, beyond MiSTer) and audio sectors delivered to the decoder (not small); the owner chose, 2026-11-04, to leave it and use `uni-bioscd.rom` as the CDZ BIOS for now. So `uni-bioscd.rom`, `top-sp1.bin` and `front-sp1.bin` serve. Two checks for the owner, not run: with the pause mark on screen, the CD player's play button should play the disc's audio; a disc without the block, such as KOF '95 or Fatal Fury 3, should load with `neocd.bin`.

### CD Speed, one setting at a time, on the debug core 0.3.2

Metal Slug, `NeoGeoCDWait` 0.3.2 (branch `test-core`), `top-sp1.bin`, CD/CDZ off, Region US, Lid off, one change per row, each run's `wait.sav` read on the PC before the next. "Frozen" is the first load's bar stopped at about 75% with the game's own animation still moving.

| Row | CD Speed | Result | Frames | Prefetch hits / host reads | Worst host read | Late polls | Failed sectors | Drive at the end |
|---|---|---|---|---|---|---|---|---|
| 1 | 1x | Loads and plays, 2.8 min | 10,062 | 10,330 / 81 | 1,121 ms | 58 | 0 | PLAY, moving |
| 2, pass 1 | 2x | Frozen | 6,826 | 11,538 / 413 | 421 ms | 346 | 0 | PLAY, stuck at 01:58:49 |
| 2, pass 2 | 2x | Frozen | 4,817 | 7,528 / 255 | 418 ms | 190 | 0 | PLAY, stuck at 01:57:00 |
| 3 | 4x | Frozen | 3,879 | 133 / 9,074 | 419 ms | 10,179 | 0 | PLAY, stuck at 01:57:14 |
| 4, `uni-bioscd.rom`, CD/CDZ on | 1x | Loads and plays, 2.5 min; the BIOS shows its blue CDZ loading screen | 8,847 | 8,852 / 93 | 439 ms | 62 | 0 | PLAY, moving |
| 5, `uni-bioscd.rom`, CD/CDZ on | 2x | Loads and plays, 1.8 min | 6,319 | 8,201 / 103 | 447 ms | 96 | 0 | PLAY, moving |
| 6, `uni-bioscd.rom`, CD/CDZ on | 4x | Corrupt screen | 2,863 | 5 / 1,434 | 65 ms | 1,733 | 0 | STOP: the BIOS sent STOP twice at frame 1,472 and sat in a loop at C0E6B0-C0E6B8 |
| 7, KOF '97, `uni-bioscd.rom`, CD/CDZ on | 2x | Yellow corrupt screen | 14,351 (3 resets; KOF from frame 9,753) | 9,452 / 181 | 66 ms | 128 | 0 | STOP: the BIOS sent STOP twice at frame 12,200, then the loop at C0E6B0-C0E6B8 |
| 8, KOF '97, `uni-bioscd.rom`, CD/CDZ on, 0.3.3 with the bank hold | 2x | Corrupt screen, 0 bank changes | 5,473 (2 resets) | 1,026 / 64 | 72 ms | 47 | 0 | STOP: the same, at frame 3,422 |

Row 8 refutes the bank flip as the cause of KOF '97's failure. With the flip held during a DMA, "cache changed banks during a DMA" is 0 and the screen still corrupts. Row 7's count of 2 cannot be pinned on KOF '97: that file also held a Metal Slug run at 2x, which played. The simulation report's H1 remains a real defect shown in simulation, but it is not this failure, and the note under row 7 that names it as the suspect is superseded. What rows 7 and 8 do show: both stop at the same place, last status `5476310000`, 00:13:67, data-track LBA 892, 1,297 frames after row 8's last reset. A stop at the same sector in two runs is not a random timing fault. In row 8 no DMA word reached FIX or SPR, and KOF '97's `IPL.TXT` starts with `232.FIX`, so the load stopped before the game's first file was copied. The 8-command ring holds only position polls, so it does not show the last seek. 

Row 9, the control, the same disc and settings on the same core at 1x: KOF '97 loads and plays with music, 11,148 frames, 10,484 prefetch hits / 259 host reads, 92 late polls, 0 failed sectors, 630,784 FIX DMA words, drive in PLAY and moving at the end, 0 bank changes. So the stop depends on the speed, not on the disc or on CDZ mode, and the bank hold does not break 1x on this run. What the loader was doing when it gave up is not in the file: the ring holds the last 8 commands, and those are all position polls.

Row 10, 0.3.4, whose ring leaves out TOC, KOF '97, `uni-bioscd.rom`, CD/CDZ on, 2x, one reset, nothing loaded before: corrupt screen again, the same last status `5476310000`, 00:13:67. The loader's last commands, with the disc's layout: frame 1,131 PLAY 00:02:17 (data-track LBA 17, three sectors before the root directory at LBA 20); frame 1,142 PLAY 01:47:72 (LBA 7,947, three before `IPL.TXT` at 7,950); frame 1,153 PLAY 00:02:17 again; then no command until STOP at frame 1,512. Those 359 frames, 6.0 s at 150 sectors a second, match the run from LBA 17 to the stop at LBA 892. So the loader read the directory and `IPL.TXT`, went back to the directory, and that third read never ended: it was not looking for `232.FIX` when it gave up (an earlier guess, that it missed `232.FIX`'s first sector, is wrong). 62 sectors reached PROG by DMA in the whole run. KOF '97's root directory is 11 sectors; Metal Slug's, which loads at 2x, is 2. That is a difference between the discs, not yet a cause. Why the loader does not finish the third read at 2x is not known; it needs the real BIOS in simulation.

Row 11, 0.3.4, KOF '99, `uni-bioscd.rom`, CD/CDZ on, 2x, one reset: reaches the menus, then a corrupt screen on the screen before the fight loads (the owner's correction: not in the fight), 10,413 frames, 3,169 prefetch hits / 86 host reads, 88 late polls, 0 failed sectors, 0 bank changes. The same ending as row 10 on another disc: frame 3,047 PLAY 00:02:17, no other command, STOP twice at frame 3,414 with the drive at 00:13:66, then the loop at C0E6B0-C0E6B8. So the stop is a directory read that does not end, wherever in the game it falls: this disc's earlier reads worked, as the load got as far as the menus. Its directory is 8 sectors, so a large directory is not enough to fail the first load, and that row 10 note's difference between the discs stays only a difference. From that PLAY to the stop: 359 frames and LBA 892 on KOF '97, 367 frames and LBA 891 on KOF '99, so the stop looks tied to the position reached more than to a time.

Row 12, the control, the same disc and core at 1x: past that screen, the fight and on with music, 6.1 minutes, 21,585 frames, 19,349 prefetch hits / 245 host reads, 176 late polls, 0 failed sectors, 0 bank changes, drive in PLAY at the end. So on both discs the stop appears at 2x and not at 1x.

Row 13, 0.3.4, Last Blade 2, `uni-bioscd.rom`, CD/CDZ on, 1x: reported fine by the owner; its file was overwritten by the next run.

Row 14, 0.3.4, Samurai Shodown RPG, the same settings at 1x: past some menus, it hung as the game was about to start, in the owner's words, who probably made the file's reset themselves; 30,133 frames, 21,637 prefetch hits / 394 host reads, 151 late polls, 0 failed sectors, 0 bank changes, 2 resets, the last ending at frame 17,188. The first such stop at 1x: frame 27,111 PLAY 00:02:00, no other command, STOP twice at frame 27,456 with the drive at 00:06:28; afterwards the 68K runs at $133C94 in PROG RAM, not in the BIOS loop. It was preceded by PLAY 61:20:22 at frame 22,115 and a pause. So the failure is not limited to 2x, which may only make it more likely. From the last PLAY to STOP: 359 and 367 frames at 2x, 345 at 1x, about 6 s at either speed, so the stop looks tied to a time and not to a position; this corrects the note under row 11, as the same position on two discs followed from the same time at the same speed. In all three runs the last PLAY is a long seek back to the start of the disc, which is an observation and not yet a cause.

Row 15, 0.3.4, KOF '97, `uni-bioscd.rom`, CD/CDZ **off**, 2x, 3 resets: the yellow screen (the owner's photo: a checker pattern with three lines of unreadable text in the middle, which looks like the BIOS's error message in a broken font; not checked). The file confirms CD/CDZ off and FF011C bit 12 = 1. The same ending as row 10: frame 6,162 PLAY 00:02:17, frame 6,175 PLAY 01:47:72, frame 6,187 PLAY 00:02:17, no retry, STOP twice at frame 6,545, 358 frames later, at 00:13:74. So CD/CDZ on or off does not change this failure. This tests a reading of the BIOS's code: that the retry stayed off because the UniBIOS in its mode 0 read the lid as open with CD/CDZ on. With the lid bit the other way, no retry came either, so that gate is not the explanation, if the BIOS was in mode 0 on this run.

Row 16, 0.3.4, Samurai Shodown RPG, `top-sp1.bin`, CD/CDZ off, 1x, one reset: past the point where row 14 hung, into the game, 8,822 frames, 3,911 prefetch hits / 202 host reads, 75 late polls, 0 failed sectors, 0 bank changes, no stop in the file. Sound effects heard; music not confirmed, with the volume low. This run and row 14 differ in two settings, the BIOS and CD/CDZ, so it does not yet say which one matters.

Row 17, 0.3.4, Samurai Shodown RPG, `uni-bioscd.rom`, CD/CDZ off, 1x, one reset: hung, as in row 14 with CD/CDZ on. The same ending as row 14: frame 4,245 PLAY 00:02:17, frame 4,264 PLAY 60:58:21, frame 4,487 PAUSE, frame 4,910 PLAY 00:02:00, no other command, STOP twice at frame 5,255, 345 frames later as in row 14, at 00:06:31, then the 68K at $133C92-$133C96; 0 failed sectors, 0 bank changes. So on this disc at 1x the stop repeats and goes with the UniBIOS, not with CD/CDZ: on one run of each, `uni-bioscd.rom` hangs with CD/CDZ on or off and `top-sp1.bin` with it off reaches the game. `uni-bioscd.rom` was made the supported BIOS on 2026-11-04 before this was known; that decision is to review.

Row 18, 0.3.4, KOF '97, `top-sp1.bin`, CD/CDZ off, 2x, one reset: reaches a round and plays, with the game's ambient CD tracks, but the loads are very slow and irregular, in the owner's words, against `uni-bioscd.rom`'s stop on the same disc and speed (rows 10 and 15). 19,709 frames, 30,650 data sectors requested, 32,588 prefetch hits / 1,283 host reads, 914 late polls, 481 drive commands, 0 failed sectors, 0 bank changes, PROG DMA 5,166,080 words. Against row 9, the same disc at 1x with `uni-bioscd.rom` in about half the frames: 5,515 data sectors and 1,476,608 PROG words. So far more was read for a similar stretch of the game, and the ring shows the same target twice in a row (00:06:37 at frames 17,708 and 17,709). That looks like this BIOS re-reading what it missed, which would explain the slow loads; the two runs differ in BIOS and speed and were not played to the same point, so it is not shown. Row 2's freeze of this BIOS at 2x on Metal Slug was on 0.3.2, without the bank hold, and has not been repeated on 0.3.4.

Row 19, 0.3.4, Metal Slug, `top-sp1.bin`, CD/CDZ off, 2x, one reset: the bar reaches about 80%, then goes very slowly, not frozen, then carries on and the game plays. This corrects rows 2 and 3: "frozen" there was probably this slow stretch, as those runs were stopped after about 2 minutes; row 2's sector counts were still climbing. The clean comparison is row 1 against this one, the same BIOS and disc, only the speed and the core's version apart: DMA words nearly the same (PROG 4,913,152 and 4,915,200, FIX 155,648 and SPR 2,235,392 in both), data sectors requested 3,899 at 1x and 27,743 at 2x, 0 failed sectors in both. So at 2x this BIOS read about seven times the sectors for the same data, which points to sectors missed and read again. It also corrects the comparison under row 18: `top-sp1.bin` writes about 4.9 M PROG words at 1x as well, so that count says nothing about re-reads. The two BIOSes then differ in how they survive a missed sector: `top-sp1.bin` slows down, `uni-bioscd.rom` sometimes stops. Why a sector is missed is not shown.

Row 20, 0.3.5 (branch `test-core-mask-hold`), KOF '97, `uni-bioscd.rom`, CD/CDZ on, 2x: loads and the owner finished a fight, against the corrupt screen of rows 7, 8 and 10 on the same disc, BIOS and speed. 0.3.5's change from 0.3.4 is the masked-interrupt hold: a sector's flip waits while the decoder is on and the interrupt is masked, for 50 ms at most. 5.1 minutes, 18,203 frames, 2 resets, the last ending at frame 624, no STOP-and-loop ending: the 68K was running until the owner quit. 8,413 data and 13,704 audio sectors requested, about three minutes of CD audio streamed, and the owner reports it sounded fine; 21,647 prefetch hits / 470 host reads, 393 late polls, worst host read 447 ms, 0 failed sectors, 0 bank changes, PROG DMA 1,941,504 words. Against row 18, `top-sp1.bin` on this disc and speed with 30,650 data sectors over a similar length of run, far fewer sectors were read, though the two were not played to the same point. One run, so it does not yet show that the hold is safe on other discs or at 1x.

Row 21, 0.3.5, KOF '97, `uni-bioscd.rom`, CD/CDZ off, 2x: the owner reports it works and won the fight, against row 15's yellow screen on 0.3.4. Its file was overwritten by row 22 before it was read, so the setting is the owner's word and there are no counters. In the bench this setting does not reach the masked scan that the hold was made for, so why the hold would cure it is not explained.

Row 22, 0.3.5, KOF '99, `uni-bioscd.rom`, CD/CDZ on, 2x, one reset: past the screen where row 11 stopped and into the fight, with brief cuts now and then in the music, in the owner's words almost nothing, during the fight and not tied to a load. 5.0 minutes, 17,784 frames, no STOP-and-loop ending: the 68K was running until the owner quit. 8,197 data and 13,016 audio sectors requested, 20,920 prefetch hits / 293 host reads, 357 late polls, worst host read 453 ms, 0 failed sectors, 0 bank changes. The file counts late polls and does not date them, so it cannot tie them to the cuts. Whether the cuts are new or depend on the speed is not known: row 12 at 1x notes music and nothing about cuts, and a repeat of this fight at 1x on 0.3.5 is the comparison.

Row 23, 0.3.5, Samurai Shodown RPG, `uni-bioscd.rom`, CD/CDZ on, 1x, one reset: reaches the game, in the owner's words, where rows 14 and 17 hung as it was about to start. 5.3 minutes, 18,874 frames, 3,968 data and 5,303 audio sectors requested, 9,034 prefetch hits / 237 host reads, 124 late polls, worst host read 84 ms, 0 failed sectors, 0 bank changes. No STOP among the last 8 commands, the last being PAUSE at frame 15,099, and the 68K was running at the end. So the hang of rows 14 and 17 did not appear at 1x with the hold, on one run. A directory scan longer than a sector at 1x, 13.33 ms, has not been shown on this disc, so the cause of those hangs stays a likely match and is not proven. The owner left for a meeting after reaching the game, so how far the game plays is not known.

Row 24, 0.3.5, Metal Slug, `uni-bioscd.rom`, CD/CDZ on, 1x, one reset: works, and on a second run the owner cleared a level; the file is the second run's, the first's was overwritten. 4.2 minutes, 14,914 frames, 4,773 data and 12,218 audio sectors requested, 16,882 prefetch hits / 109 host reads, 89 late polls, worst host read 442 ms, 0 failed sectors, 0 bank changes. So the hold did not break this disc's 1x. The worst host read is about the same as at 2x in rows 20 and 22 (447 and 453 ms) and as row 4's on 0.3.2, so it does not depend on the speed or on the hold. The owner heard a few cuts in the music on this run too, so the cuts of row 22 are not limited to 2x. A suspect, not shown: the debug core asks for a write of `wait.sav` about every 7.2 s (`timer[28]` in `rtl/test/wait_counter.sv`; 35 writes in this run's 4.2 minutes), through the same host channel as the sector reads (`rtl/cd/cd_host.sv`), so a read can wait for it. Against it, row 23 had 44 writes and a worst host read of only 84 ms, so a write does not always cost hundreds of ms. Two checks: cuts about 7.2 s apart on a recording, and whether they remain on a core without the wait counter.

Row 25, `uniplexed.NeoMillieCD` 0.4.0 (branch `release-candidate`, no wait counter, so no file), KOF '99, `uni-bioscd.rom`, CD/CDZ on, which reads at 2x on this core: reaches the fight and the owner cleared it with no cuts in the music heard, against the cuts of row 22 on the debug core at the same speed. This fits the suspect under row 24, the debug core's `wait.sav` write every 7.2 s, and does not prove it: it is one fight, and row 22's cuts came only now and then.

Row 26, `uniplexed.NeoMillieCD` 0.4.0, Metal Slug, `uni-bioscd.rom`, CD/CDZ off, which reads at 1x on this core: works well, in the owner's words, who did not mention cuts in the music.

Row 27, `uniplexed.NeoMillieCD` 0.4.1, KOF '95, CD/CDZ on, which reads at 2x on this core: a first run gave no CD audio music; the owner restarted and the game then played with music. The same disc therefore plays music on this core, so the layout of its CUE, where only 1 of 40 audio tracks has an INDEX 00 against all of them on KOF '99, Last Blade 2 and Samurai Shodown RPG, is not enough to explain the first run. How the first run started, and which restart cured it, is to be asked. This core leaves no file. Not yet explained.

Row 28, the same core and disc, `uni-bioscd.rom`: opening the core with CD/CDZ already saved as on starts directly and with music, and changing CD/CDZ in the menu with a game running restarts the core and works, in the owner's words. So row 27's silent run did not repeat, and its cause is not known: it stays a known issue, seen once.

Row 29, the release packages, `uniplexed.NeoMillie` and `uniplexed.NeoMillieCD` 0.5.0, 2026-11-05, `uni-bioscd.rom`: the owner was asked for a game from the cartridge core's list, its memory card across a power-off, both About screens, KOF '97 with CD/CDZ on (2x) up to a fight, and Last Blade 2 with CD/CDZ off (1x), and to say if the music cut or went silent. The answer was that everything works, with no details, so the cartridge game is not named and how long each ran is not known. These builds have no counter, so there is no file.

Row 30, `uniplexed.NeoMillieCD` 0.5.0 as released, Samurai Shodown RPG, `uni-bioscd.rom`, CD/CDZ on, 2x: load errors on the first run, reported by the owner on 2026-11-05 after the release; a Reset Core with nothing changed, and the game then loads and works. The second first-run failure cured by a restart, after row 27's silent KOF '95; both on the release builds, which have no counter, so there is no file. A debug build that keeps several runs was made to see it (row 31).

Row 31, `uniplexed.NeoGeoCDWait` 0.5.1 (the 0.5.0 sources plus a wait counter that keeps 8 runs in `waits.sav`), Samurai Shodown RPG, CD/CDZ on, 2x, 2026-11-05: four runs in one opening of the core, read with `tools/check_wait_save.py` (copy and report in `build/sd-backup/2026-11-05-waits/`, not published). The owner reported the first as a failure, restarted, failed again, and the last run worked; the file's run 2 lasted 24 frames, a reset at once. The same game load fails twice and runs once: runs 0 and 1 each wrote exactly 728,064 words to PROG RAM and stopped there, run 3 went past it to 1,032,192. Both failing runs ended with the drive's STOP issued twice, the same exit as rows 6 and 7; run 0's 68K sat in a loop in the BIOS at C0E6B2, run 1's at 133C90 in PROG RAM. What the file rules out: failed sectors are 0 in all four; the 'cache changed banks during a DMA' count of rows 5 and 7 is 0 in all four; late polls were 36, 44, 0 and 70 per run, the slowest host read was 86.0 ms, 86.4 ms and, in the run that worked, 87.2 ms, so the failure is not a slow read or a lost sector. What it cannot see: the 2x hold's 50 ms limit (`MASK_HOLD_MAX`), a program that keeps the decoder's interrupt masked that long. 0.5.2 counts it. Also learned: the host loads `waits.sav` back at the start of the core (the blank records came back as 0xFF and numbered the first run 0); a failed first restart means this is not only a first-run problem.

Row 32, `uniplexed.NeoGeoCDWait` 0.5.2 (row 31's build plus counts of the 2x hold), the same game and settings, 2026-11-05: the owner reported the first run failed, a reset, and the next worked; file runs 4 and 5, copy in `build/sd-backup/2026-11-05-waits-052/`. The numbering went on from row 31's file, so the load of the file at the core's start works. The loads are exact: failing run 4 wrote 728,064 words to PROG, 131,072 to FIX, 1,118,208 to SPR and 1,439,744 to PCM, the same as row 31's failing run 1 to the word, and working run 5 wrote what row 31's working run 3 wrote, to the word. Both failing runs end with the same last commands: PLAY to 00:02:17, PLAY to 60:58:21, PAUSE, PLAY to 00:02:00 (LBA 0), and 345 frames on, STOP twice. Failed sectors 0, cache bank changes in a DMA 0, as in row 31. The hold: run 4 held a sector 5 times, run 5 4 times, and every hold in both ran out at its 50 ms limit (50.3 ms each), so each time a sector met a masked interrupt, the mask stayed on past 50 ms and the sector went in with it masked, where its /INT pulse can be missed. One hold more in the failing run, over a shorter run, is what separates the two; when each happened is not in the file.

Row 33, `uniplexed.NeoGeoCDWait` 0.5.3 (row 32's build plus a log of each hold that runs out: frame, the drive's LBA, how long the mask stayed on after), the same game and settings, 2026-11-05: the first run failed, a reset, the next worked; file runs 6 and 7, copy in `build/sd-backup/2026-11-05-waits-053/`. The loads are exact a third time: run 6 stopped at 728,064 PROG words with the same FIX, SPR and PCM counts as runs 1 and 4. The hold is not the cause. Both runs have the same four run-outs at the same place, LBA 108 to 111, about 24 s after the start of the run (run 6 frames 1449 to 1460, run 7 frames 6022 to 6034, 1,469 frames after its start), and the load goes past them. Run 6's fifth run-out is at frame 4014, LBA 330, three frames after the BIOS's STOP at 4011, with the mask then on for 9.1 s until the reset: a result of the failure, not its cause. Run 6's last commands before it: a command 5 at 3262, PAUSE, PLAY to 00:02:17, PLAY to 60:58:21, PAUSE at 3507, PLAY to 00:02:00 (LBA 0) at 3666, STOP at 4011, as in runs 1 and 4. Of the candidates, slow reads, failed host reads and the hold are now ruled out; what the counters cannot see yet is a sector lost inside `cd.sv`, whose two-bank cache can flip past a sector the program has not read, and a sector whose header is not the LBA asked for. The log's 'still on' marks an entry whose timing stopped because the next run-out came, not only one still masked at the last frame.

Row 34, `uniplexed.NeoGeoCDWait` 0.5.4 (row 33's build counting each sector the decoder offered at the next flip of `cd.sv`'s cache: DMA'd, skipped (STAT3 read, no DMA) or lost (neither), with a log of the last 8 lost: frame, header, whether its interrupt reached CD_IRQ_FLAGS or fell masked and was dropped), the same game and settings, 2026-11-06: the first run failed, a reset, the next worked; file runs 8 and 9, copy in `build/sd-backup/2026-11-06-waits-054/`. The failing load stopped at 728,064 PROG words a fourth time. No sector is lost where it fails. Run 8 lost 4 sectors, LBA 107 to 110 at frames 1453 to 1462 (24 s), each with its interrupt dropped while masked: the place of row 33's run-outs, which the BIOS passes in every run. Run 9 lost the same four 1,476 frames after its start, and one more, LBA 328 at frame 6988, in the run that worked. Its last commands before the stop are as in rows 31 and 33: PAUSE at 3264, PLAY to 00:02:17, to 60:58:21, to 61:20:22, PAUSE at 4504, PLAY to 00:02:00 (LBA 0) at 4711, STOP at 5056. Run 8 DMA'd 2,063 sectors and skipped 469; run 9 on its own DMA'd 3,344 and skipped 388. A sector lost in the one-sector cache is ruled out as the cause, and a ring buffer like the LC8951's would not change this load. The SD of this test was first left unmountable by the card reader, which wrote its USB command blocks over the data of every write of the 0.5.4 install; it was repaired from an image before the test.

Row 35, `uniplexed.NeoGeoCDWait` 0.5.4, the same game and settings, 2026-11-06, two tests with no build. A failed load, Quit, the core opened again: the load fails again, and a Reset Core after it works. The core opened, a Reset Core at the title screen before Start Game, then Start Game: it fails. So a reset alone does not make it work, nor does the core's state at opening make it fail: the load works when a failed load came before it in the same opening of the core. Taken with rows 31 to 34 (only at 2x, the same stop every time), the lead is a load that reads memory before the disc's data reaches it, and finds there what the failed load left. Next: 0.5.5 logs the reads of PROG RAM from a 2 KB block nothing wrote since the reset.

Row 36, `uniplexed.NeoGeoCDWait` 0.5.5 (reads of PROG RAM from a 2 KB block nothing wrote since the reset, by the 68K or a DMA), the same game and settings, 2026-11-06: the first run failed, a reset, the next worked; file runs 15 and 16, copy in `build/sd-backup/2026-11-06-waits-055/`. The failing run reads no unwritten block between Start Game (the 68K's reads of `0F9800`-`0FF800` and `1E0000` at frame 3270, the same in both runs) and the STOP at 4061; its last such read, `135000` at 4195, is after the STOP, past the end of `EXT_SYS.PRG` (loaded by IPL.TXT at `132000`, 11,568 bytes) where the 68K loops. The run that works reads seven unwritten blocks 181 frames after its Start Game (`12A008`, `1317D4`, `131800`, `137534`, `13E454`, `13F050`, `141114`): data the failed load left. The disc (read locally from the card image) has one data track and 39 audio tracks; `PLAY 60:58:21` is track 28, music. Its `CPY.TXT` (LBA 49146) holds 68K code that MAME's samsrpg hack changes (byte 64, `g` to `f`: BEQ to BNE), and whose EDC matches the disc's `g`.

Row 37, `uniplexed.NeoGeoCDWait` 0.5.6 first build (68K writes to the CDZ BIOS's protection variables, A5 = `108000`: `7778` special read running, `777E` its count, `7782`, `7786`, `7698`; and STAT3 reads that find nVALST back at 1), the same game and settings, 2026-11-06: runs 17 (failed) and 18 (worked after a reset), copy in `build/sd-backup/2026-11-06-waits-056/`. With the UniBIOS no special read starts in either run, both counts stay 0 in the run that works, and no STAT3 read finds the status expired. The CDZ protection and lc8951.v's 1.8 ms nVALST are not the cause. The failing run's commands are as before: PLAY to 00:02:17 at 4334, track 28 at 4353, PAUSE at 4566, PLAY to 00:02:00 at 4749, STOP at 5094, 345 frames on: the 5 s timeout of a BIOS sector read waiting on `7688`, whose decoder handler drops a sector whose header is not the position sought.

Row 38, `uniplexed.NeoGeoCDWait` 0.5.6 second build (changes the 68K makes to the BIOS's sector read variables: position sought `76C8`/`76CA`, `7688` and `76A6`, `76B6`/`76B7`, `7E04`, `7679`, FF0002; the header of the last sector offered), the same game and settings, 2026-11-07: runs 19 (failed) and 20 (worked after a reset), copy in `build/sd-backup/2026-11-07-waits-056b/`. The UniBIOS keeps a table of the first 512 files of the root directory at `111A06`; the disc has 3,831 in 88 sectors (LBA 20 to 107), so a file past them is searched on the disc (`C0E3A8`), one directory sector at a time into `111204`. At Start Game (frame 3842) that search begins with PLAY to 00:02:17, mask `0550`; no sector is handled before the game's music, PLAY track 28, 19 frames later, nor up to 4301: no change to `7688`, `76CA` or the handler's stage. At 4301 the BIOS starts over at the start of the data: position 00:02:00, `7688` 0, `7E04` bit 0 set, which stops its re-seek after 64 wrong sectors; PLAY to 00:02:00 at 4304. At 4384 the first sector arms the decoder handler (stage 0 to 1: the BIOS spends the first sector after a seek), and nothing more until the timeout at 4649: the BIOS's fatal error `C0E5D8` (STOP, then the loop at `C0E6B2` where the 68K was found in row 30). The drive, as megacdd, starts a PLAY exactly at its target, so at 00:02:00 the sector sought is the one spent and none after it matches; a real drive lands short and a real disc has the pregap before 00:02:00. Fix in `a867ca0`: a data PLAY lands 4 sectors early, into the pregap at the start, which cd_fetch now makes.

Row 39, `uniplexed.NeoGeoCDWait` 0.5.6 with the log of the BIOS command queue stopped at the PLAY to 60:58:21 and the landing change, the same game, 2026-11-08: run 23 with CD/CDZ on failed, run 26 with CD/CDZ off loaded on its first Start Game, up to the fight after choosing a character, with no failed load before it (run 25, 392 frames with no disc, then the reset of the setting); copy in `build/sd-backup/2026-11-08-waits-cdzoff/`. The music is asked for the same way in the load that works: the same queue code 7, `76F6` = 84, 13 frames after the last writes to `76D8`, the queue moving the same way. So the music at that point is not what tells them apart. The log cannot say more: its 16 entries cover the last 15 frames or so, with no write to `7688`, `76B6` or `76C8`, the 8 command ring went on past the music in run 26, and the log's frames are modulo 2048, so run 26's absolute frames are not reliable. The landing change does not break this load at 1x. Run 24 is another disc, with CD/CDZ on.

Row 40, `uniplexed.NeoGeoCDWait` 0.5.6 with the event timelines, the same game, 2026-11-08: run 2 with CD/CDZ on failed, run 4 in another opening with CD/CDZ off loaded; copy in `build/sd-backup/2026-11-08-waitt/`. Every saved run of the debug core, rows 30 to 40, is at CD Speed 1x (the debug core has its own CD Speed item; only a release ties 2x to CD/CDZ), so the failure does not need 2x: at 1x the only thing CD/CDZ changes is FF011C bit 12, the tray bit (0 with it on, 1 with it off). With CD/CDZ off the BIOS reads the root directory's 88 sectors, sets `$76B6` to 0 when done, and only then clears `$7EC4` and asks for the music. With CD/CDZ on it sets up the same read (`$7688` = 58), sends PLAY to 00:02:17, and 0.1 ms later clears `$7EC4` with no sector delivered; the music follows, 7.8 s later the load at position 0 with 0 sectors, and the count runs through FFFF. Candidate, from the UniBIOS 3.3 code and not yet tested: its SYSTEM setting ($10FE32: FRONTLOADER, TOPLOAD or CDZ, 0 when none is saved) sets the polarity of that bit (`C1D4D0`): unless SYSTEM is CDZ, bit 12 at 0 reads as the tray open, which sets the abort flag `$7679` that the BIOS's waits exit on. It does not yet explain why a load after a failed one works. The timeline of CD/CDZ on was recovered by hand: the first start of the next opening, still with CD/CDZ on, cleared its entry 0.

Row 41, the same build and game, CD/CDZ on, CD Speed 1x, 2026-11-08: the UniBIOS menu (Select held at boot) showed `SYSTEM: TOPLOAD`; set to CDZ, the game loaded on its first Start Game, up to the fight after choosing a character. One run. So the failure is a mismatch: the core reports a CDZ (FF011C bit 12 at 0) while the UniBIOS, set to TOPLOAD, reads that as the tray open. Still to check: the same at 2x, as a release runs with CD/CDZ on; whether the setting stays after closing the core; why a load after a failed one worked with TOPLOAD.

Row 42, the same build and game, 2026-11-08: saved with the C button (the Pocket's X), `SYSTEM: CDZ` stays after Quit and opening the core again. With CD/CDZ on, CD Speed 2x and that setting the game loads on its first Start Game, up to the fight after choosing a character. One run. Still unexplained: why a load after a failed one worked with TOPLOAD.

Row 43, the same game, 2026-11-08, with a core-side tray bit that followed the UniBIOS's setting (`ffa1fa3`): with SYSTEM at TOPLOAD, CD/CDZ on and 2x the load still ended in the illegal instruction at `1334A0`, so the tray bit alone is not the fix. On the build before it (copy in `build/sd-removed/2026-11-08-waitt-tests-abc/`), runs 18 and 19 share the core, CD/CDZ on, 2x and FF011C bit 12 = 0: run 18 passed with SYSTEM recalled by the owner as CDZ (3,344 sectors DMA'd), run 19 failed with SYSTEM set to TOPLOAD (2,102 sectors DMA'd). Run 17, TOPLOAD at 1x, failed the same way, and run 15, CD/CDZ off at 1x, passed.

Row 44, `uniplexed.NeoGeoCDWait` 0.5.6 with `cd_bios_model`, the same game, 2026-11-08, the UniBIOS menu not opened (copy in `build/sd-removed/2026-11-08-waitt-bios-model/`): the load got past the point of the failure in all three settings, and the owner stopped each run a few seconds later, so the character select and the fight were not played. Run 2, CD/CDZ off at 1x: the BIOS wrote CDZ, the core stored TOPLOAD, 2,336 sectors DMA'd. Runs 1 and 2 are one opening of the core, and the CDZ fits the value the core had stored in work RAM before changing CD/CDZ restarted it (inferred, not measured). Run 4, CD/CDZ on at 1x: the BIOS wrote TOPLOAD, the core stored CDZ, 2,969 sectors. Run 5, CD/CDZ on at 2x: the same writes, 2,501 sectors. 0 failed sectors in all three. Run 5 is a new opening after run 4 stored CDZ and the BIOS still wrote TOPLOAD, so the forced value did not reach the memory card.

Row 45, `uniplexed.NeoMillieCD` 0.5.1 with `cd_bios_model` (11,628 ALMs, 281 M10K, timing met), the same game, 2026-11-08, the UniBIOS menu not opened: passes in both release modes, CD/CDZ off at 1x and on at 2x, reported by the owner. One run each. This build has no wait counter, so there is no save file to read.

Row 46, the same build, King of Fighters '97, 2026-11-08, the UniBIOS menu not opened: passes with CD/CDZ on at 2x, music reported fine, and with CD/CDZ off at 1x, reported by the owner. One run each, with the 50 ms hold still in the build.

Row 47, `uniplexed.NeoMillieCD` 0.5.1, 2026-11-08, the UniBIOS menu not opened, reported by the owner: The King of Fighters '99, '97 and '95 and Pulstar work, and Fatal Fury 3 works almost perfectly with a few black frames (where in the game was not asked). Then The King of Fighters '98, Art of Fighting, Samurai Shodown IV, Twinkle Star Sprites, Metal Slug 2 and Aero Fighters 3, converted with `cd_convert.py` from zips of one BIN per track and a CHD, all work well. All of them were run with CD/CDZ on, 2x, were played and sounded fine. The owner finds Metal Slug and Metal Slug 2 on CD slower than on the AES core, with more slowdown only under heavy load, which may be the CD version rather than a fault, and slight differences in the music and sound.

Rows 48 to 51, memory card saves, `uniplexed.NeoMillieCD` with the 0.5.1 bitstream, `uni-bioscd.rom`, Samurai Shodown RPG with an English patch, 2026-11-09. In each, a save in the game, then **Quit**, then the SD card read on the PC. Only the core's `data.json` on the card changed between rows.

Row 48, 0.5.1 as released: the save shows and loads after Reset Core, so the game writes and reads the card in the core. After Quit it is gone, and `Saves/ngcd/common/uni-bioscd.sav` is byte for byte the copy of 2026-11-05: no file was written.

Row 49, the Memory Card slot moved before the Disc slots, as in the Mega CD core's order: the file is unchanged. Not the cause; reverted.

Row 50, the original order without `"filename": "uni-bioscd.rom"` on the BIOS slot, the BIOS picked by hand: the file is written, 8,039 of its 8,192 bytes not FF.

Row 51, the BIOS's `"filename"` back, and the Memory Card slot with `"parameters": 32` and `"filename": "uni-bioscd.sav"`: the BIOS loads with nothing to pick, a second save in another of the game's slots is written, and the file differs from row 50's in 45 bytes. The first save is still in it, so the file was also loaded when the core opened. Shipped as 0.5.2.

The fault came with 2d654c2 (2026-11-04), which fixed the BIOS's filename while the card's `"parameters": 36` copied its name from slot 0, the BIOS. Why the Pocket then does not flush the slot is not known: Analogue's documentation does not cover a slot 0 with a fixed filename. Rows 50 and 51 are one run each.

Row 7, KOF '97 at 2x with the UniBIOS: the host kept up (98% prefetch hits, 128 late polls over the whole file, which also holds the Metal Slug run of line i at 2x before the disc change), yet 41 s after the disc pick the loader took the same exit as row 6: STOP twice and the loop at C0E6B0, with the yellow screen. So 2x with the UniBIOS is not safe either, and this stop is not bandwidth. The suspect is "cache changed banks during a DMA: 2": a DMA that read the LC8951's cache while the stream moved it to the next sector got a mix of two sectors, which a loader that checks its data would take as a bad read. Row 5 also had 2 with no visible effect. A simulation report of 2026-11-04 found the mechanism before this row: MiSTer's `cd.sv:263-275` flips the LC8951's read bank once `SECTOR_TIME` has passed and the other bank is full, whether or not a DMA is still reading the current bank, so a loader whose span from the sector's ready to its DMA's end exceeds `SECTOR_TIME` (13.3 ms at 1x, 6.7 at 2x, 3.3 at 4x) gets the rest of the DMA from the next sector under a correct HEAD; reproduced in simulation at 2x and 4x with every wrong word being the next sector's. The counter here is that case on the real BIOS: 2 at 2x in rows 5 and 7, 1 at 1x in row 4, 0 in every `top-sp1.bin` row. The fix the report sketches is to hold the flip while a DMA runs; row 8 shows that it did not cure this failure. The DMA writes that reached no memory, 36,864 here, keep growing with what the game loads (16,384 in the Metal Slug runs).

Row 6 against row 3: at 4x the prefetch collapses with either loader (5 hits of 1,439 requests here, 133 of 9,207 there), 1,427 requests arrived with a prefetch read still at the host, and the worst host read, 65 ms, is twenty times a sector's 3.3 ms. The two loaders then differ in what they do about it: `top-sp1.bin`'s waits for the position for ever (row 3), the UniBIOS's gives up after about 24 s, stops the disc and shows the corrupt screen. No file of the game reached FIX or SPR (0 DMA words to either); the 1,048,576 PCM DMA words are the same in row 8 on another disc, where no file has that size, so they are not the game's (corrected: an earlier version of this note read them as its PCM upload). So 4x is a bandwidth problem of the host path, unlike 2x, and the corrupt screen is the loader's error path, not a memory fault: 0 failed sectors, 0 lost DMA words, 0 bank changes.

Row 5 against row 2: the same speed, 2x, freezes `top-sp1.bin`'s loader twice and not the UniBIOS's, so the stop is in how a loader waits, not in the speed alone. Late polls do not stop a run by themselves: row 5 had 96 and played. In the frozen rows the drive's position stays put while in PLAY, and the loader cycles TOC 8, 7, 6, 2 waiting for it; in row 5 the position moves (05:30:70 at the end). The UniBIOS loader also fetched less: 8,201 prefetch hits in 6,319 frames against 11,538 in 6,826. "DMA writes that reached no memory": 16,384 in every run that plays (rows 1, 4, 5), 4,096 in the frozen ones, so that is the game's own writes to an area not enabled, not a fault; where it goes is still to be read. "Cache changed banks during a DMA" is 2 in row 5 and 1 in row 4, 0 in the `top-sp1.bin` rows, with no visible effect.

Row 4's file reads CD/CDZ on and FF011C bit 12 at 0, a closed tray for a CDZ, and its `uni-bioscd.rom` loaded the game: the setting and the CDZ path work at 1x. Its one new mark: the LC8951's cache changed banks during a DMA once (0 in the other rows); whether that DMA read the cache is not known. In every frozen run the FIX and SPR write counts are the same, 204,800 and 1,266,688, so the load stops at the same file of the disc, and the BIOS keeps polling the drive with TOC 8, 7, 6 and 2 while the position does not move. Nothing is lost on the memory path by the counters, and no sector fails. The screen never corrupts with this BIOS: the corrupt screens seen on 0.3.1 were with `uni-bioscd.rom` and CD/CDZ on, which rows 4 and 5 repeat. At 4x the prefetch no longer keeps up at all (133 hits), yet the stop is at the same place as 2x, so the stop is not a matter of bandwidth.

Beyond the list: the owner reports the game loading with two of the four BIOSes so far. The card holds `top-sp1.sav`, `neocd.sav`, `front-sp1.sav` and `uni-bioscd.sav` in `Saves/ngcd/common/`: the card is named after the picked BIOS and shared by the CD cores. The file's FIX, SPR and PCM counts, 286,720, 2,300,928 and 2,222,080, are each a multiple of 1,024, as the gate's zeros were read.

For any failure, run it again on `NeoGeoCDWait`, as the file is the only view inside, and take `wait.sav` off the card before the next run: a run that fails before its first save, about 7 s in, leaves the previous file. Lines of `check_wait_save.py`'s output:

| What you see | Read in the file | What it points at |
|---|---|---|
| Stuck on "CHECKING DISC" | `last mount:` not "mounted" | The mount: see the next row |
| | `drive state` not PLAY, LBA not moving, exchanges rising | The BIOS is not asking for sectors: the TOC it read. The `last command` and `last status` words say what it was at |
| | PLAY, LBA moving, `failed sectors` rising | Host reads of slot 3 fail: the sectors' offsets, or a read past the file's end |
| | PLAY, LBA moving, no failed sectors, FIX, SPR, PCM not moving | Sectors arrive and the BIOS rejects them: the header (`file_lba`, a pregap slip), or the decoder interrupt, or the DMA |
| | PLAY, LBA stuck, exchanges rising | `req_done` never came: the fetch, or the host never answers |
| No disc reported | `last mount:` says why: "openfile of the BIN failed" is the folder or name in the CUE; "a read of the picked file failed" is the slot's read; "the slot's size is 0" is the table; "neither a CUE nor..." is the wrong file; "none yet" with `drive state` not TRAY is that no mount request came, so the pick did not reach the core; with TRAY the mount is still under way, so the host is not answering its reads | The mount's reason |
| Picture, no sound | Z80 and PCM counts: at 0 modulo their width, the game's uploads did not happen. Both moving, and no FM, effects or music: the Z80 program, then the audio mix | Z80 RAM, PCM RAM, `cdda.v`, and the T80, unseen before |
| Effects, no CD music | `drive state` PLAY, LBA moving into an audio track | `cdda.v`'s path: note it for Task 14 |
| Loads, then freezes | `failed sectors` not 0: which read. LBA at the end of the disc or `drive state` END: a request past the data. FIX, SPR, PCM stopped mid-load, LBA moving: the DMA's window | The host's reads, the TOC's stops, `DMA_SDRAM_BUSY` |

Findings are fixed one commit each, with the observation in the message, and the lines are run again until a to j pass. The commit `feat(cd): milestone 3, a converted disc loads and plays` and its tag `m3-cd-mount-fetch` wait for that; no line has been marked as passed.

### Debug core 0.3.2

`NeoGeoCDWait` 0.3.2, `dist/uniplexed.NeoGeoCDWait_0.3.2.zip`, branch `test-core`: not a release. Its file shows what 0.3.1's could not: the settings in effect, the last 8 non-IDLE drive commands with their answers and frames, the 68K at the last 4 VBlanks, resets, the sector fetch, and the DMA's memory path. `python tools/build.py neogeocd_wait`, Quartus 25.1 Lite, 5CEBA4F23C8. Nothing here ran on a Pocket. `sim/topcd` and `sim/top` had not run on this build when it was packaged.

| Build | RD_WAIT | ALMs of 16,600 budget | M10K of 292 | DSP | `.rbf` SHA-256 (first 16) | Thinnest setup | Thinnest hold |
|---|---|---|---|---|---|---|---|
| `neogeocd_wait`, `NeoGeoCDWait` | 8 | 13,314 | 282 | 5 | 6c34513c9cf0e540 | +0.276, CLK_96M, Slow 85C | +0.097, CLK_48M, Fast 0C |
| `neogeo`, `NeoMillie` | 8 | 8,695 | 272 | 5 | 109abd1e332d73df | | |

Slack in ns, `neogeocd_wait`:

| Clock | Setup Slow 85C | Slow 0C | Fast 85C | Fast 0C | Hold Slow 85C | Slow 0C | Fast 85C | Fast 0C |
|---|---|---|---|---|---|---|---|---|
| CLK_96M | +0.276 | +0.295 | +1.534 | +1.680 | +0.308 | +0.301 | +0.139 | +0.126 |
| CLK_48M | +0.332 | +0.396 | +4.268 | +4.629 | +0.291 | +0.178 | +0.130 | +0.097 |
| CLK_PIX | +6.176 | +6.307 | +8.186 | +8.454 | +0.484 | +0.457 | +0.157 | +0.116 |
| dram_clk | +1.952 | +1.936 | +2.447 | +2.458 | +3.883 | +3.929 | +4.152 | +4.160 |
| clk_74a | +3.043 | +2.611 | +8.821 | +9.135 | +0.311 | +0.301 | +0.150 | +0.136 |
| bridge_spiclk | +10.533 | +10.782 | +12.256 | +12.382 | +0.420 | +0.407 | +0.181 | +0.172 |

The file is 512 bytes now, layout 3. **Delete `Saves/ngcd/uniplexed.NeoGeoCDWait/wait.sav` before the first run**: what the host does with an older, shorter file is not known. `tools/check_wait_save.py` reads all three layouts, and says what a 256-byte layout 3 file lacks. Leave the core with **Quit**, and take the file off the card before the next run.

---

NeoMillie is free. If it is useful to you, [donate with PayPal](https://www.paypal.com/donate/?hosted_button_id=A72RAVHX98628).
