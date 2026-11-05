// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Measures the deadlines of the memory mux on MiSTer's own RTL: lspc2_a2 and clocks wired as in
// neogeo.sv, with no ROM or VRAM behind them. Prints, in clocks of CLK_96M from the edge that
// makes PCK1/PCK2 fall, when neo_b1 (FIXD_REG on CLK_EN_1HB) and zmc2_dot (SR on CLK_EN_12M_N with
// LOAD) next sample the data, and fails if these differ from the values sim/mem uses. With no VRAM
// behind it the sprite is not flipped: SPR_TILE_HFLIP swaps which half of CR_DOUBLE CA4 picks, so
// the first load may take either half and the whole burst is due by then.
`timescale 1ns/1ps
module tb_lspc_timing;
    // Same values as the named parameters in sim/mem/tb_pocket_mem_mux.sv
    localparam int PCK_PERIOD = 64;
    localparam int PCK_HIGH   = 4;
    localparam int FIX_FIRST  = 24;
    localparam int SPR_FIRST  = 28;

    logic clk96 = 0, clk48 = 0;
    always #5.17 clk96 = ~clk96;
    always @(posedge clk96) clk48 <= ~clk48;

    // neogeo.sv lines 196-199
    logic en24n = 0, en24p = 0;
    always @(posedge clk48) begin
        en24n <= ~en24n;
        en24p <= en24n;
    end

    logic nreset = 0;
    wire  [15:0] pbus_out;
    wire  [23:16] pbus_io;
    wire  [15:0] m68k_data;
    wire  ca4, s2h1, s1h1, load, h, even1, even2, pck1, pck2, pck1_en_p, pck2_en_p, pck1_en_n, pck2_en_n, nresetp;

    lspc2_a2_sync lspc (
        .CLK(clk48), .CLK_EN_24M_P(en24p), .CLK_EN_24M_N(en24n), .RESET(nreset),
        .PBUS_OUT(pbus_out), .PBUS_IO(pbus_io), .M68K_ADDR(3'd0), .M68K_DATA(m68k_data), .LSPOE(1'b1), .LSPWE(1'b1),
        .DOTA(1'b0), .DOTB(1'b0), .CA4(ca4), .S2H1(s2h1), .S1H1(s1h1), .LOAD(load), .H(h), .EVEN1(even1), .EVEN2(even2),
        .CD_VBLANK_IRQ_EN(1'b1), .CD_TIMER_IRQ_EN(1'b1),
        .PCK1(pck1), .PCK2(pck2), .PCK1_EN_P(pck1_en_p), .PCK2_EN_P(pck2_en_p), .PCK1_EN_N(pck1_en_n), .PCK2_EN_N(pck2_en_n),
        .nRESETP(nresetp), .SVRAM_DATA_IN(32'h0), .FVRAM_DATA_IN(16'h0), .VMODE(1'b0)
    );

    wire clk_en_12m_n, clk_en_1hb;
    clocks_sync clks (
        .CLK(clk48), .CLK_EN_24M_P(en24p), .CLK_EN_24M_N(en24n), .nRESETP(nresetp),
        .CLK_EN_12M_N(clk_en_12m_n), .CLK_EN_1HB(clk_en_1hb)
    );

    initial begin
        #100_000;
        $fatal(1, "timeout");
    end

    // Clocks of 96 MHz are counted at clk48 edges. A signal read at a clk48 edge holds what the
    // previous clk48 edge launched, so a fall seen here was launched 2 clocks ago.
    longint t = 0, pck1_t = -1, pck2_t = -1, prev_pck1_t = -1, prev_pck2_t = -1;
    longint pck2_rise_t = -1;
    logic   pck1_d = 0, pck2_d = 0, s1h1_d = 0;
    int     seen = 0, fix_n = 0, spr_n = 0, s1h1_n = 0, high2 = 0;
    int     period1 = 0, period2 = 0, pulse2 = 0, fix_first = -1, spr_first = -1, phase = 0;
    bit     stable = 0;

    always @(posedge clk48) begin
        t += 2;
        pck1_d <= pck1;
        pck2_d <= pck2;
        s1h1_d <= s1h1;
        if (!pck2_d && pck2) pck2_rise_t = t - 2;
        // Overdrive's neo_b1.v samples on negedge S1H1 instead of CLK_EN_1HB
        if (s1h1_d && !s1h1 && pck2_t > 0 && stable && s1h1_n < 2) begin
            $display("PCK2 fall + %0d: S1H1 falls, S2H1 is %0d", int'(t - 2 - pck2_t), s2h1);
            s1h1_n++;
        end
        if (nreset && t > 4000) stable = 1;
        if (pck2_d && !pck2) begin
            prev_pck2_t = pck2_t;
            pck2_t = t - 2;
            fix_n = 0;
            if (prev_pck2_t > 0) period2 = int'(pck2_t - prev_pck2_t);
            if (pck2_rise_t > 0) high2 = int'(pck2_t - pck2_rise_t);
            if (pck1_t > 0) phase = int'(pck2_t - pck1_t);
        end
        if (pck1_d && !pck1) begin
            prev_pck1_t = pck1_t;
            pck1_t = t - 2;
            spr_n = 0;
            if (prev_pck1_t > 0) period1 = int'(pck1_t - prev_pck1_t);
        end
        // neo_b1.v: FIXD_REG <= FIXD on CLK_EN_1HB; neogeo.sv: FIXD = S2H1 ? [15:8] : [7:0]
        if (clk_en_1hb && pck2_t > 0 && stable && seen < 12) begin
            $display("PCK2 fall + %0d: FIXD_REG samples SROM_DATA[%s]", int'(t - pck2_t), s2h1 ? "15:8" : "7:0");
            if (fix_n == 0) fix_first = int'(t - pck2_t);
            fix_n++;
            seen++;
        end
        // zmc2_dot.v: SR <= CR on CLK_EN_12M_N with LOAD; neogeo.sv: CR = CA4 ? [63:32] : [31:0]
        if (clk_en_12m_n && load && pck1_t > 0 && stable && seen < 12) begin
            $display("PCK1 fall + %0d: SR loads CR_DOUBLE[%s]", int'(t - pck1_t), ca4 ? "63:32" : "31:0");
            if (spr_n == 0) spr_first = int'(t - pck1_t);
            spr_n++;
            seen++;
        end
    end

    initial begin
        repeat (40) @(posedge clk48);
        nreset = 1;
        wait (seen >= 12);
        $display("PCK1 period %0d, PCK2 period %0d, PCK2 high %0d, PCK2 falls %0d after PCK1", period1, period2, high2, phase);
        $display("first sample: fix %0d, sprite %0d", fix_first, spr_first);
        if (period1 != PCK_PERIOD || period2 != PCK_PERIOD || high2 != PCK_HIGH) $fatal(1, "PCK period");
        if (fix_first != FIX_FIRST) $fatal(1, "fix offset %0d", fix_first);
        if (spr_first != SPR_FIRST) $fatal(1, "sprite offset %0d", spr_first);
        $display("PASS tb_lspc_timing");
        $finish;
    end
endmodule
