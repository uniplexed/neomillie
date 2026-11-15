// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// APF slots and settings of the cart core, and the CD build's at the end. Include inside a module.
//
// The register map is the one of apf_io.sv in Mazamars312's Neo Geo Overdrive for Pocket ("Free of
// use"), the only map there is: the game JSON files by terminator2k2 and Timothee Groleau, and
// interact.json, write to it. Slots, filenames and bridge addresses are those of his data.json.
//
//   Slot   File                Bridge address   ioctl_index   Conversion
//   0      game instance JSON  none (*)         none          none
//   1      BIOS                0x10A00000       0             none
//   2      000-lo.lo           0x50000000       1             a word per byte, byte in [7:0], first 64 KB
//   3      srom                0x10C00000       8             fix_convert
//   4      prom                0x10000000       4             none
//   5      crom0               0x40000000       15            spr_convert_dbl
//   6      m1rom               0x10F80000       9             none
//   7      vroma0              0x20000000       16            none, linear into CRAM1
//   8      prom1               0x10800000       4, addr from 0x800000
//   9      sfix.sfix           0x10D00000       2             fix_convert
//   0x101  memory card, 8 KB   0x60000000       none          none
//   0x102  backup, 64 KB       0x70000000       none          none
//   (*) parsed by the Pocket OS; its memory_writes reach the settings below as bridge writes.
//
// Slot 7 always loads linear. Indices 48-63 are not used: the V2 region of a game comes from
// V2_offset and V2ROM_MASK in its JSON file, and only matters with cfg[23] = 0.
//
// Slot 8 lands at 0x800000, which holds only if prom is 8 MB in every game that has a prom1. The
// paks whose game JSON loads slot 8: garou, garouh, kof99, kof99e, kof2000, kof2003, mslug3.
// prom1_conflict goes high if a prom ever runs past 8 MB in a game that also loads a prom1.
//
// No end of file flush: no Neo Geo ROM file is smaller than 64 KB or not a multiple of the block
// size (Darksoft crom0 is a multiple of 1 MB, srom and sfix of 64 KB). A block still open when
// the slot or the address moves on is dropped. How the bridge delivers a file whose length is not
// a multiple of 4 is not documented.

// Old game JSON locations. The 249 files write 0x24, 0x28, 0x2C, 0x30, 0x3C, 0x40, 0x4C, 0x30C, 0x310,
// 0x314, 0x400, 0x410
localparam [11:0] REG_SYSTEM_TYPE_OLD = 12'h00C;
localparam [11:0] REG_MEMCARD_OLD     = 12'h010;
localparam [11:0] REG_PCHIP_MAIN_OLD  = 12'h024;
localparam [11:0] REG_USE_PCM_OLD     = 12'h028;
localparam [11:0] REG_PCHIP_SUB_OLD   = 12'h02C;
localparam [11:0] REG_CMC_CHIP_OLD    = 12'h030;
localparam [11:0] REG_V2_OFFSET_OLD   = 12'h03C;
localparam [11:0] REG_CART_CHIP_OLD   = 12'h040;
localparam [11:0] REG_V2_MASK_OLD     = 12'h04C;
localparam [11:0] REG_C1_WAIT_OLD     = 12'h054;
// Core
localparam [11:0] REG_CORE_RESET      = 12'h100;
localparam [11:0] REG_DIPSW           = 12'h104;    // 1 = on: bit 0 settings mode, 1 freeplay, 2 freeze
localparam [11:0] REG_SYSTEM_TYPE     = 12'h108;
localparam [11:0] REG_MEMCARD         = 12'h10C;    // bit 0: 1 = card unplugged
localparam [11:0] REG_CPU_CLOCK       = 12'h110;    // 0 = 12 MHz, 1 = 16 MHz, 2 = 24 MHz; a change restarts the core
localparam [11:0] REG_LR_BUTTONS      = 12'h118;    // 0 L A+B, R C+D; 1 L ABC; 2 R ABC (MiSTer's ABC key)
// Video
localparam [11:0] REG_VIDEO_MODE      = 12'h200;
localparam [11:0] REG_SCREEN_X        = 12'h204;    // signed pixels, right is positive
localparam [11:0] REG_SCREEN_Y        = 12'h208;    // signed lines, down is positive
localparam [11:0] REG_VIDEO_RATIO     = 12'h20C;    // bit 2: 320 wide, bits 2:0: scaler slot
// Sound and V2. The mutes: 1 = silent
localparam [11:0] REG_CH_MUTE         = 12'h300;    // the six ADPCM-A channels
localparam [11:0] REG_SND_MUTE        = 12'h304;    // bit 0 FM, 1 ADPCM-A, 2 ADPCM-B, 3 PSG
localparam [11:0] REG_STEREO_MIX      = 12'h318;    // 0 none, 1 25%, 2 50%, 3 100% (mono)
localparam [11:0] REG_USE_PCM         = 12'h30C;
localparam [11:0] REG_V2_OFFSET       = 12'h310;
localparam [11:0] REG_V2_MASK         = 12'h314;
// Chips
localparam [11:0] REG_C1_WAIT         = 12'h400;
localparam [11:0] REG_PCHIP_MAIN      = 12'h404;
localparam [11:0] REG_PCHIP_SUB       = 12'h408;
localparam [11:0] REG_CMC_CHIP        = 12'h40C;
localparam [11:0] REG_CART_CHIP       = 12'h410;
// New, for the JSON maker, with no Overdrive alias
localparam [11:0] REG_MS5P            = 12'h500;
localparam [11:0] REG_XRAM            = 12'h504;
localparam [11:0] REG_ADPCMA_EXT      = 12'h508;
// CD build only (apf_loader CD_BUILD), the settings of pocket/neogeocd/interact.json. Read back for the menu
// as REG_SYSTEM_TYPE is.
localparam [11:0] REG_CD_TYPE         = 12'h600;    // bit 0: 1 = CDZ, to status[2]
localparam [11:0] REG_CD_REGION       = 12'h604;    // 0 US, 1 EU, 2 JP, 3 AS (MiSTer's status[11:10]; the top remaps)
localparam [11:0] REG_CD_LID          = 12'h60C;    // bit 0: 1 = open, to status[15]
// Cart build: the region the UniBIOS is made to keep, see bios_model. 0 = the BIOS's own setting, 1 JP, 2 US, 3 EU
localparam [11:0] REG_CART_REGION     = 12'h610;
// CD build: CD Turbo 4x (beta), the 4x drive that reads ahead through the SDRAM ring
localparam [11:0] REG_CD_TURBO        = 12'h614;    // bit 0: 1 = Turbo 4x, to status[12]

// Accepted and ignored, with every other write in 0xF0000000-0xF0000FFF: 0x014 use_mouse, 0x01C ch_enable,
// 0x020 snd_enable, 0x050 and 0x308 V1ROM_MASK (MiSTer builds its own).

// Save slots in the data table, sizes as the Overdrive answers them (size_exact is null)
localparam [31:0] SLOT_MEMCARD = 32'h101;
localparam [31:0] SIZE_MEMCARD = 32'd8192;
localparam [31:0] SLOT_BACKUP  = 32'h102;
localparam [31:0] SIZE_BACKUP  = 32'd65536;

// The CD build's data.json (pocket/neogeocd): 0 BIOS 0x10A00000, 1 000-lo.lo 0x50000000, 0x101 memory card
// 0x60000000 as above. The disc slots are deferred: the host loads them on demand, and the loader takes
// only their size from the data table. The disc slot's address is nominal, never written.
//   2  disc, cue or bin, parameters 0x9, address 0x73000000
//   3  disc data, bin, parameters 0x8, no address
localparam [31:0] SLOT_DISC     = 32'd2;
localparam [31:0] SLOT_DISC_BIN = 32'd3;

localparam [4:0] IDX_BIOS = 5'd0, IDX_LO = 5'd1, IDX_SFIX = 5'd2, IDX_P = 5'd4, IDX_SROM = 5'd8,
                 IDX_M1 = 5'd9, IDX_CROM = 5'd15, IDX_V = 5'd16;
