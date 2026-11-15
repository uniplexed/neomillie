# Third-party notices

NeoMillie, the Neo Geo and Neo Geo CD cores for the Analogue Pocket, and its NeoMillieCD Converter build on the work of the following authors.

| Component | Author(s) | Use |
|-----------|-----------|-----|
| Neo Geo core (NeoGeo_MiSTer RTL) | Furrtek | Base RTL, pinned as a submodule. Its `LICENSE` is the text of the GPL, version 2 |
| MiSTer port | srg320, Sorgelig and MiSTer-devel | Base RTL, in the same submodule |
| `cd_sys` (`rtl/cd/cd.sv`, `drive.v`, `lc8951.v`, `cdda.v` of NeoGeo_MiSTer) | paulb-nl, by that directory's commits; srg320, Sorgelig and MiSTer-devel; the headers of the first three name Sean 'Furrtek' Gonsalves, `cdda.v` has no header | The CD controller, its DMA, the transfer windows, the drive bus and the CD audio buffer (`synth/neogeocd_core.qsf`). `drive.v` and `cdda.v` are built unmodified from the submodule; `cd.sv` and `lc8951.v` are built from the copies under `rtl/cd/`, whose edits are tagged `POCKET` (the cache bank flip held while a DMA runs and, with CD Turbo 4x, while the decoder is on with its interrupt masked, with `DECEN` brought out for that). Those three headers say GPL-2-or-later. The glue in `rtl/top/neogeo_pocket.sv` is tagged `POCKET`, and an accumulator there replaces `CEGen.vhd` |
| `megacdd.cpp` of MiSTer Main | zakk4223 and paulb-nl, by its commits; srg320, Sorgelig and MiSTer-devel | `rtl/cd/cdd_drive.sv` with `rtl/cd/cd_defs.svh` is its port, function by function, driven as `neogeocd.cpp` drives it. `rtl/cd/cd_mount.sv` takes the TOC arithmetic of its `cdd_t::LoadCUE`. `sim/cdd/harness.cpp` compiles with it. The file carries no notice of its own and its repository offers only the GPLv3 text (`sim/cdd/mister/SOURCE.md`), so these four files are GPL-3.0-only by their headers. `megacdd.cpp`, `megacd.h` and `cd.h` are vendored unchanged in `sim/cdd/mister/` for the golden trace, and are not built into a core |
| `sdram_mux.sv` and `ddram.sv` of NeoGeo_MiSTer | Sean 'Furrtek' Gonsalves; Sorgelig | Ported in `rtl/pocket/pocket_mem_mux.sv`, header credits kept: `sdram_mux.sv`'s request detection and priority, and its CD remaps (`sdram_mux.sv:120,123`, SPR and FIX) with the chips changed; the client side of `ddram.sv`. Their headers say GPL-2-or-later and GPL-3-or-later |
| jt12 / jt49 | jotego | Sound chips |
| fx68k | Jorge Cwik | 68000 CPU. `rtl/cpu/FX68K/fx68k.txt` of NeoGeo_MiSTer gives the licence: GPL, "either version 3 of the License, or (at your option) any later version" |
| T80 | Daniel Wallner | Z80 CPU |
| Neo Geo Overdrive for Pocket | Mazamars312 | Reimplemented from their source, no code copied: PSRAM timing sequence of `psram_controller.v` followed in `rtl/pocket/cram_ctrl.sv`; arbitration policy and memory layout of `cram_16bit.v` and `cram_8bit.v` followed in `rtl/pocket/pocket_mem_mux.sv`; data table size loop of `apf_io.sv`, the read path and the `dist/` layout followed in `rtl/test/` and `pocket/memtest/`. Adapted, not copied: the settings register map, reset action, data table loop and read paths of `apf_io.sv` in `rtl/pocket/apf_loader.sv` and `apf_regs.svh`; the header of `apf_io.sv` says "Free of use - please feel free to use at your own and create". `pocket/neogeo/audio.json`, `video.json` and `variants.json` are copied from their `dist/`. `data.json`, `input.json` and `interact.json` started as copies of theirs and have since been changed: `interact.json` first lost the CPU overclock and screen position entries and gained a default for MVS/AES, and the 0.6.0 menu added items of its own and brought back the Screen X Position and Screen Y Position sliders at their addresses and ranges. Adapted, not copied: the scaler convention of the video block of `Neogeo.sv` (mode slot in `video_rgb[15:13]` on the first pixel clock after DE falls, width and slot from `APF_Video_ratio`, 224 lines) in `rtl/pocket/video_out.sv`, with DE taken from the core's blanking instead of their porches (the picture sits about 2 pixels right of their default position, 224 lines as their, PAL window from line 16); `i2s.v` (no author header, their README lists the I2S bus among their modules) in `rtl/pocket/audio_i2s.sv`, with the same MCLK accumulator and I2S framing but clock enables in `clk_74a` and a request/acknowledge sample handshake. `pocket/neogeocd/` holds the same `audio.json`, `input.json`, `video.json` and `variants.json` as `pocket/neogeo/`, and its `interact.json` repeats the width and scaler items. Their tree holds `cd.sv`, `drive.v` and `lc8951.v` of the Neo Geo core; `rtl/cd/` takes nothing from it |
| `releases/romsets.xml` of NeoGeo_MiSTer; the Overdrive's game JSON set | MiSTer-devel; terminator2k2 and Timothee Groleau | `tools/make_game_jsons.py` generates the cartridge core's game list from the XML's attributes. Its V2 masks, its folder overrides and `lasthope` come from the JSON set made for the Overdrive, which no longer ships. The file has no licence notice of its own, and the submodule's `LICENSE` is the text of the GPL, version 2 |
| `fix_convert`, `spr_convert_dbl` of `neogeo_loader.cpp` | MiSTer-devel, Main_MiSTer | The two ROM conversions, done in hardware in `rtl/pocket/apf_loader.sv` |
| `openfpga-megacd` (Pocket Mega CD) | neutralinsomniac | Design reference only, no code copied: the repository has no licence file. Read for the APF target-command state machine's shape (`megacd_top.sv:470-582`), a bank of four sectors at bridge `0x7000_{slot}000`, the `deferload` slots (`parameters` `0x9` for the picked disc, `0x8` for the hidden data slot), the openfile parameter struct (path bytes, then flags word, then size word), the getfile response (NUL-terminated path), a binary search of reads for a BIN's size, the lesson that a read completed by the watchdog must never validate a bank slot, and that openfile is refused outside `/Assets/<platform>/` and `/Saves/<platform>/`. `synth/neocd_delta/megacd_cdd.qsf` compiles its `megacd_cdd_drive.sv` from a local clone, only to compare sizes (`docs/hw-tests.md`); it is in no build of these cores |
| APF framework, core template v1.3.0 (`core_top.v` port list, tie-offs and host command wiring; `core_bridge_cmd.v`; the pin map in `synth/pocket_common.qsf`) | Analogue | Used under Analogue's own EULA, which the headers of the template's `src/fpga/apf/*.v` name. A submodule. The header of `rtl/top/core_top.v` says which part of that file is the template's |
| ECM 1.0 | Neill Corlett | The EDC and ECC code of `tools/cdconv/disc.py` follows it. Copyright (C) 2002 Neill Corlett, GPL version 2 or (at your option) any later version, used under version 3 or later |
| Disc image layouts: cdirip 0.6.3 (DeXT), Aaru, libmirage, MAME's `cdrom.cpp`, libcdio, nrgrip, Mednafen, Yabause | their authors | Read for the CloneCD, Alcohol 120%, Nero and DiscJuggler file layouts that `tools/cdconv/` reads. No code of theirs is used |
| Python, PyInstaller, Tcl/Tk, OpenSSL and the other libraries inside the converter programs | their authors | Carried inside `NeoMillieCD-Converter-windows-x64`, `-macos-arm64` and `-linux-x64`. Each zip has their licences in `THIRD-PARTY-LICENSES.txt`, made by `tools/third_party_licenses.py` from `tools/licenses/third-party.txt` and the build system's own files |

## The T80 licence

The cores' bitstreams contain T80, whose licence asks for its notice in the materials that come with them. This is the header of `T80.vhd`, as the other T80 files carry it:

```
****
T80(c) core. Attempt to finish all undocumented features and provide
             accurate timings.
Version 350.
Copyright (c) 2018 Sorgelig
 Test passed: ZEXDOC, ZEXALL, Z80Full(*), Z80memptr
 (*) Currently only SCF and CCF instructions aren't passed X/Y flags check as
     correct implementation is still unclear.

****
T80(b) core. In an effort to merge and maintain bug fixes ....

Ver 303 add undocumented DDCB and FDCB opcodes by TobiFlex 20.04.2010
Ver 301 parity flag is just parity for 8080, also overflow for Z80, by Sean Riddle
Ver 300 started tidyup.

MikeJ March 2005
Latest version from www.fpgaarcade.com (original www.opencores.org)

****
Z80 compatible microprocessor core

Version : 0250
Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
