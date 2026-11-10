// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Memory map of the core, byte addresses within each chip. Include inside a module.
//
//   Region                Chip    Base       Size
//   P1 ROM                CRAM0   0x000000   1 MB
//   PROG RAM (CD build)   CRAM0   0x000000   2 MB, over P1 and P2, which the CD build does not load.
//                                            As MiSTer, the 68K reads its low 1 MB as the P1 zone (nROMOE),
//                                            so MAP_P1 must equal MAP_PROG; CD_EXT_RD and the DMA read the rest.
//   P2 ROM (banked)       CRAM0   0x100000   up to 7 MB
//   PROG1 (secondary P)   CRAM0   0x800000   1 MB
//   System ROM (BIOS)     CRAM0   0xA00000   128 KB (cart) / 512 KB (CD)
//   S ROM (cart fix)      CRAM0   0xC00000   512 KB
//   SFIX                  CRAM0   0xD00000   128 KB
//   MVS backup RAM (cart) CRAM0   0xD20000   64 KB
//   M1 ROM                CRAM0   0xF80000   512 KB
//   V ROMs                CRAM1   0x000000   16 MB
//   PCM RAM (CD build)    CRAM1   0x000000   1 MB, where ADPCM-A reads it
//   C ROM (interleaved)   SDRAM   0x0000000  64 MB
//   SPR RAM (CD build)    SDRAM   0x0000000  4 MB, four banks of 1 MB, where the sprite fetch reads it
//   FIX RAM (CD build)    SRAM    word 0     128 KB, words 0x0000 to 0xFFFF, in sram_port. Not on CRAM0
//   S and M1 (cart)       SRAM    word 0     copies of what CRAM0 holds: S up to 128 KB then the first 128 KB of M1, or,
//                                            with a larger S, the first 256 KB of M1
localparam [23:0] MAP_P1    = 24'h000000;
localparam [23:0] MAP_PROG  = 24'h000000;
localparam [23:0] MAP_P2    = 24'h100000;
localparam [23:0] MAP_PROG1 = 24'h800000;
localparam [23:0] MAP_BIOS  = 24'hA00000;
localparam [23:0] MAP_SROM  = 24'hC00000;
localparam [23:0] MAP_SFIX  = 24'hD00000;
localparam [23:0] MAP_BACKUP = 24'hD20000;
localparam [23:0] MAP_M1    = 24'hF80000;
localparam [23:0] MAP_PCM   = 24'h000000;
