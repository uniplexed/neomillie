// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// An estimate, on the real mux and memory models, of how often the 68K waits for CRAM0 in the cart core, by kind of game.
// It checks nothing and always passes: it prints a table.
//
// The traffic is a model, not a game. Its rates are set to the figures measured on the Pocket with the wait counter
// (Metal Slug X, first mission): 32,200 ROM reads a frame, the fix on 224 of 264 lines and 320 of 384 pixels. Z80_GAP and the
// share of the bus cycles were tuned against that game's lost clocks. The 68K's bus cycles are locked to the video clocks, by a
// phase this bench does not know, so every run is made at four phases.
`timescale 1ns/1ps

module tb_cart_contention;
`include "mem_map.svh"

    localparam real PERIOD = 10.34;
    localparam int  LINE_CLKS = 6144, LINES = 264, FRAME = LINE_CLKS * LINES, FRAMES = 1;
    localparam int  Z80_GAP = 70;               // mean clocks between two Z80 byte reads
    localparam int  ROM_SHARE = 63;             // of the 68K's bus cycles, in percent: 32,200 of about 51,000 a frame

    logic clk = 0, clk48 = 0;
    always #(PERIOD / 2) begin
        clk = ~clk;
        if (clk) clk48 = ~clk48;
    end

    logic        nRESET = 0, mem_init = 1, PCK2 = 1, FIX_EN = 0, nAS = 1, nROMOE = 1, DL_EN = 0, DL_WR = 0, m1_req = 0;
    logic [20:1] M68K_ADDR = 0;
    logic [15:0] S_LATCH = 0;
    logic [26:0] DL_ADDR = 0;
    logic  [7:0] DL_INDEX = 0;
    logic [18:0] m1_addr = 0;

    wire  [15:0] PROM_DATA, fx_wdata, fx_rdata;
    wire  [16:0] fx_word;
    wire   [1:0] fx_be;
    wire         PROM_DATA_READY, m1_ack, fx_req, fx_we, fx_ack;
    tri   [15:0] c0_dq, c1_dq, dram_dq, s_dq;
    wire [21:16] c0_a;
    wire  [16:0] s_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb, s_oe, s_we, s_ub, s_lb;

    pocket_mem_mux #(.ROM_SRAM(1), .M1_CACHE(1), .FIX_CACHE(1), .READY_COMB(1)) dut (
        .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(1'b1), .SYSTEM_CDx(1'b0),
        .M68K_ADDR(M68K_ADDR), .M68K_DATA(16'h0), .nAS(nAS), .nLDS(1'b1), .nUDS(1'b1),
        .nROMOE(nROMOE), .nPORTOE(1'b1), .nSROMOE(1'b1), .P2ROM_ADDR(27'h0),
        .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
        .PCK2(PCK2), .S_LATCH(S_LATCH), .FIX_BANK(2'b0), .FIX_EN(FIX_EN),
        .PCK1(1'b1), .CROM_ADDR(27'h0), .SPR_EN(1'b0), .REFRESH_EN(1'b0),
        .DL_EN(DL_EN), .DL_DATA(16'h0), .DL_ADDR(DL_ADDR), .DL_WR(DL_WR), .DL_INDEX(DL_INDEX),
        .CD_TR_AREA(3'b0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
        .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'b0),
        .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
        .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
        .fx_req(fx_req), .fx_we(fx_we), .fx_word(fx_word), .fx_be(fx_be), .fx_wdata(fx_wdata), .fx_ack(fx_ack), .fx_rdata(fx_rdata),
        .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0),
        .adpcma_addr(25'h0), .adpcma_req(1'b0), .adpcmb_addr(25'h0), .adpcmb_req(1'b0), .v2_offset(24'h0),
        .m1_addr(m1_addr), .m1_req(m1_req), .m1_ack(m1_ack),
        .BK_RD(1'b0), .BK_WR(2'b00), .bk_req(1'b0), .bk_we(1'b0), .bk_addr(15'd0), .bk_wdata(16'd0), .bk_ack(), .bk_rdata(), .ROM_COPY_BUSY(),
        .dram_dq(dram_dq),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_dq(c1_dq), .cram1_wait(1'b0)
    );

    psram_model #(.POLL_NS(1.0), .QUIET(1)) mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_cram0.dq_oe)
    );
    sram_port u_sram (
        .clk(clk48), .req(fx_req), .we(fx_we), .word(fx_word), .be(fx_be), .wdata(fx_wdata), .ack(fx_ack), .rdata(fx_rdata),
        .sram_a(s_a), .sram_dq(s_dq), .sram_oe_n(s_oe), .sram_we_n(s_we), .sram_ub_n(s_ub), .sram_lb_n(s_lb)
    );
    sram_model #(.POLL_NS(2.0), .QUIET(1)) mem_s (
        .a(s_a), .dq(s_dq), .oe_n(s_oe), .we_n(s_we), .ub_n(s_ub), .lb_n(s_lb), .fpga_dq_oe(u_sram.dq_oe), .cut_write_ok(1'b0)
    );

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
        #1;
    endtask

    // Runs until this falls
    bit running = 0;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // The cost of a scenario
    int reads = 0, waited = 0, lost48 = 0, at_fix = 0, at_z80 = 0, at_other = 0, z_reads = 0, m1_hits = 0, fix_hits = 0, fix_reads = 0;
    int fix_worst = 0;

    always @(posedge clk) if (running) begin
        if (dut.m1c_hit && m1_req != m1_ack) m1_hits++;
        if (dut.fixc_hit) fix_hits++;
    end

    task automatic pck2_client(input int hot);
        // The first fall of a run only aligns Z80_WINDOW: on the console PCK2 never stops
        tick(3); PCK2 = 0; tick(61); PCK2 = 1;
        while (running) begin
            automatic int y = int'((cyc / LINE_CLKS) % LINES);
            automatic int x = int'(cyc % LINE_CLKS);
            automatic logic [11:0] tile = $urandom_range(99) < hot ? 12'h020 : 12'(12'h100 + $urandom_range(255));
            automatic int lat = 0;
            FIX_EN = y < 224 && x < 5120;
            S_LATCH = {tile, ~y[0], y[2:0]};
            tick(3);
            PCK2 = 0;
            if (FIX_EN) begin
                fix_reads++;
                tick;
                while (dut.fix_pend || (dut.c0_req && dut.c0_owner == 2) || (dut.fx_run && dut.fx_owner == 0)) begin tick; lat++; end
                if (lat + 1 > fix_worst) fix_worst = lat + 1;
                tick(61 - lat - 1 > 0 ? 61 - lat - 1 : 1);
            end else tick(61);
            PCK2 = 1;
        end
    endtask

    task automatic z80_client(input int upper_share, input int upper_base, input int upper_size);
        int a = 'h100, lat, bank = 0, since = 0;
        while (running) begin
            if ($urandom_range(4) == 0) begin      // a jump, into code or into a sound bank
                if ($urandom_range(99) < upper_share) begin
                    if (since++ > 300) begin bank = $urandom_range(upper_size / 'h4000 - 1); since = 0; end
                    a = upper_base + bank * 'h4000 + $urandom_range('h3FFF);
                end else a = $urandom_range('h7FFF);
            end else a++;
            m1_addr = 19'(a);
            m1_req = ~m1_req;
            lat = 0;
            while (m1_ack != m1_req && running) begin tick; lat++; end
            z_reads++;
            tick($urandom_range(2 * Z80_GAP));
        end
        m1_req = m1_ack;
    endtask

    task automatic cpu_client(input int phase);
        while (int'(cyc % 64) != phase) tick;
        while (running) begin
            automatic int len = 32, w = 0, lat = 0;
            if ($urandom_range(99) < ROM_SHARE) begin
                M68K_ADDR = 20'($urandom);
                nAS = 0; nROMOE = 0;
                tick;
                while (!PROM_DATA_READY && lat < 300) begin tick; lat++; end
                lat++;
                reads++;
                if (lat > 12) begin
                    w = (lat - 12 + 7) / 8;
                    waited++;
                    lost48 += w * 4;
                    case (dut.dbg_at_req)
                        2'd2:    at_fix++;
                        2'd3:    at_z80++;
                        default: at_other++;
                    endcase
                end
                len += w * 8;
                tick(len - lat - 4 > 0 ? len - lat - 4 : 1);
                nAS = 1; nROMOE = 1;
                tick(4);
            end else tick(len);
        end
        nAS = 1; nROMOE = 1;
    endtask

    task automatic set_s(input bit big);
        nRESET = 0;
        tick(2200);         // empties the caches
        DL_EN = 1;
        DL_INDEX = 8'd8; DL_ADDR = big ? 27'h3FFFE : 27'd0; DL_WR = 1;
        tick;
        DL_WR = 0;
        tick(16);           // DL_EN stays up: the copy would only move data this bench does not look at
        nRESET = 1;
        tick(8);
    endtask

    task automatic run(input string name, input int phase, input bit big, input int upper_share, input int upper_base, input int upper_size, input int hot);
        reads = 0; waited = 0; lost48 = 0; at_fix = 0; at_z80 = 0; at_other = 0; z_reads = 0; m1_hits = 0; fix_hits = 0; fix_reads = 0; fix_worst = 0;
        set_s(big);
        begin
            automatic int acc0 = mem_c0.access_count;
            running = 1;
            fork
                pck2_client(hot);
                z80_client(upper_share, upper_base, upper_size);
                cpu_client(phase);
                begin tick(FRAME * FRAMES); running = 0; end
            join
            tick(200);
            $display("phase %2d  %-34s lost %6.3f%%  waits/frame %6d (fix %5d, Z80 %5d, other %4d)  reads %6d  CRAM0 use %5.1f%%  Z80 reads %6d  M1 hit %3d%%  fix hit %3d%%  fix worst %2d",
                     phase, name, 100.0 * lost48 / real'(FRAME * FRAMES / 2), waited / FRAMES, at_fix / FRAMES, at_z80 / FRAMES, at_other / FRAMES,
                     reads / FRAMES, 100.0 * (mem_c0.access_count - acc0) * 12 / real'(FRAME * FRAMES), z_reads / FRAMES,
                     z_reads ? 100 * m1_hits / z_reads : 0, fix_reads ? 100 * fix_hits / fix_reads : 0, fix_worst);
        end
    endtask

    initial begin
        tick(8);
        mem_init = 0;
        tick(8);
        for (int p = 0; p < 32; p += 8) begin
            run("S<=128, M1<=128 (199 of 242)", p, 0, 0, 0, 'h4000, 85);
            run("S 128, M1 256, as KOF '98", p, 0, 15, 'h20000, 'h20000, 85);
            run("S 512, M1 256, as Garou", p, 1, 0, 0, 'h4000, 85);
            run("S 128, M1 512, as Metal Slug 5", p, 0, 15, 'h20000, 'h60000, 85);
            run("S 512, M1 512, as KOF 2003", p, 1, 15, 'h40000, 'h40000, 85);
            run("S 512, M1 512, half in banks", p, 1, 50, 'h40000, 'h40000, 60);
        end
        $display("PASS tb_cart_contention");
        $finish;
    end
endmodule
