// SPDX-License-Identifier: GPL-3.0-only
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License only.

// What the CD modules share, as megacd.h of MiSTer's Main. A package, compiled once where cdd_drive.sv
// includes this file, so it must come before the other files that import it.
`ifndef CD_DEFS_SVH
`define CD_DEFS_SVH

package cd_defs;

// A track of the disc's table of contents. start and stop are disc LBAs, lead-in excluded. file 0 is the
// picked file itself, 1..n the CUE's FILEs in order. file_lba is the LBA within file of the sector at
// start, so the byte offset of disc LBA x is (x - start + file_lba) * 2352.
typedef struct packed {
    logic        audio;
    logic  [6:0] file;
    logic [23:0] start;
    logic [23:0] stop;
    logic [23:0] file_lba;
} toc_entry_t;

localparam logic [3:0] CD_STAT_STOP         = 4'h0,
                       CD_STAT_PLAY         = 4'h1,
                       CD_STAT_SEEK         = 4'h2,
                       CD_STAT_SCAN         = 4'h3,
                       CD_STAT_PAUSE        = 4'h4,
                       CD_STAT_OPEN         = 4'h5,
                       CD_STAT_NO_VALID_CHK = 4'h6,
                       CD_STAT_NO_VALID_CMD = 4'h7,
                       CD_STAT_ERROR        = 4'h8,
                       CD_STAT_TOC          = 4'h9,
                       CD_STAT_TRACK_MOVE   = 4'hA,
                       CD_STAT_NO_DISC      = 4'hB,
                       CD_STAT_END          = 4'hC,
                       CD_STAT_TRAY         = 4'hE;

localparam logic [3:0] CD_COMM_IDLE       = 4'h0,
                       CD_COMM_STOP       = 4'h1,
                       CD_COMM_TOC        = 4'h2,
                       CD_COMM_PLAY       = 4'h3,
                       CD_COMM_SEEK       = 4'h4,
                       CD_COMM_PAUSE      = 4'h6,
                       CD_COMM_RESUME     = 4'h7,
                       CD_COMM_FW_SCAN    = 4'h8,
                       CD_COMM_RW_SCAN    = 4'h9,
                       CD_COMM_TRACK_MOVE = 4'hA,
                       CD_COMM_TRACK_PLAY = 4'hB,
                       CD_COMM_TRAY_CLOSE = 4'hC,
                       CD_COMM_TRAY_OPEN  = 4'hD;

localparam logic [3:0] CRC_START = 4'd5;
localparam int CD_SCAN_SPEED = 30;
localparam int LEAD_IN = 150;

endpackage

`endif
