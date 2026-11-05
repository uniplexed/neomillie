// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Frame generator with the shape of MiSTer's video_cleaner output at ce_pix: 384 pixels per line,
// 264 lines (NTSC) or 312 (PAL), the signals aligned and registered at ce_pix. The numbers come from
// running videosync.v and clocks.v of the pinned submodule: HSYNC is a 27 pixel pulse, CHBL is low
// for 320 pixels starting 55 pixels after the HSYNC edge, BNKB is low for 224 lines (NTSC) or
// 256 lines (PAL, 56 blank lines). VBlank and VSync change at the start of a line, as the cleaner
// updates them at the hs edge. The colour is a function of the picture position, so a test can tell
// which pixel it sees; everything outside the picture is 8'hEE so that blanking must be forced to 0.
package vo_pkg;
    // First line of the blank-free window (BNKB low) of the frame below, and the distance from the
    // trailing edge of the raw VSYNC pulse (the end of its 8 lines) to it, both measured by running
    // videosync.v of the submodule: 16 lines in NTSC (the pulse is RASTERC[8], trailing edge at
    // raster line 0x100, window from 0x110) and 27 in PAL (BLANK_PAL, trailing edge at line 0xE5,
    // window from 0x100). The Overdrive restarts its line count at that trailing edge and opens DE
    // 16 (NTSC) or 43 (PAL) lines later (Neogeo.sv:1641-1642), see overdrive_first_line.
    function automatic int act_y0(input bit pal);
        return pal ? 24 : 16;
    endfunction
    function automatic int raw_vsync_trail(input bit pal);
        return act_y0(pal) - (pal ? 27 : 16);
    endfunction
    // First line of the Overdrive's picture, in the lines of the stub, from his formula alone
    function automatic int overdrive_first_line(input bit pal);
        return raw_vsync_trail(pal) + (pal ? 43 : 16);
    endfunction

    function automatic [23:0] px(input int xa, input int ya);
        logic [7:0] x8, y8;
        x8 = xa[7:0];
        y8 = ya[7:0];
        return {x8, y8, xa[8] ? ~y8 : (y8 ^ x8)};
    endfunction
endpackage

module lspc_timing_stub #(
    parameter bit PAL = 0
) (
    input  wire       CLK_48M,
    input  wire       ce_pix,
    input  wire       rst,
    output reg  [7:0] r = 0, g = 0, b = 0,
    output reg        hs = 0, vs = 0, hblank = 1, vblank = 1
);
    import vo_pkg::*;

    localparam int LINE   = 384;
    localparam int LINES  = PAL ? 312 : 264;
    localparam int HS_W   = 27;
    localparam int ACT_X0 = 55;
    localparam int ACT_Y0 = act_y0(PAL);
    localparam int ACT_H  = PAL ? 256 : 224;
    localparam int VS_Y0  = 2;
    localparam int VS_H   = 8;

    int x = 0, y = 0;
    wire in_x = x >= ACT_X0 && x < ACT_X0 + 320;
    wire in_y = y >= ACT_Y0 && y < ACT_Y0 + ACT_H;
    wire [23:0] p = px(x - ACT_X0, y - ACT_Y0);

    always @(posedge CLK_48M) begin
        if (rst) begin
            x <= 0;
            y <= 0;
        end else if (ce_pix) begin
            x <= x == LINE - 1 ? 0 : x + 1;
            if (x == LINE - 1) y <= y == LINES - 1 ? 0 : y + 1;
            hs     <= x < HS_W;
            vs     <= y >= VS_Y0 && y < VS_Y0 + VS_H;
            hblank <= !in_x;
            vblank <= !in_y;
            {r, g, b} <= in_x && in_y ? p : 24'hEEEEEE;
        end
    end
endmodule
