// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The end of memtest's mixed test: a client must not be left half started when the step ends. Many
// very short mixed steps, so that the last clock lands on every client's phase; the sweeps in
// between are cut down to almost nothing. Good memory must give no error on row 3 and no hang.
`timescale 1ns/1ps
module tb_memtest_mixend;

    localparam int R_MIX = 2;
    localparam int RUNS = 600;
    localparam int FORCED = 100;

    logic clk = 0, mem_init = 1, start = 0;
    always #5.17 clk = ~clk;

    tri   [15:0] dram_dq, c0_dq, c1_dq;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire         c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;

    wire [4:0][31:0] res_err, res_addr;
    wire [4:0][15:0] res_pass, res_got, res_exp;

    memtest #(.SPAN_BITS(2), .RET_BITS(9), .RET_REGION_BITS(4), .MIX_BITS(9), .FILE_BITS(2), .FILL_BITS(7),
              .TICKS_PER_SECOND(1000)) dut (
        .clk(clk), .mem_init(mem_init), .start(start), .bw_tog(1'b0), .bw_addr(32'd0), .bw_data(32'd0),
        .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_wait(1'b0), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv),
        .cram1_cre(c1_cre), .cram1_ce0_n(c1_ce0), .cram1_ce1_n(c1_ce1), .cram1_oe_n(c1_oe), .cram1_we_n(c1_we),
        .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb)
    );

    sdram_model mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    psram_model #(.IO_NS(11.47)) mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_mux.u_cram0.dq_oe)
    );
    psram_model #(.IO_NS(11.47)) mem_c1 (
        .a(c1_a), .dq(c1_dq), .clk(c1_clk), .cre(c1_cre), .adv_n(c1_adv), .ce0_n(c1_ce0), .ce1_n(c1_ce1),
        .oe_n(c1_oe), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb), .fpga_dq_oe(dut.u_mux.u_cram1.dq_oe)
    );

    // A hang shows here: a loop is about 2,000 clocks
    int last_pass = 0, idle = 0;
    always @(posedge clk) begin
        if (int'(res_pass[R_MIX]) != last_pass) begin
            last_pass = int'(res_pass[R_MIX]);
            idle = 0;
        end else if (start) begin
            idle++;
            if (idle > 200000) $fatal(1, "hung: step %0d kind st %0d seq step %0d rd_st %0d after %0d runs",
                                      dut.step, dut.st, dut.sq_step, dut.rd_st, last_pass);
        end
    end

    // Which clock of the 64 clock line each mixed step ends on, and what it leaves behind
    int end_phase [64];
    int left_fix = 0, left_spr = 0, left_68k = 0, left_z80 = 0;
    always @(posedge clk) if (dut.st == dut.S_NEXT && dut.step == dut.STEP_MIX) begin
        end_phase[(int'(dut.mt) - 1) & 63]++;
        if (dut.fix_on) left_fix++;
        if (dut.spr_on) left_spr++;
        if (dut.m_on)   left_68k++;
        if (dut.z_on)   left_z80++;
    end

    initial begin
        #200_000_000;
        $fatal(1, "timeout");
    end

    int reported = 0;
    always @(posedge clk) if (int'(res_err[R_MIX]) != 0 && reported == 0) begin
        reported = 1;
        $display("first row 3 error after %0d runs: first %08x got %04x exp %04x, step %0d, %0d clocks into the step, previous grant owner %0d word %06x, state at request %07x",
                 last_pass, res_addr[R_MIX], res_got[R_MIX], res_exp[R_MIX], dut.step, dut.mt,
                 dut.prev_grant[24:23], dut.prev_grant[22:0], dut.bad_snap);
    end

    initial begin
        repeat (20) @(posedge clk);
        #1 mem_init = 0;
        #130_000;
        start = 1;
        // One whole loop for the fills, then straight back to the mixed test after each sequence test
        wait (int'(dut.loops) == 1);
        repeat (RUNS) begin
            wait (dut.st == dut.S_STEP && dut.step == dut.STEP_C0_WALK_WR);
            dut.step = dut.STEP_MIX;
            @(posedge clk);
            @(posedge clk);
        end
        wait (int'(res_pass[R_MIX]) >= RUNS);
        // Then the end of the step pushed onto the clock PCK2 falls: the sprite client held busy
        // up to it, so that the first idle clock is that one, as other clients can do on their own.
        // First half with no new 68K read in that window, second half with them.
        for (int i = 0; i < FORCED; i++) begin
            wait (dut.st == dut.S_STEP && dut.step == dut.STEP_C0_WALK_WR);
            dut.step = dut.STEP_MIX;
            wait (dut.st == dut.S_RUN && dut.step == dut.STEP_MIX && int'(dut.mt) == (1 << 9) - 1);
            force dut.spr_on = 1'b1;
            if (i < FORCED / 2) force dut.m_t = 8'd0;
            wait (int'(dut.mt) == (1 << 9) + 32);
            release dut.spr_on;
            release dut.m_t;
            @(posedge clk);
            @(posedge clk);
        end
        wait (int'(res_pass[R_MIX]) >= RUNS + FORCED);
        repeat (3) @(posedge clk);
        $display("%0d mixed steps ended, row 3 errors %0d, worst clocks fix %0d sprite %0d",
                 res_pass[R_MIX], res_err[R_MIX], dut.lat[31:24], dut.lat[23:16]);
        $display("left running at the end: fix %0d sprite %0d 68K %0d Z80 %0d", left_fix, left_spr, left_68k, left_z80);
        for (int i = 0; i < 64; i++) if (end_phase[i] != 0) $display("  steps ending on clock %0d of the line: %0d", i, end_phase[i]);
        if (res_err[R_MIX] != 0) $fatal(1, "row 3 errors on good memory");
        if (mem_c0.error_count != 0 || mem_c1.error_count != 0 || mem_sd.error_count != 0) $fatal(1, "model errors");
        $display("PASS tb_memtest_mixend");
        $finish;
    end
endmodule
