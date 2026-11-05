// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// video_out against the frame stub, in 18 cases that differ in what the design can see: NTSC and PAL,
// 320 and 304 wide, a different slot, and for the main ones all 8 phases of ce_pix against CLK_PIX
// (CLK_PIX is CLK_48M/8 as in the PLL, so the phase between them is a whole number of CLK_48M
// clocks). Each case runs 3 full frames and checks, from the signals of the APF alone:
//   active window   DE lines per frame, DE pixels per line (320 or 304), every pixel is the one
//                   the stub drew at that position of the picture
//   fifo            no pointer error flag, exactly 384 x lines pixel clocks between frame starts
//   slot word       the first pixel after DE falls, on active lines, is {8'd0, slot, 13'd0}; all
//                   other pixels outside DE are 0
//   sync            hs once per line, vs once per frame, both one pixel wide
// The pixel clock half period is a parameter so that a run with a slightly fast CLK_PIX
// (an underrun) can be shown to fail.
`timescale 1ns/1ps
module vo_case #(
    parameter int         PHASE = 0,
    parameter bit         PAL   = 0,
    parameter bit         W320  = 1,
    parameter bit [2:0]   SLOT  = 3'd5
) (
    input  wire         clk48,
    input  wire         clk_pix,
    input  wire         clk_pix90,
    input  wire         rst,
    output logic        done = 0,
    output int          e_win = 0, e_pix = 0, e_slot = 0, e_sync = 0, e_fifo = 0, e_clk = 0
);
    import vo_pkg::*;

    localparam int LINES = PAL ? 312 : 264;
    localparam int XOFF  = W320 ? 0 : 8;
    // lines of the 224 line window skipped at the top: where the Overdrive's picture starts, from his
    // porch and the raw VSYNC of the stub, not from a constant of video_out
    localparam int YOFF  = overdrive_first_line(PAL) - act_y0(PAL);
    localparam int WIDTH = W320 ? 320 : 304;

    // ce_pix: one CLK_48M pulse every 8 clocks, at the phase of this case
    logic [2:0] c8 = PHASE[2:0];
    logic       ce_pix = 0;
    always @(posedge clk48) begin
        c8     <= c8 + 1'b1;
        ce_pix <= c8 == 3'd7;
    end

    wire [7:0] r, g, b;
    wire       hs, vs, hblank, vblank;
    lspc_timing_stub #(.PAL(PAL)) stub (
        .CLK_48M(clk48), .ce_pix(ce_pix), .rst(rst),
        .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank)
    );

    wire [23:0] video_rgb;
    wire        rgb_clk, rgb_clk90, de, vhs, vvs, skip, fifo_err;
    video_out dut (
        .rst(rst), .CLK_48M(clk48), .ce_pix(ce_pix), .r(r), .g(g), .b(b),
        .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
        .width320(W320), .slot(SLOT), .pal(PAL),
        .CLK_PIX(clk_pix), .CLK_PIX_90(clk_pix90),
        .video_rgb(video_rgb), .video_rgb_clock(rgb_clk), .video_rgb_clock_90(rgb_clk90),
        .video_de(de), .video_hs(vhs), .video_vs(vvs), .video_skip(skip), .fifo_err(fifo_err)
    );

    always @(posedge clk_pix) begin
        if (rgb_clk !== clk_pix || rgb_clk90 !== clk_pix90) e_clk <= e_clk + 1;
    end

    // ---- Checker, one step per CLK_PIX ----
    logic       prev_de = 0, prev_hs = 0, prev_vs = 0;
    logic       armed = 0;
    int         frames = 0, hc = 0, lc = 0, slots = 0, hs_n = 0, cyc = 0;

    task automatic frame_end();
        if (lc != 224)       e_win  <= e_win + 1;
        if (slots != 224)    e_slot <= e_slot + 1;
        if (hs_n != LINES)   e_sync <= e_sync + 1;
        if (cyc != LINES * 384) e_fifo <= e_fifo + 1;
    endtask

    always @(posedge clk_pix) begin
        prev_de <= de;
        prev_hs <= vhs;
        prev_vs <= vvs;
        if (vhs && prev_hs) e_sync <= e_sync + 1;
        if (vvs && prev_vs) e_sync <= e_sync + 1;
        if (fifo_err) e_fifo <= e_fifo + 1;
        if (vvs && !prev_vs) begin
            if (armed) frame_end();
            armed  <= 1;
            frames <= frames + 1;
            lc     <= 0;
            slots  <= 0;
            hs_n   <= 0;
            cyc    <= 1;
            if (frames == 3) done <= 1;
        end else begin
            cyc <= cyc + 1;
        end
        if (armed) begin
            if (vhs && !prev_hs) hs_n <= hs_n + 1;
            if (de) begin
                if (video_rgb !== px(hc + XOFF, lc + YOFF)) e_pix <= e_pix + 1;
                hc <= hc + 1;
            end else begin
                if (prev_de) begin
                    // the first pixel after DE fell
                    if (hc != WIDTH) e_win <= e_win + 1;
                    if (video_rgb !== {8'd0, SLOT, 13'd0}) e_slot <= e_slot + 1;
                    slots <= slots + 1;
                    lc    <= lc + 1;
                end else if (video_rgb !== 24'd0) begin
                    e_slot <= e_slot + 1;
                end
                hc <= 0;
            end
            if (skip !== 1'b0) e_sync <= e_sync + 1;
        end
    end
endmodule

module tb_video_out;
    // CLK_48M = 48.3357 MHz; the pixel clock is exactly 8 of its periods
    localparam real HALF96 = 5.17;
    localparam real PIX_HALF = 82.72;       // 16 x HALF96 = 8 CLK_48M periods; the underrun run uses a shorter one

    logic clk96 = 0, clk48 = 0, clk_pix = 0, rst = 1;
    always #(HALF96) clk96 = ~clk96;
    always @(posedge clk96) clk48 <= ~clk48;
    always #(PIX_HALF) clk_pix = ~clk_pix;
    wire clk_pix90;
    assign #(PIX_HALF / 2) clk_pix90 = clk_pix;

    localparam int N = 18;
    // case i: 0-7 NTSC 320 at phases 0-7, 8-15 PAL 304 at phases 0-7, 16 NTSC 304, 17 PAL 320
    function automatic bit c_pal(input int i);  return (i >= 8 && i < 16) || i == 17; endfunction
    function automatic bit c_w320(input int i); return i < 8 || i == 17; endfunction

    logic [N-1:0] done;
    int e_win[N], e_pix[N], e_slot[N], e_sync[N], e_fifo[N], e_clk[N];
    for (genvar i = 0; i < N; i++) begin : g
        localparam int PH = i < 16 ? i % 8 : (i == 16 ? 3 : 5);
        localparam bit PL = c_pal(i);
        localparam bit WD = c_w320(i);
        vo_case #(.PHASE(PH), .PAL(PL), .W320(WD), .SLOT(WD ? 3'd4 + 3'(i % 4) : 3'(i % 4))) c (
            .clk48(clk48), .clk_pix(clk_pix), .clk_pix90(clk_pix90), .rst(rst), .done(done[i]),
            .e_win(e_win[i]), .e_pix(e_pix[i]), .e_slot(e_slot[i]), .e_sync(e_sync[i]),
            .e_fifo(e_fifo[i]), .e_clk(e_clk[i])
        );
    end

    int fails = 0;
    function automatic void report(input string name, input int a, input int b2, input int c);
        if (a + b2 + c != 0) begin
            $display("FAIL %s: window %0d, pixel or slot %0d, sync or fifo %0d", name, a, b2, c);
            fails++;
        end else begin
            $display("PASS %s", name);
        end
    endfunction

    initial begin
        repeat (40) @(posedge clk48);
        rst = 0;
        wait (&done);
        repeat (50) @(posedge clk_pix);     // one more look after the last frame start
        begin
            int w = 0, p = 0, s = 0, y = 0, f = 0, pw = 0, pp = 0, ps = 0, py = 0, pf = 0, ck = 0;
            for (int i = 0; i < N; i++) begin
                ck += e_clk[i];
                if (c_pal(i)) begin pw += e_win[i]; pp += e_pix[i]; ps += e_slot[i]; py += e_sync[i]; pf += e_fifo[i]; end
                else          begin w  += e_win[i]; p  += e_pix[i]; s  += e_slot[i]; y  += e_sync[i]; f  += e_fifo[i]; end
            end
            // test_active_window_320x224: DE lines, DE width and every pixel, all cases
            report("test_active_window_320x224", w + pw, p + pp, 0);
            // test_no_fifo_overrun_3_frames: NTSC cases, pixel clock count per frame and the error flag
            report("test_no_fifo_overrun_3_frames", 0, 0, f);
            // test_video_pal_no_underrun: the same for the 312 line frame
            report("test_video_pal_no_underrun", 0, 0, pf);
            // test_scaler_slot_word: slot word and zero blanking, all cases
            report("test_scaler_slot_word", 0, s + ps, 0);
            // sync pulses and the clock outputs
            report("test_sync_pulses_and_clocks", 0, 0, y + py + ck);
        end
        if (fails != 0) $fatal(1, "%0d video_out tests failed", fails);
        $display("video_out: all tests passed (%0d cases)", N);
        $finish;
    end

    initial begin
        #200ms;
        $fatal(1, "timeout");
    end
endmodule
