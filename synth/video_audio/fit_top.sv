// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Wrapper for the standalone fit: only the clocks are real pins, the rest are virtual pins.
module fit_top (
    input  wire        clk_74a, clk_48m, clk_pix,
    input  wire        v_rst, v_ce_pix, v_hs, v_vs, v_hblank, v_vblank, v_width320, v_pal,
    input  wire [7:0]  v_r, v_g, v_b,
    input  wire [2:0]  v_slot,
    output wire [23:0] v_rgb,
    output wire        v_de, v_hso, v_vso, v_err,
    input  wire        a_rst,
    input  wire [15:0] a_l, a_r,
    output wire        a_mclk, a_lrck, a_dac
);
    wire unused_clk, unused_clk90, unused_skip;
    video_out vo (
        .rst(v_rst), .CLK_48M(clk_48m), .ce_pix(v_ce_pix), .r(v_r), .g(v_g), .b(v_b),
        .hs(v_hs), .vs(v_vs), .hblank(v_hblank), .vblank(v_vblank),
        .width320(v_width320), .slot(v_slot), .pal(v_pal),
        .CLK_PIX(clk_pix), .CLK_PIX_90(clk_pix),
        .video_rgb(v_rgb), .video_rgb_clock(unused_clk), .video_rgb_clock_90(unused_clk90),
        .video_de(v_de), .video_hs(v_hso), .video_vs(v_vso), .video_skip(unused_skip), .fifo_err(v_err)
    );
    audio_i2s ai (
        .clk_74a(clk_74a), .clk_48m(clk_48m), .rst(a_rst), .l(a_l), .r(a_r),
        .audio_mclk(a_mclk), .audio_lrck(a_lrck), .audio_dac(a_dac)
    );
endmodule
