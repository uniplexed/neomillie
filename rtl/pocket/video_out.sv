// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The scaler convention follows the video block of Neogeo.sv in Mazamars312's Neo Geo Overdrive for
// Pocket (which runs on real Pockets, and whose README allows free use): the picture is 304 or 320
// pixels wide, 224 lines high, the width is chosen per line, and the scaler mode slot is sent as
// a pixel with video_rgb[15:13] = slot on the first pixel clock after DE falls on each active line.
// His video.json is used unchanged (pocket/neogeo/video.json). The implementation is new.

// Video output of the Neo Geo core for the Analogue Pocket.
//
// In: the pixel stream of MiSTer's video_cleaner at ce_pix (a one CLK_48M pulse every 8 clocks, 6 MHz),
// whole line of 384 pixels with hblank and vblank, 264 (NTSC) or 312 (PAL) lines.
// Out: the APF video pins, registered on CLK_PIX (CLK_96M / 16, the same 6 MHz rate).
//
// DE is regenerated from the core's own blanking (hblank low for 320 pixels, vblank for the
// window), as MiSTer's output does, not from porches after a sync pulse as in the Overdrive.
//
// Horizontal. The Overdrive restarts x_count on the falling edge of his positive HSYNC, the trailing
// end of the pulse, which videosync.v puts 28 pixels before hblank falls (measured with
// videosync.v and clocks.v of the pinned submodule: HSYNC pulse 28 pixels, hblank low 320).
// His base porch (30 in 320 mode, 38 in 304) counts from that edge, and his default X position
// slider of -2 makes it 32 and 40. His palette path has 4 pixel registers where MiSTer's has 2,
// so, by counting registers (not simulated), the Overdrive's 320 mode starts at DE index 2 of this
// module and his 304 mode covers DE indices 10..313: this picture sits about 2 pixels to the right
// of the Overdrive's at its default. There are no X/Y sliders yet.
// Cropping to 304 removes 8 pixels on each side, which are the pixels neogeo.sv blanks when
// status[16] is set (pxcnt outside 7..310; by my reading of neogeo.sv:2017-2031 and
// video_cleaner.sv the cleaned hblank falls one pixel before pxcnt 0, so these are pixels 8..311
// of the DE window; not simulated end to end).
//
// Vertical. The Overdrive's VSYNC is ~(VMODE ? BLANK_PAL : RASTERC[8]) and he restarts his line
// count on its falling edge, the trailing end of an 8 line pulse, and opens DE 16 (NTSC) or 43
// (PAL) lines later. The trailing edge is raster line 0x100 in NTSC (RASTERC[8] rising) and 0xE5
// in PAL (BLANK_PAL, 27 lines before the window), so his picture starts at line 0x110 in both.
// MiSTer's blank-free window (BNKB) is 256 lines in PAL, from 0x100, and in NTSC the 224 lines
// from 0x110. So NTSC shows the whole window and PAL skips its first 16 lines and drops the last 16,
// a symmetric crop. Measured with videosync.v: 27 lines from the PAL trailing edge to the window,
// 16 in NTSC. Not confirmed on hardware.
//
// Clock crossing: CLK_48M with ce_pix and CLK_PIX come from one VCO, with an exact ratio of 8 and
// a fixed but unknown phase; STA closes the paths between them, so what has to hold is the pointer
// window, not a timing race. Every pixel word is written into a ring of 4 entries (CLK_48M, at
// ce_pix) and read once per CLK_PIX. The write pointer crosses as a 2 bit Gray code through two
// flops. The reader does not wait for a fill level: it seeds its read pointer from the observed
// write pointer once after reset, at the next write index p plus 1: the oldest live entry of the
// ring. That puts it 1 to 3 pixel times behind the writer (the sync adds 2 to 3, a missed capture
// one more) in a window of 0 to 4, so there is 1 pixel time to either side. After that both pointers advance once per pixel
// and nothing is compared. A pointer difference two entries off nominal sets fifo_err and seeds
// the reader again.
//
// width320, slot and pal come from clk_74a (quasi-static, written by the bridge) and cross through
// two flops each; they are latched per line during hblank, like the Overdrive's res_reg. The bits
// cross independently, so on a change of setting a line can see a mix of old and new bits, for
// one line; that is harmless.
module video_out (
    input  wire        rst,             // any domain; held through a PLL relock
    input  wire        CLK_48M,
    input  wire        ce_pix,
    input  wire [7:0]  r, g, b,
    input  wire        hs, vs,          // positive pulses
    input  wire        hblank, vblank,
    input  wire        width320,        // APF_Video_ratio[2], 1 = 320 wide; status[16] = ~width320
    input  wire [2:0]  slot,            // APF_Video_ratio[2:0], the scaler mode
    input  wire        pal,             // status[3]
    input  wire        CLK_PIX,
    input  wire        CLK_PIX_90,

    output reg  [23:0] video_rgb = 0,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output reg         video_de = 0,
    output reg         video_hs = 0,
    output reg         video_vs = 0,
    output wire        video_skip,
    output reg         fifo_err = 0     // sticky, CLK_PIX
);

assign video_rgb_clock    = CLK_PIX;
assign video_rgb_clock_90 = CLK_PIX_90;
assign video_skip         = 1'b0;

// ---- Reset and configuration into the CLK_48M domain ----

reg [1:0] rst_w = 2'b11;
always @(posedge CLK_48M) rst_w <= {rst_w[0], rst};

reg [4:0] cfg_s1 = 0, cfg_s2 = 0;      // {pal, slot, width320}
always @(posedge CLK_48M) {cfg_s2, cfg_s1} <= {cfg_s1, pal, slot, width320};

// ---- DE, slot word and sync pulses, CLK_48M at ce_pix ----

localparam [8:0] SKIP_PAL = 9'd16;
localparam [8:0] LINES    = 9'd224;

reg        old_hbl = 1, old_hs = 0, old_vs = 0, was_de = 0;
reg [8:0]  hc = 0;                      // pixels since hblank fell, index of the current pixel
reg [8:0]  yc = 0;                      // active lines completed in this frame
reg        w320_l = 1, pal_l = 0;
reg  [2:0] slot_l = 0;
reg  [2:0] hs_sr = 0;

wire       de_h = !hblank && (w320_l || (hc >= 9'd8 && hc < 9'd312));
wire [8:0] y0   = pal_l ? SKIP_PAL : 9'd0;
wire       de_v = !vblank && yc >= y0 && yc < y0 + LINES;
wire       de_n = de_h && de_v;
wire       fall = was_de && !de_n;

wire [26:0] word = {de_n, hs_sr[2], vs && !old_vs,
                    de_n ? {r, g, b} : (fall ? {8'd0, slot_l, 13'd0} : 24'd0)};

(* ramstyle = "logic" *) reg [26:0] mem [0:3];   // registers, not M10K: 4 words, read asynchronously
reg  [1:0] wptr = 0, wg = 0;

always @(posedge CLK_48M) begin
    if (rst_w[1]) begin
        wptr <= 0;
        wg   <= 0;
    end else if (ce_pix) begin
        old_hbl <= hblank;
        old_hs  <= hs;
        old_vs  <= vs;
        was_de  <= de_n;
        hs_sr   <= {hs_sr[1:0], hs && !old_hs};
        hc      <= hblank ? 9'd0 : (hc == 9'd511 ? hc : hc + 1'b1);
        if (hblank && !old_hbl) yc <= vblank ? 9'd0 : (yc == 9'd511 ? yc : yc + 1'b1);
        if (hblank) {pal_l, slot_l, w320_l} <= cfg_s2;
        mem[wptr] <= word;
        wptr      <= wptr + 1'b1;
        wg        <= (wptr + 1'b1) ^ ((wptr + 1'b1) >> 1);
    end
end

// ---- Read side, CLK_PIX ----

reg [1:0] rst_r = 2'b11;
reg [1:0] s1 = 0, s2 = 0;
reg       started = 0;
reg [1:0] rptr = 0;
wire[1:0] p = {s2[1], s2[1] ^ s2[0]};
wire[1:0] d = p - rptr;

always @(posedge CLK_PIX) begin
    rst_r <= {rst_r[0], rst};
    s1    <= wg;
    s2    <= s1;
    if (rst_r[1]) begin
        started <= 0;
        fifo_err <= 0;
        {video_de, video_hs, video_vs, video_rgb} <= 0;
    end else if (!started) begin
        {video_de, video_hs, video_vs, video_rgb} <= 0;
        if (s2 != 0) begin
            started <= 1;
            rptr    <= p + 2'd1;
        end
    end else begin
        rptr <= rptr + 1'b1;
        {video_de, video_hs, video_vs, video_rgb} <= mem[rptr];
        if (d == 2'd2) begin
            fifo_err <= 1;
            started  <= 0;
        end
    end
end

endmodule
