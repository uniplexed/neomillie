// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// pocket_mem_mux against the three checking memory models. Clients drive 1 ns after the clock
// edge, like registered outputs of the core. Latency is counted from the drive to the first
// clock the correct data is visible, so a wrong word also shows as a miss. Latencies are in
// CLK_96M clocks; the same traffic runs at both CLK_96M frequencies (the ns limits of the
// memories and the refresh interval are what move).
`timescale 1ns/1ps
module tb_pocket_mem_mux;
`include "mem_map.svh"

    localparam real PERIOD_AES = 10.34;     // 96.671316 MHz
    localparam real PERIOD_MVS = 10.417;    // 96.000 MHz
    localparam real REFRESH_NS = 7800.0;
    localparam logic [23:0] V2_OFFSET = 24'hC00000;

    // Video timing, in clocks of CLK_96M, measured on MiSTer's RTL by sim/lspc_timing:
    //   PCK1 and PCK2 fall every PCK_PERIOD, 32 apart (lspc2_a2.v:168-172), high for PCK_HIGH.
    //   neo_b1.v:75 samples FIXD on CLK_EN_1HB (clocks.v:75), first 24 clocks after PCK2 falls.
    //   zmc2_dot.v loads CR on LOAD and CLK_EN_12M_N, first 28 clocks after PCK1 falls. A flipped
    //   sprite takes CR_DOUBLE[31:0] then, so the whole burst is due by that load.
    // A word launched by one edge is seen by a consumer on the next, so the data must be visible
    // one clock before the sample, in the latency this bench counts (drive to visible).
    localparam int PCK_PERIOD   = 64;
    localparam int PCK_HIGH     = 4;
    localparam int PCK1_TO_PCK2 = 32;
    localparam int PCK2_TO_1HB  = 24;
    localparam int PCK1_TO_LOAD = 28;
    localparam int FIX_DEADLINE = PCK2_TO_1HB - 1;
    localparam int SPR_DEADLINE = PCK1_TO_LOAD - 1;

    real    period = PERIOD_AES;
    logic   clk = 0, clk48 = 0;     // CLK_48M rises with every other CLK_96M, in one time step, as the PLL's
    longint cyc = 0;
    always #(period / 2) begin
        clk = ~clk;
        if (clk) clk48 = ~clk48;
    end
    always @(negedge clk) cyc++;

    // ---- DUT inputs ----
    logic        mem_init = 1, nRESET = 0, nSYSTEM_G = 1, SYSTEM_CDx = 0;
    logic [20:1] M68K_ADDR = 0;
    logic        nAS = 1, nROMOE = 1, nPORTOE = 1, nSROMOE = 1;
    logic [26:0] P2ROM_ADDR = 0, CROM_ADDR = 0, DL_ADDR = 0;
    logic        PCK1 = 1, PCK2 = 1, FIX_EN = 1, SPR_EN = 1, REFRESH_EN = 0;
    logic [15:0] S_LATCH = 0, DL_DATA = 0;
    logic  [1:0] FIX_BANK = 0;
    logic        DL_EN = 0, DL_WR = 0;
    logic  [7:0] DL_INDEX = 0;
    logic [24:0] adpcma_addr = 0, adpcmb_addr = 0;
    logic        adpcma_req = 0, adpcmb_req = 0, m1_req = 0;
    logic [18:0] m1_addr = 0;
    logic [2:0]  CD_TR_AREA = 0;
    logic        CD_EXT_WR = 0, CD_EXT_RD = 0, CD_USE_FIX = 0, CD_TR_RD_FIX = 0, CD_TR_WR_FIX = 0;
    logic        CD_USE_SPR = 0, CD_TR_RD_SPR = 0, CD_TR_WR_SPR = 0, DMA_RUNNING = 0;
    logic        CD_TR_WR_PCM = 0, CD_BANK_PCM = 0;
    logic  [1:0] CD_BANK_SPR = 0;
    logic [15:0] M68K_DATA = 0, DMA_DATA_OUT = 0;
    logic        nLDS = 1, nUDS = 1;
    logic [23:0] DMA_ADDR_OUT = 0, DMA_ADDR_IN = 0;

    // ---- DUT outputs and pins ----
    wire  [15:0] PROM_DATA, SROM_DATA;
    wire         PROM_DATA_READY, DMA_SDRAM_BUSY, CD_EXT_WR_READY, CD_PCM_DTACK, dl_overflow;
    wire         fx_req, fx_we, fx_ack;
    wire  [16:0] fx_word;
    wire  [15:0] fx_wdata, fx_rdata;
    wire   [1:0] fx_be;
    wire  [63:0] CR_DOUBLE;
    wire   [7:0] adpcma_dout, adpcmb_dout, m1_dout;
    wire         adpcma_ack, adpcmb_ack, m1_ack;

    tri   [15:0] dram_dq, c0_dq, c1_dq, s_dq;
    wire  [16:0] s_a;
    wire         s_oe, s_we, s_ub, s_lb;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire         c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;

    pocket_mem_mux #(.CD_BUILD(1)) dut (
        .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(nSYSTEM_G), .SYSTEM_CDx(SYSTEM_CDx),
        .M68K_ADDR(M68K_ADDR), .M68K_DATA(M68K_DATA), .nAS(nAS), .nLDS(nLDS), .nUDS(nUDS),
        .nROMOE(nROMOE), .nPORTOE(nPORTOE), .nSROMOE(nSROMOE), .P2ROM_ADDR(P2ROM_ADDR),
        .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
        .PCK2(PCK2), .S_LATCH(S_LATCH), .FIX_BANK(FIX_BANK), .FIX_EN(FIX_EN), .SROM_DATA(SROM_DATA),
        .PCK1(PCK1), .CROM_ADDR(CROM_ADDR), .SPR_EN(SPR_EN), .CR_DOUBLE(CR_DOUBLE), .REFRESH_EN(REFRESH_EN),
        .DL_EN(DL_EN), .DL_DATA(DL_DATA), .DL_ADDR(DL_ADDR), .DL_WR(DL_WR), .DL_INDEX(DL_INDEX), .dl_overflow(dl_overflow),
        .CD_TR_AREA(CD_TR_AREA), .CD_EXT_WR(CD_EXT_WR), .CD_EXT_RD(CD_EXT_RD), .CD_EXT_WR_READY(CD_EXT_WR_READY), .CD_USE_FIX(CD_USE_FIX),
        .CD_TR_RD_FIX(CD_TR_RD_FIX), .CD_TR_WR_FIX(CD_TR_WR_FIX), .CD_BANK_SPR(CD_BANK_SPR),
        .CD_USE_SPR(CD_USE_SPR), .CD_TR_RD_SPR(CD_TR_RD_SPR), .CD_TR_WR_SPR(CD_TR_WR_SPR),
        .CD_TR_WR_PCM(CD_TR_WR_PCM), .CD_BANK_PCM(CD_BANK_PCM), .CD_PCM_DTACK(CD_PCM_DTACK),
        .fx_req(fx_req), .fx_we(fx_we), .fx_word(fx_word), .fx_be(fx_be), .fx_wdata(fx_wdata), .fx_ack(fx_ack), .fx_rdata(fx_rdata),
        .DMA_ADDR_OUT(DMA_ADDR_OUT), .DMA_ADDR_IN(DMA_ADDR_IN), .DMA_DATA_OUT(DMA_DATA_OUT), .DMA_RUNNING(DMA_RUNNING),
        .DMA_SDRAM_BUSY(DMA_SDRAM_BUSY),
        .adpcma_addr(adpcma_addr), .adpcma_dout(adpcma_dout), .adpcma_req(adpcma_req), .adpcma_ack(adpcma_ack),
        .adpcmb_addr(adpcmb_addr), .adpcmb_dout(adpcmb_dout), .adpcmb_req(adpcmb_req), .adpcmb_ack(adpcmb_ack),
        .v2_offset(V2_OFFSET),
        .m1_addr(m1_addr), .m1_dout(m1_dout), .m1_req(m1_req), .m1_ack(m1_ack),
        .BK_RD(1'b0), .BK_WR(2'b00), .bk_req(1'b0), .bk_we(1'b0), .bk_addr(15'd0), .bk_wdata(16'd0), .bk_ack(), .bk_rdata(), .ROM_COPY_BUSY(),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_wait(1'b0), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv),
        .cram1_cre(c1_cre), .cram1_ce0_n(c1_ce0), .cram1_ce1_n(c1_ce1), .cram1_oe_n(c1_oe), .cram1_we_n(c1_we),
        .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb)
    );

    // CLK_NS stays at the shorter period: in clocks it is the strict one for both frequencies
    sdram_model #(.CLK_NS(PERIOD_AES)) mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    psram_model mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_cram0.dq_oe)
    );
    psram_model mem_c1 (
        .a(c1_a), .dq(c1_dq), .clk(c1_clk), .cre(c1_cre), .adv_n(c1_adv), .ce0_n(c1_ce0), .ce1_n(c1_ce1),
        .oe_n(c1_oe), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb), .fpga_dq_oe(dut.u_cram1.dq_oe)
    );

    sram_port u_fix (
        .clk(clk48), .req(fx_req), .we(fx_we), .word(fx_word), .be(fx_be), .wdata(fx_wdata), .ack(fx_ack), .rdata(fx_rdata),
        .sram_a(s_a), .sram_dq(s_dq), .sram_oe_n(s_oe), .sram_we_n(s_we), .sram_ub_n(s_ub), .sram_lb_n(s_lb)
    );
    sram_model mem_s (
        .a(s_a), .dq(s_dq), .oe_n(s_oe), .we_n(s_we), .ub_n(s_ub), .lb_n(s_lb), .fpga_dq_oe(u_fix.dq_oe), .cut_write_ok(1'b0)
    );

    // Watchdog: the whole bench takes about 25 ms of simulated time
    initial begin
        #100_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;

    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
        #1;
    endtask

    // ---- Refresh monitor: gap between AUTO REFRESH commands, spacing of the toggles ----
    bit     rf_on = 0;
    int     rf_cmds = 0, rf_cmds0 = 0, rf_toggles = 0, rf_spacing_min = 1 << 30;
    real    rf_t_last = 0, rf_gap_max = 0;
    longint rf_tog_cyc = 0;
    logic   rf_tog_last = 0;

    always @(posedge clk) if (rf_on) begin
        if (mem_sd.refresh_count != rf_cmds) begin
            if ($realtime - rf_t_last > rf_gap_max) rf_gap_max = $realtime - rf_t_last;
            rf_cmds   = mem_sd.refresh_count;
            rf_t_last = $realtime;
        end
        if (dut.sd_refresh != rf_tog_last) begin
            if (rf_toggles != 0 && cyc - rf_tog_cyc < rf_spacing_min) rf_spacing_min = int'(cyc - rf_tog_cyc);
            rf_toggles++;
            rf_tog_cyc  = cyc;
            rf_tog_last = dut.sd_refresh;
        end
    end

    task automatic rf_window_start();
        rf_gap_max = 0;
        rf_t_last  = $realtime;
    endtask

    // ---- Stale read monitor ----
    // A CD read ranks above the CD write queue, so a read of a word still queued would get the old data:
    // only timing keeps that from happening, and this checks it. A write's time runs from its CD_EXT_WR
    // edge to the clock the queue head starts on the chip.
    longint wq_clk = 0;
    longint wq_edge[$];
    int     wr_to_head_max = 0, stale_reads = 0;

    always @(posedge clk) begin
        wq_clk++;
        if (dut.cd_wr_edge && !dut.cd_wq_full && dut.cd_wr_chip == dut.CHIP_C0) wq_edge.push_back(wq_clk);
        if ((!dut.c0_req || dut.c0_ack) && !dut.dl_c0) begin
            if (dut.want_68k) begin
                for (int p = dut.cd_wq_rp; p != int'(dut.cd_wq_wp); p = (p + 1) & (2 * (1 << dut.CD_WQ_AW) - 1))
                    if (dut.cd_wq[p & ((1 << dut.CD_WQ_AW) - 1)][44:43] == dut.CHIP_C0 &&
                        dut.cd_wq[p & ((1 << dut.CD_WQ_AW) - 1)][40:18] == dut.m68k_word) begin
                        stale_reads++;
                        check(0, $sformatf("stale read: word %h granted while it is still queued", dut.m68k_word));
                    end
            end
            else if (!dut.want_fix && dut.cd_wq_c0) begin
                automatic longint age = wq_clk - wq_edge.pop_front();
                if (age > wr_to_head_max) wr_to_head_max = int'(age);
            end
        end
        if (!nRESET) wq_edge.delete();
    end

    // The same on the SDRAM: a SPR read ranks above the queue too. Runs from the write's edge to the clock the
    // head starts on the chip, and the read's edge is WR_TO_RD after the write's, at the 68K's bus cycle
    longint sd_edge[$];
    int     spr_to_head_max = 0, spr_stale_reads = 0;

    always @(posedge clk) begin
        if (dut.cd_wr_edge && !dut.cd_wq_full && dut.cd_wr_chip == dut.CHIP_SD) sd_edge.push_back(wq_clk);
        if (dut.sd_ready && !dut.sd_rd && !dut.sd_wr && !(dut.crom_pend | dut.req_crom)) begin
            if (dut.tr_spr_pend) begin
                for (int p = dut.cd_wq_rp; p != int'(dut.cd_wq_wp); p = (p + 1) & (2 * (1 << dut.CD_WQ_AW) - 1))
                    if (dut.cd_wq[p & ((1 << dut.CD_WQ_AW) - 1)][44:43] == dut.CHIP_SD &&
                        dut.cd_wq[p & ((1 << dut.CD_WQ_AW) - 1)][42:18] == dut.cd_spr_word) begin
                        spr_stale_reads++;
                        check(0, $sformatf("stale SPR read: word %h granted while it is still queued", dut.cd_spr_word));
                    end
            end
            else if (!dut.dl_sd && dut.cd_wq_sd) begin
                automatic longint age = wq_clk - sd_edge.pop_front();
                if (age > spr_to_head_max) spr_to_head_max = int'(age);
            end
        end
        if (!nRESET) sd_edge.delete();
    end

    // ---- Memory backdoor and patterns ----
    function automatic logic [15:0] hash(int salt, int w);
        logic [31:0] x = (32'(w) + 32'd1) * 32'h9E37_79B1 + 32'(salt) * 32'h0101_0137;
        return x[31:16] ^ x[15:0];
    endfunction

    // Word address of the SDRAM to the model's {bank, row, column}
    function automatic bit [24:0] sd_key(logic [25:1] w);
        return {w[24:23], w[22:10], w[25], w[9:1]};
    endfunction

    function automatic logic [15:0] c0_read(int byte_addr);
        bit [22:0] k = 23'(byte_addr >> 1);
        return mem_c0.mem.exists(k) ? mem_c0.mem[k] : 16'hDEAD;
    endfunction

    function automatic logic [15:0] c1_read(int byte_addr);
        bit [22:0] k = 23'(byte_addr >> 1);
        return mem_c1.mem.exists(k) ? mem_c1.mem[k] : 16'hDEAD;
    endfunction

    function automatic logic [15:0] sd_read(int byte_addr);
        bit [24:0] k = sd_key(25'(byte_addr >> 1));
        return mem_sd.mem.exists(k) ? mem_sd.mem[k] : 16'hDEAD;
    endfunction

    // One loader word: DL_WR is one clock per word, as MiSTer's top drives it
    task automatic dl(input logic [7:0] idx, input logic [26:0] a, input logic [15:0] d);
        DL_INDEX = idx; DL_ADDR = a; DL_DATA = d; DL_WR = 1;
        tick;
        DL_WR = 0;
    endtask

    // ---- Directed reads ----
    task automatic read_68k(input int kind, input logic [20:1] a, input logic [26:0] p2,
                            output logic [15:0] q, output int lat);
        longint t0 = cyc;
        M68K_ADDR = a; P2ROM_ADDR = p2; nAS = 0;
        case (kind)
            0: nROMOE = 0;
            1: nPORTOE = 0;
            3: CD_EXT_RD = 1;
            default: nSROMOE = 0;
        endcase
        while (!PROM_DATA_READY && cyc - t0 <= 150) tick;
        lat = int'(cyc - t0);
        q   = PROM_DATA;
        check(PROM_DATA_READY === 1'b1, "68K read: PROM_DATA_READY did not rise");
        tick(2);
        nAS = 1; nROMOE = 1; nPORTOE = 1; nSROMOE = 1; CD_EXT_RD = 0;
        tick(2);
        check(PROM_DATA_READY === 1'b0, "PROM_DATA_READY did not fall after nAS rose");
    endtask

    task automatic pck2_fetch(input logic [15:0] s, input logic [1:0] bank);
        S_LATCH = s; FIX_BANK = bank; PCK2 = 0;
        tick(60);
        PCK2 = 1;
        tick(4);
    endtask

    task automatic m1_read(input logic [18:0] a, output logic [7:0] q);
        longint t0 = cyc;
        m1_addr = a; m1_req = ~m1_req;
        while (m1_ack != m1_req && cyc - t0 < 200) tick;
        check(m1_ack == m1_req, "M1 read not acknowledged");
        q = m1_dout;
    endtask

    task automatic adpcm_read(input bit is_b, input logic [24:0] a, output logic [7:0] q);
        longint t0 = cyc;
        if (is_b) begin adpcmb_addr = a; adpcmb_req = ~adpcmb_req; end
        else      begin adpcma_addr = a; adpcma_req = ~adpcma_req; end
        while ((is_b ? adpcmb_ack != adpcmb_req : adpcma_ack != adpcma_req) && cyc - t0 < 200) tick;
        check(is_b ? adpcmb_ack == adpcmb_req : adpcma_ack == adpcma_req, "ADPCM read not acknowledged");
        q = is_b ? adpcmb_dout : adpcma_dout;
    endtask

    // ---- test_loader_routing ----
    task automatic test_loader_routing();
        // index, file offset, chip (0 CRAM0, 1 CRAM1, 2 SDRAM), expected byte address
        int routes[14][4] = '{
            '{0,  'h00124,  0, 'hA00124},
            '{0,  'h7FFFE,  0, 'hA7FFFE},
            '{2,  'h01234,  0, 'hD01234},
            '{4,  'h12344,  0, 'h012344},
            '{4,  'h312344, 0, 'h312344},   // a merged prom runs on linearly
            '{4,  'h812344, 0, 'h812344},   // into the PROG1 window
            '{5,  'h01236,  0, 'h081236},
            '{6,  'h01238,  0, 'h101238},
            '{8,  'h2123A,  0, 'hC2123A},
            '{9,  'h0123C,  0, 'hF8123C},
            '{15, 'h2345678, 2, 'h2345678},
            '{16, 'h01230,  1, 'h001230},
            '{17, 'h01232,  1, 'h081232},
            '{47, 'h01234,  1, 'hF81234}
        };
        int ignored[9] = '{1, 3, 7, 10, 14, 48, 63, 64, 200};
        int n_c0 = 0, n_c1 = 0, n_sd = 0;

        DL_EN = 1;
        for (int i = 0; i < 14; i++) begin
            logic [15:0] d = hash(100, i);
            int idx = routes[i][0], at = routes[i][3];
            dl(8'(idx), 27'(routes[i][1]), d);
            tick(40);
            case (routes[i][2])
                0: begin n_c0++; check(c0_read(at) == d, $sformatf("index %0d: not at CRAM0 %h", idx, at)); end
                1: begin n_c1++; check(c1_read(at) == d, $sformatf("index %0d: not at CRAM1 %h", idx, at)); end
                default: begin n_sd++; check(sd_read(at) == d, $sformatf("index %0d: not at SDRAM %h", idx, at)); end
            endcase
        end
        // Unmapped indices, and offsets past the end of the region, write nothing
        for (int i = 0; i < 9; i++) dl(8'(ignored[i]), 27'h1000, 16'h5A5A);
        dl(8'd4,  27'hA00000,  16'h5A5A);      // would overwrite the BIOS
        dl(8'd6,  27'h900000,  16'h5A5A);
        dl(8'd15, 27'h4000000, 16'h5A5A);      // would wrap into the first sprites
        tick(60);
        DL_EN = 0;
        dl(8'd4, 27'h1000, 16'h5A5A);           // DL_EN low
        tick(60);
        DL_EN = 1;
        // The CD build's work RAM fill, begun by the first word: 64K words, one of them the index 6 route above
        while (!dut.wfill[16]) tick;
        tick(40);
        check(c0_read('h100000) == 16'hAAAA && c0_read('h101238) == 16'hAAAA && c0_read('h11FFFE) == 16'hAAAA, "work RAM not filled");
        check(c0_read('h0FFFFE) == 16'hDEAD && c0_read('h120000) == 16'hDEAD, "the fill ran past the work RAM");
        n_c0 += 65536 - 1;
        check(mem_c0.mem.size() == n_c0, $sformatf("CRAM0 holds %0d words, expected %0d", mem_c0.mem.size(), n_c0));
        check(mem_c1.mem.size() == n_c1, $sformatf("CRAM1 holds %0d words, expected %0d", mem_c1.mem.size(), n_c1));
        check(mem_sd.mem.size() == n_sd, $sformatf("SDRAM holds %0d words, expected %0d", mem_sd.mem.size(), n_sd));
        $display("test_loader_routing done: 14 routes, 9 unmapped indices");
    endtask

    // ---- test_fix_address_reorder ----
    // MiSTer's sdram_mux formula, in its own SDRAM word address space
    function automatic logic [25:0] mister_fix_word(logic sys_g, logic [1:0] bank, logic [15:0] s);
        return sys_g ? 26'({6'b0_0000_1, bank, s[15:4], s[2:0], ~s[3]})
                     : 26'({8'b0_0000_001,      s[15:4], s[2:0], ~s[3]});
    endfunction

    task automatic test_fix_address_reorder();
        logic [15:0] latches[4] = '{16'h0000, 16'h1238, 16'hABC7, 16'hFFFF};
        foreach (latches[i]) for (int bank = 0; bank < 4; bank++) begin
            logic [15:0] s = latches[i];
            logic [15:0] d = hash(200, i * 4 + bank);
            // The file offset MiSTer loads this word from: its word address minus the region
            int off = (int'(mister_fix_word(1'b1, 2'(bank), s)) - ('h80000 >> 1)) * 2;
            dl(8'd8, 27'(off), d);
            tick(20);
            nSYSTEM_G = 1;
            pck2_fetch(s, 2'(bank));
            check(SROM_DATA == d, $sformatf("S ROM latch %h bank %0d: got %h, expected %h", s, bank, SROM_DATA, d));
        end
        foreach (latches[i]) begin
            logic [15:0] s = latches[i];
            logic [15:0] d = hash(201, i);
            int off = (int'(mister_fix_word(1'b0, 2'b0, s)) - ('h20000 >> 1)) * 2;
            dl(8'd2, 27'(off), d);
            tick(20);
            nSYSTEM_G = 0;
            pck2_fetch(s, 2'd3);    // FIX_BANK does not apply to SFIX
            check(SROM_DATA == d, $sformatf("SFIX latch %h: got %h, expected %h", s, SROM_DATA, d));
        end
        nSYSTEM_G = 1;
        // FIX_EN low and a refresh slot do not fetch
        begin
            int n0 = mem_c0.access_count;
            FIX_EN = 0;
            pck2_fetch(16'h0001, 2'd0);
            FIX_EN = 1;
            REFRESH_EN = 1;
            pck2_fetch(16'h0002, 2'd0);
            REFRESH_EN = 0;
            check(mem_c0.access_count == n0, "fix fetch with FIX_EN low or in a refresh slot");
        end
        $display("test_fix_address_reorder done");
    endtask

    // ---- test_p_rom_bank_window ----
    task automatic test_p_rom_bank_window();
        logic [15:0] q;
        int lat;
        // A merged prom at index 4: P1 is its first 1 MB, the banked window the rest
        for (int i = 0; i < 8; i++) begin
            dl(8'd4, 27'(i * 'h20000 + 'h40), hash(300, i));
            tick(14);
        end
        for (int i = 0; i < 8; i++) begin
            read_68k(0, 20'(i * 'h20000 + 'h40) >> 1, 27'h0, q, lat);
            check(q == hash(300, i), $sformatf("P1 read %0d: %h", i, q));
        end
        // Bank switch moves P2ROM_ADDR while M68K_ADDR stays the same
        for (int bank = 0; bank < 8; bank++) begin
            logic [26:0] p2 = 27'(bank * 'h100000 + 'h1234);
            dl(8'd6, p2, hash(301, bank));
            tick(14);
        end
        for (int bank = 7; bank >= 0; bank--) begin
            logic [26:0] p2 = 27'(bank * 'h100000 + 'h1234);
            read_68k(1, 20'h1234 >> 1, p2, q, lat);
            check(q == hash(301, bank), $sformatf("P2 bank %0d: %h", bank, q));
            check(c0_read('h100000 + int'(p2)) == hash(301, bank), "P2 word not at P2 base + P2ROM_ADDR");
        end
        // Index 4 past 1 MB and index 6 see the same memory
        dl(8'd4, 27'h300010, 16'hC0DE);
        tick(14);
        read_68k(1, 20'h0, 27'h200010, q, lat);
        check(q == 16'hC0DE, "merged prom not visible through the bank window");
        // System ROM through nSROMOE
        dl(8'd0, 27'h1FFFE, 16'hB105);
        tick(14);
        read_68k(2, 20'h1FFFE >> 1, 27'h0, q, lat);
        check(q == 16'hB105, "BIOS read");
        $display("test_p_rom_bank_window done");
    endtask

    // A PCK2 fall with no fetch, to open the Z80 window
    task automatic open_z80_window();
        FIX_EN = 0; PCK2 = 0;
        tick;
        PCK2 = 1; FIX_EN = 1;
        tick;
    endtask

    // Fetch other words, so that the expected data on the next pass is a change
    task automatic spoil_outputs();
        S_LATCH = 16'h0008; PCK2 = 0; tick(30); PCK2 = 1; tick(4);
        CROM_ADDR = 27'(25'h8000) << 1; PCK1 = 0; tick(30); PCK1 = 1; tick(4);
    endtask

    // ---- test_same_clock_requests: priority, and nothing lost when clients arrive together ----
    task automatic test_same_clock_requests();
        logic [15:0] d_68k = 16'h6801, d_fix = 16'hF1F1, d_m1 = 16'h1E2D, d_a = 16'hA55A, d_b = 16'hB66B;
        logic [15:0] d_dl = 16'h7777;
        logic [63:0] d_spr = 64'h1111_2222_3333_4444;
        int solo_spr = -1;

        mem_c0.mem[23'h000100] = d_68k;
        mem_c0.mem[23'(int'(MAP_SROM >> 1) + 1)] = d_fix;    // S_LATCH 0008: tile 0, word 1
        mem_c0.mem[23'(int'(MAP_M1 >> 1) + 'h80)] = d_m1;
        mem_c1.mem[23'h000200] = d_a;
        mem_c1.mem[23'(int'(V2_OFFSET >> 1) + 'h300)] = d_b;
        for (int i = 0; i < 4; i++) mem_sd.mem[sd_key(25'h4000 + 25'(i))] = 16'(d_spr >> (48 - 16 * i));

        // Sprite alone, for the idle latency
        begin
            longint t0;
            CROM_ADDR = 27'(25'h4000) << 1;
            tick(16);       // settle the watchdog away from this window
            t0 = cyc;
            PCK1 = 0;
            while (CR_DOUBLE !== d_spr && cyc - t0 < 100) tick;
            solo_spr = int'(cyc - t0);
            check(CR_DOUBLE === d_spr, "sprite solo fetch data or word order");
            tick(16);
            PCK1 = 1;
            tick(32);
            $display("sprite idle latency %0d clocks", solo_spr);
        end

        // All clients on one clock, with a loader word for each chip in turn (3 = no loader).
        // A loader word reaches the arbiter a clock after DL_WR, through the FIFO.
        for (int with_dl = 3; with_dl >= 0; with_dl--) begin
            longint t0;
            int t_68k = -1, t_fix = -1, t_m1 = -1, t_a = -1, t_b = -1, t_spr = -1, t_dl = -1;
            int n_c0, n_c1;
            int dl_off = 'h10000 + with_dl * 2;
            int dl_at;
            logic [7:0] dl_idx;

            case (with_dl)
                0: begin dl_idx = 8'd5;  dl_at = 'h080000 + dl_off; end
                1: begin dl_idx = 8'd16; dl_at = dl_off; end
                2: begin dl_idx = 8'd15; dl_at = dl_off; end
                default: begin dl_idx = 8'd5; dl_at = 0; end
            endcase

            spoil_outputs();
            n_c0 = mem_c0.access_count; n_c1 = mem_c1.access_count;
            M68K_ADDR = 20'h00100; nROMOE = 0; nAS = 0;
            S_LATCH = 16'h0000; FIX_BANK = 0; PCK2 = 0;     // S_LATCH bit 3 is inverted: word 1
            m1_addr = 19'h00100; m1_req = ~m1_req;          // low byte of word 80h
            adpcma_addr = 25'h000401; adpcma_req = ~adpcma_req;
            adpcmb_addr = 25'h1000601; adpcmb_req = ~adpcmb_req;
            CROM_ADDR = 27'(25'h4000) << 1; PCK1 = 0;
            if (with_dl != 3) begin
                DL_INDEX = dl_idx; DL_ADDR = 27'(dl_off); DL_DATA = d_dl; DL_WR = 1;
            end
            t0 = cyc;
            tick;
            DL_WR = 0;
            for (int n = 0; n < 90; n++) begin
                int lat = int'(cyc - t0);
                if (t_68k < 0 && PROM_DATA_READY && PROM_DATA == d_68k) t_68k = lat;
                if (t_fix < 0 && SROM_DATA == d_fix) t_fix = lat;
                if (t_m1 < 0 && m1_ack == m1_req) t_m1 = lat;
                if (t_a < 0 && adpcma_ack == adpcma_req) t_a = lat;
                if (t_b < 0 && adpcmb_ack == adpcmb_req) t_b = lat;
                if (t_spr < 0 && CR_DOUBLE === d_spr) t_spr = lat;
                if (with_dl != 3 && t_dl < 0) begin
                    logic [15:0] got = with_dl == 0 ? c0_read(dl_at) : with_dl == 1 ? c1_read(dl_at) : sd_read(dl_at);
                    if (got == d_dl) t_dl = lat;
                end
                tick;
            end
            check(t_68k >= 0, "68K request lost");
            check(t_fix >= 0, "fix request lost");
            check(t_m1 >= 0, "Z80 request lost");
            check(t_a >= 0, "ADPCM-A request lost");
            check(t_b >= 0, "ADPCM-B request lost");
            check(t_spr >= 0, "sprite request lost");
            check(m1_dout == d_m1[7:0], "Z80 data");
            check(adpcma_dout == d_a[15:8], "ADPCM-A odd byte");
            check(adpcmb_dout == d_b[15:8], "ADPCM-B odd byte through v2_offset");
            check(t_68k < t_fix, $sformatf("fix before 68K (%0d, %0d)", t_fix, t_68k));
            check(t_fix < t_m1, $sformatf("Z80 before fix (%0d, %0d)", t_m1, t_fix));
            check(t_a < t_b, $sformatf("ADPCM-B before ADPCM-A (%0d, %0d)", t_b, t_a));
            if (with_dl != 3) check(t_dl >= 0, "loader word lost");
            check(t_spr <= solo_spr, $sformatf("sprite delayed by the arrival of a loader word: %0d > %0d", t_spr, solo_spr));
            check(mem_c0.access_count - n_c0 == 3 + (with_dl == 0), $sformatf("CRAM0: %0d accesses", mem_c0.access_count - n_c0));
            check(mem_c1.access_count - n_c1 == 2 + (with_dl == 1), $sformatf("CRAM1: %0d accesses", mem_c1.access_count - n_c1));
            $display("same clock, loader %0d: 68K %0d fix %0d Z80 %0d A %0d B %0d sprite %0d loader %0d", with_dl, t_68k, t_fix, t_m1, t_a, t_b, t_spr, t_dl);
            nROMOE = 1; nAS = 1; PCK1 = 1; PCK2 = 1;
            tick(20);
        end

        // Priority among pending requests: everything arrives while the chip is busy. One chip per
        // pass, as the loader words leave the FIFO in order.
        for (int chip = 0; chip < 3; chip++) begin
            longint t0;
            int t_68k = -1, t_fix = -1, t_a = -1, t_spr = -1, t_dl = -1;
            int dl_off = 'h10010 + chip * 2;
            int dl_at = chip == 0 ? 'h080000 + dl_off : dl_off;
            spoil_outputs();
            open_z80_window();
            case (chip)
                0: begin m1_addr = 19'h00100; m1_req = ~m1_req; end
                1: begin adpcmb_addr = 25'h1000601; adpcmb_req = ~adpcmb_req; end
                default: dl(8'd15, 27'h20000, 16'h1234);
            endcase
            // SDRAM: the next loader word is at the head of the FIFO as the sprite arrives
            if (chip == 2) dl(8'd15, 27'(dl_off), 16'h7001);
            else tick(3);
            M68K_ADDR = 20'h00100; nROMOE = 0; nAS = 0;
            S_LATCH = 16'h0000; FIX_BANK = 0; PCK2 = 0;
            adpcma_addr = 25'h000401; adpcma_req = ~adpcma_req;
            CROM_ADDR = 27'(25'h4000) << 1; PCK1 = 0;
            t0 = cyc;
            if (chip != 2) dl(chip == 0 ? 8'd5 : 8'd16, 27'(dl_off), 16'h7001);
            for (int n = 0; n < 90; n++) begin
                int lat = int'(cyc - t0);
                logic [15:0] got = chip == 0 ? c0_read(dl_at) : chip == 1 ? c1_read(dl_at) : sd_read(dl_at);
                if (t_68k < 0 && PROM_DATA_READY && PROM_DATA == d_68k) t_68k = lat;
                if (t_fix < 0 && SROM_DATA == d_fix) t_fix = lat;
                if (t_a < 0 && adpcma_ack == adpcma_req) t_a = lat;
                if (t_spr < 0 && CR_DOUBLE === d_spr) t_spr = lat;
                if (t_dl < 0 && got == 16'h7001) t_dl = lat;
                tick;
            end
            nROMOE = 1; nAS = 1; PCK1 = 1; PCK2 = 1;
            tick(20);
            $display("pending, chip %0d: loader %0d 68K %0d fix %0d A %0d sprite %0d", chip, t_dl, t_68k, t_fix, t_a, t_spr);
            check(t_dl >= 0, "loader word lost");
            if (chip == 0) check(t_dl < t_68k && t_68k < t_fix, "CRAM0 priority is not loader, 68K, fix");
            if (chip == 1) check(t_dl < t_a, "CRAM1 priority is not loader, ADPCM-A");
            // The next access starts as the sprite's word 0 arrives, so these two end together
            if (chip == 2) check(t_dl + 3 >= t_spr, $sformatf("loader word before the sprite (%0d, %0d)", t_dl, t_spr));
        end
        $display("test_same_clock_requests done");
    endtask

    // ---- test_cd_ports_ignored ----
    task automatic test_cd_ports_ignored();
        int n0 = mem_c0.access_count, n1 = mem_c1.access_count, sd0 = mem_sd.mem.size();
        logic [15:0] q;
        int lat;
        DL_EN = 0;
        CD_USE_FIX = 1; CD_USE_SPR = 1; DMA_RUNNING = 1;
        CD_EXT_RD = 1; CD_TR_RD_FIX = 1; CD_TR_RD_SPR = 1;
        tick(4);
        CD_EXT_WR = 1; CD_TR_WR_FIX = 1; CD_TR_WR_SPR = 1; CD_TR_WR_PCM = 1;
        tick(40);
        check(fx_req == fx_ack && u_fix.state == u_fix.S_IDLE && s_oe === 1'b1, "CD request reached the SRAM with SYSTEM_CDx=0");
        check(CD_PCM_DTACK === 1'b0, "CD_PCM_DTACK with SYSTEM_CDx=0");
        check(mem_c0.access_count == n0 && mem_c1.access_count == n1, "CD request reached a CRAM with SYSTEM_CDx=0");
        check(mem_sd.mem.size() == sd0, "CD request wrote the SDRAM with SYSTEM_CDx=0");
        check(DMA_SDRAM_BUSY === 1'b0, "DMA_SDRAM_BUSY with SYSTEM_CDx=0");
        check(CD_EXT_WR_READY === 1'b1, "CD_EXT_WR_READY low with SYSTEM_CDx=0");
        // The normal paths are not blocked by them
        read_68k(0, 20'h00100, 27'h0, q, lat);
        check(q == 16'h6801, "68K read while CD signals are high");
        pck2_fetch(16'h0000, 2'd0);
        check(SROM_DATA == 16'hF1F1, "fix fetch while CD_USE_FIX is high");
        CROM_ADDR = 27'(25'h4000) << 1; PCK1 = 0; tick(40); PCK1 = 1; tick(4);
        check(CR_DOUBLE === 64'h1111_2222_3333_4444, "sprite fetch while CD_USE_SPR is high");
        CD_USE_FIX = 0; CD_USE_SPR = 0; DMA_RUNNING = 0;
        CD_EXT_RD = 0; CD_TR_RD_FIX = 0; CD_TR_RD_SPR = 0;
        CD_EXT_WR = 0; CD_TR_WR_FIX = 0; CD_TR_WR_SPR = 0; CD_TR_WR_PCM = 0;
        DL_EN = 1;
        $display("test_cd_ports_ignored done");
    endtask

    // ---- test_refresh_watchdog ----
    task automatic test_refresh_watchdog();
        // Idle with no PCK1 at all, at both frequencies
        for (int i = 0; i < 2; i++) begin
            real p = i == 0 ? PERIOD_AES : PERIOD_MVS;
            period = p;
            tick;
            rf_window_start();
            begin
                int c0 = rf_cmds;
                tick(int'(200000.0 / p));
                check(rf_gap_max <= REFRESH_NS, $sformatf("no PCK1 at %0.3f ns: %0.0f ns without refresh", p, rf_gap_max));
                check(rf_cmds - c0 >= 25, $sformatf("only %0d refreshes in 200 us", rf_cmds - c0));
                $display("watchdog at %0.3f ns: largest gap %0.0f ns, %0d refreshes in 200 us", p, rf_gap_max, rf_cmds - c0);
            end
        end
        period = PERIOD_AES;
        tick;

        // PCK1 running, no refresh slots: active display, with sprite fetches
        rf_window_start();
        repeat (400) begin
            CROM_ADDR = 27'(25'h4000) << 1; PCK1 = 0; tick(PCK_PERIOD - PCK_HIGH); PCK1 = 1; tick(PCK_HIGH);
        end
        check(rf_gap_max <= REFRESH_NS, $sformatf("active display: %0.0f ns without refresh", rf_gap_max));
        $display("active display: largest gap %0.0f ns", rf_gap_max);

        // Refresh slots: one refresh per PCK1 slot, no sprite fetch
        begin
            int c0 = rf_cmds;
            logic [63:0] cr_prev = CR_DOUBLE;
            REFRESH_EN = 1;
            repeat (40) begin
                CROM_ADDR = 27'(25'h8000) << 1; PCK1 = 0; tick(PCK_PERIOD - PCK_HIGH); PCK1 = 1; tick(PCK_HIGH);
            end
            REFRESH_EN = 0;
            check(rf_cmds - c0 == 40, $sformatf("%0d refreshes in 40 slots", rf_cmds - c0));
            check(CR_DOUBLE === cr_prev, "sprite fetch in a refresh slot");
        end

        // A slot right after a watchdog toggle: two toggles in one busy window would cancel
        for (int after = 0; after < 14; after++) begin
            int t0 = rf_toggles;
            while (rf_toggles == t0) tick;
            tick(after);
            REFRESH_EN = 1; PCK1 = 0; tick(2); REFRESH_EN = 0; PCK1 = 1;
            tick(30);
        end
        check(rf_spacing_min >= 10, $sformatf("refresh toggles %0d clocks apart", rf_spacing_min));
        $display("test_refresh_watchdog done: closest toggles %0d clocks", rf_spacing_min);
    endtask

    // ---- test_top_word_sequence ----
    // Reads of a die's top word before a load must not turn the load's write into a register access
    task automatic test_top_word_sequence();
        logic [15:0] q;
        logic [7:0] b;
        int lat;
        int n0 = mem_c0.access_count, n1 = mem_c1.access_count;

        // Top of die 0 (P2) and die 1 (M1) of CRAM0, both tops of CRAM1, each read twice
        repeat (2) begin
            read_68k(1, 20'h0, 27'h6FFFFE, q, lat);
            m1_read(19'h7FFFE, b);
            adpcm_read(1'b0, 25'h07FFFFE, b);
            adpcm_read(1'b0, 25'h0FFFFFE, b);
        end
        check(mem_c0.access_count - n0 == 4 && mem_c1.access_count - n1 == 4, "top word reads");

        // No read reaches the CRAMs while the core is in reset, and the toggles are still answered
        nRESET = 0;
        n0 = mem_c0.access_count; n1 = mem_c1.access_count;
        m1_read(19'h7FFFE, b);
        adpcm_read(1'b0, 25'h07FFFFE, b);
        adpcm_read(1'b1, 25'h0FFFFFE, b);
        nAS = 0; nROMOE = 0; tick(30); nAS = 1; nROMOE = 1;
        PCK2 = 0; tick(30); PCK2 = 1;
        check(mem_c0.access_count == n0 && mem_c1.access_count == n1, "CRAM read in reset");

        // The load: ascending through both top words of each chip
        dl(8'd4, 27'h7FFFFC, 16'h0001);  tick(12);
        dl(8'd4, 27'h7FFFFE, 16'h0000);  tick(12);     // the values that would select BCR and RCR
        dl(8'd9, 27'h07FFFC, 16'h0002);  tick(12);
        dl(8'd9, 27'h07FFFE, 16'h0001);  tick(12);
        dl(8'd31, 27'h07FFFC, 16'h0001); tick(12);     // (31-16)*512 KB + 7FFFC: top of die 0
        dl(8'd31, 27'h07FFFE, 16'h0000); tick(12);
        dl(8'd47, 27'h07FFFC, 16'h0002); tick(12);     // top of die 1
        dl(8'd47, 27'h07FFFE, 16'h0001); tick(12);
        nRESET = 1;
        tick(4);
        check(mem_c0.sw_seq_count == 0 && mem_c1.sw_seq_count == 0, "software access sequence during the load");
        check(c0_read('h7FFFFE) == 16'h0000 && c0_read('hFFFFFE) == 16'h0001, "CRAM0 top words");
        check(c1_read('h7FFFFE) == 16'h0000 && c1_read('hFFFFFE) == 16'h0001, "CRAM1 top words");
        read_68k(1, 20'h0, 27'h6FFFFE, q, lat);
        check(q == 16'h0000, "P2 reads the top word back from the array");
        $display("test_top_word_sequence done");
    endtask

    // ---- test_loader_rate ----
    // Returns how many of n words at one fixed interval reached memory
    task automatic stream(input int chip, input int interval, input int n, input int salt, output int lost);
        int base = 'h200000 + salt * 'h40000;
        lost = 0;
        for (int i = 0; i < n; i++) begin
            longint t0 = cyc;
            dl(chip == 0 ? 8'd6 : chip == 1 ? 8'd16 : 8'd15, 27'(base + i * 2), hash(salt, i));
            while (cyc - t0 < interval) tick;
        end
        tick(60);
        for (int i = 0; i < n; i++) begin
            int at = base + i * 2 + (chip == 0 ? 'h100000 : 0);
            logic [15:0] got = chip == 0 ? c0_read(at) : chip == 1 ? c1_read(at) : sd_read(at);
            if (got != hash(salt, i)) lost++;
        end
    endtask

    task automatic test_loader_rate();
        string names[3] = '{"CRAM0", "CRAM1", "SDRAM"};
        int shortest[3] = '{10, 10, 9};     // clocks per word that the mux must sustain
        int salt = 1;
        int lost;
        nRESET = 0;
        for (int chip = 0; chip < 3; chip++) begin
            stream(chip, shortest[chip], 3000, salt++, lost);
            check(lost == 0, $sformatf("%s lost %0d of 3000 words at %0d clocks per word", names[chip], lost, shortest[chip]));
            $display("loader %s: %0d clocks per word, %0d of 3000 lost (%0.1f MB/s at AES clock)", names[chip],
                     shortest[chip], lost, 2000.0 / (shortest[chip] * period));
            // A burst on consecutive clocks, as apf_loader may emit a pair or more
            for (int b = 0; b < 3; b++) begin
                int at = 'h700000 + salt * 'h40000;
                int bad = 0;
                salt++;
                DL_INDEX = chip == 0 ? 8'd6 : chip == 1 ? 8'd16 : 8'd15;
                for (int i = 0; i < 5; i++) begin
                    DL_ADDR = 27'(at + b * 16 + i * 2); DL_DATA = hash(salt, i); DL_WR = 1;
                    tick;
                end
                DL_WR = 0;
                tick(80);
                for (int i = 0; i < 5; i++) begin
                    int w = at + b * 16 + i * 2 + (chip == 0 ? 'h100000 : 0);
                    logic [15:0] got = chip == 0 ? c0_read(w) : chip == 1 ? c1_read(w) : sd_read(w);
                    if (got != hash(salt, i)) bad++;
                end
                check(bad == 0, $sformatf("%s lost %0d of a 5-word burst", names[chip], bad));
            end
        end
        check(dl_overflow === 1'b0, "dl_overflow set while the loader kept to the contract");
        nRESET = 1;
        $display("test_loader_rate done");
    endtask

    // One clock per word too fast: words are lost and dl_overflow says so. Runs last, as the flag
    // stays set until MEM_INIT.
    task automatic test_loader_overflow();
        string names[3] = '{"CRAM0", "CRAM1", "SDRAM"};
        int shortest[3] = '{10, 10, 9};
        int salt = 20;
        int lost;
        nRESET = 0;
        DL_EN = 1;
        tick(40);
        check(dl_overflow === 1'b0, "dl_overflow set before the overflow test");
        for (int chip = 0; chip < 3; chip++) begin
            stream(chip, shortest[chip] - 1, 3000, salt++, lost);
            check(lost > 0, $sformatf("%s kept up at %0d clocks per word: the contract is not the limit", names[chip], shortest[chip] - 1));
            check(dl_overflow === 1'b1, "dl_overflow not set by lost words");
            $display("loader %s: %0d clocks per word, %0d of 3000 lost", names[chip], shortest[chip] - 1, lost);
        end
        DL_EN = 0;
        $display("test_loader_overflow done");
    endtask

    // ---- Traffic clients for the deadline test ----
    typedef enum int { SPR, FIX, CPU, Z80, ADA, ADB, N_CLIENT } client_t;
    string  cname[N_CLIENT]    = '{"sprite", "fix", "68K", "Z80 M1", "ADPCM-A", "ADPCM-B"};
    int     deadline[N_CLIENT] = '{SPR_DEADLINE, FIX_DEADLINE, 150, 200, 128, 1580};
    int     lat_max[N_CLIENT];
    longint lat_sum[N_CLIENT];
    int     served[N_CLIENT], missed[N_CLIENT];
    bit     stop = 0;
    bit     video_enforced = 1;     // sprite and fix misses fail the bench
    int     cpu_late;           // 68K reads past the zero wait state budget
    int     z80_cadence = 0;    // clocks between Z80 reads; 0 is the dense stress pattern

    // Measured in sim/top with the real fx68k, RD_WAIT 9 and 10: PROM_DATA_READY 10 clocks after the request,
    // in that bench's count and with READY_COMB, takes no wait state, 11 takes one. This bench has the ready
    // registered and counts from a clock earlier: an idle read here is 11 where it is 9 there, so 12.
    localparam int CPU_NO_WAIT = 12;

    task automatic note(client_t c, int lat, bit ok);
        served[c]++;
        lat_sum[c] += lat;
        if (lat > lat_max[c]) lat_max[c] = lat;
        // Wrong or missing data is always an error; lateness of the video clients only when enforced
        if (!ok) begin
            missed[c]++;
            check(1'b0, $sformatf("%s: no correct data after %0d clocks", cname[c], lat));
        end else if (lat > deadline[c]) begin
            missed[c]++;
            if (missed[c] <= 3 && (video_enforced || (c != SPR && c != FIX)))
                $error("%s miss: %0d clocks", cname[c], lat);
        end
    endtask

    localparam int N_BLOCK = 256;

    function automatic logic [25:1] spr_word(int b); return 25'(b * 4 * 1361 * 16); endfunction
    function automatic int p1_word(int b);  return b * 1021; endfunction
    function automatic int p2_byte(int b);  return b * 2 * 4099; endfunction
    function automatic int bios_word(int b); return b * 251; endfunction
    function automatic int m1_byte(int b);  return b * 2039; endfunction
    function automatic int ada_byte(int b); return b * 40503; endfunction
    function automatic int adb_byte(int b); return b * 30011; endfunction
    function automatic logic [15:0] fix_latch(int b); return 16'(b * 251); endfunction

    function automatic int fix_word(logic sys_g, logic [1:0] bank, logic [15:0] s);
        return sys_g ? int'(MAP_SROM >> 1) + int'({bank, s[15:4], s[2:0], ~s[3]})
                     : int'(MAP_SFIX >> 1) + int'({s[15:4], s[2:0], ~s[3]});
    endfunction

    // The CD build: no banks, nSYSTEM_G is always 1, and the word is the SRAM's
    function automatic int fix_ram_word(logic [15:0] s);
        return int'({s[15:4], s[2:0], ~s[3]});
    endfunction

    // Backdoor fill of everything the clients can read
    task automatic fill_memories();
        for (int b = 0; b < N_BLOCK; b++) begin
            int w;
            for (int i = 0; i < 4; i++) mem_sd.mem[sd_key(spr_word(b) + 25'(i))] = hash(1, int'(spr_word(b)) + i);
            w = int'(MAP_P1 >> 1) + p1_word(b);      mem_c0.mem[23'(w)] = hash(2, w);
            w = int'(MAP_P2 >> 1) + (p2_byte(b) >> 1); mem_c0.mem[23'(w)] = hash(2, w);
            w = int'(MAP_BIOS >> 1) + bios_word(b);  mem_c0.mem[23'(w)] = hash(2, w);
            w = int'(MAP_M1 >> 1) + (m1_byte(b) >> 1); mem_c0.mem[23'(w)] = hash(2, w);
            for (int bank = 0; bank < 4; bank++) begin
                w = fix_word(1'b1, 2'(bank), fix_latch(b)); mem_c0.mem[23'(w)] = hash(2, w);
            end
            w = fix_word(1'b0, 2'b0, fix_latch(b));  mem_c0.mem[23'(w)] = hash(2, w);
            w = fix_ram_word(fix_latch(b));          mem_s.mem[w] = hash(7, w);
            w = ada_byte(b) >> 1;                    mem_c1.mem[23'(w)] = hash(3, w);
            w = adb_byte(b) >> 1;                    mem_c1.mem[23'(w)] = hash(3, w);
            w = (int'(V2_OFFSET) + (adb_byte(b) >> 4)) >> 1; mem_c1.mem[23'(w)] = hash(3, w);
        end
    endtask

    task automatic sprite_client(int n);
        int fetched = 0, last = -1;
        while (fetched < n) begin
            longint t0 = cyc;
            int b;
            bit vbl = REFRESH_EN;
            logic [63:0] exp = 0;
            do b = $urandom_range(N_BLOCK - 1); while (b == last);
            last = b;
            for (int i = 0; i < 4; i++) exp = {exp[47:0], hash(1, int'(spr_word(b)) + i)};
            CROM_ADDR = 27'({spr_word(b), 1'b0});
            PCK1 = 0;
            if (!vbl) begin
                while (CR_DOUBLE !== exp && cyc - t0 < PCK_PERIOD - 1) tick;
                note(SPR, int'(cyc - t0), CR_DOUBLE === exp);
                fetched++;
            end
            while (cyc - t0 < PCK_PERIOD - PCK_HIGH) tick;
            PCK1 = 1;
            while (cyc - t0 < PCK_PERIOD) tick;
        end
        stop = 1;
    endtask

    task automatic fix_client();
        tick(PCK1_TO_PCK2);
        while (!stop) begin
            longint t0 = cyc;
            int b;
            bit vbl = REFRESH_EN;
            logic [15:0] s, exp;
            logic [1:0] bank = 2'($urandom_range(3));
            logic sys_g = SYSTEM_CDx || $urandom_range(15) != 0;
            do begin
                b   = $urandom_range(N_BLOCK - 1);
                s   = fix_latch(b);
                exp = SYSTEM_CDx ? hash(7, fix_ram_word(s)) : hash(2, fix_word(sys_g, bank, s));
            end while (exp == SROM_DATA);
            S_LATCH = s; FIX_BANK = bank; nSYSTEM_G = sys_g; PCK2 = 0;
            if (!vbl) begin
                while (SROM_DATA !== exp && cyc - t0 < PCK_PERIOD - 1) tick;
                note(FIX, int'(cyc - t0), SROM_DATA === exp);
            end
            while (cyc - t0 < PCK_PERIOD - PCK_HIGH) tick;
            PCK2 = 1;
            while (cyc - t0 < PCK_PERIOD) tick;
        end
    endtask

    task automatic cpu_client();
        while (!stop) begin
            longint t0 = cyc;
            int kind = $urandom_range(2);
            int b = $urandom_range(N_BLOCK - 1);
            int w = kind == 0 ? int'(MAP_P1 >> 1) + p1_word(b) :
                    kind == 1 ? int'(MAP_P2 >> 1) + (p2_byte(b) >> 1) : int'(MAP_BIOS >> 1) + bios_word(b);
            logic [15:0] exp = hash(2, w);
            M68K_ADDR = kind == 0 ? 20'(p1_word(b)) : 20'(bios_word(b));
            P2ROM_ADDR = 27'(p2_byte(b));
            nAS = 0;
            case (kind)
                0: nROMOE = 0;
                1: nPORTOE = 0;
                default: nSROMOE = 0;
            endcase
            while (!PROM_DATA_READY && cyc - t0 <= 300) tick;
            note(CPU, int'(cyc - t0), PROM_DATA_READY && PROM_DATA == exp);
            if (cyc - t0 > CPU_NO_WAIT) cpu_late++;
            tick(4);
            nAS = 1; nROMOE = 1; nPORTOE = 1; nSROMOE = 1;
            tick(2);
            // A 68000 bus cycle is 16 clocks of 48 MHz, longer with wait states. 32 divides the PCK
            // period, so a quarter of the cycles run longer to walk through every phase.
            while (cyc - t0 < 32) tick;
            if ($urandom_range(3) == 0) tick($urandom_range(7));
        end
    endtask

    task automatic z80_client();
        while (!stop) begin
            longint t0 = cyc;
            int b = $urandom_range(N_BLOCK - 1);
            int a = m1_byte(b);
            int w = int'(MAP_M1 >> 1) + (a >> 1);
            logic [15:0] word = hash(2, w);
            logic [7:0] exp = a[0] ? word[15:8] : word[7:0];
            m1_addr = 19'(a); m1_req = ~m1_req;
            while (m1_ack != m1_req && cyc - t0 <= 1000) tick;
            note(Z80, int'(cyc - t0), m1_ack == m1_req && m1_dout == exp);
            // The real Z80 reads at most once per 72 clocks; the stress pattern is far denser
            if (z80_cadence != 0) while (cyc - t0 < z80_cadence) tick;
            else tick($urandom_range(24));
        end
    endtask

    task automatic ada_client();
        while (!stop) begin
            longint t0 = cyc;
            int a = ada_byte($urandom_range(N_BLOCK - 1));
            logic [15:0] word = hash(3, a >> 1);
            logic [7:0] exp = a[0] ? word[15:8] : word[7:0];
            adpcma_addr = 25'(a); adpcma_req = ~adpcma_req;
            while (adpcma_ack != adpcma_req && cyc - t0 <= 143) tick;
            note(ADA, int'(cyc - t0), adpcma_ack == adpcma_req && adpcma_dout == exp);
            while (cyc - t0 < 144) tick;
        end
    endtask

    task automatic adb_client();
        int i = 0;
        while (!stop) begin
            longint t0 = cyc;
            int b = $urandom_range(N_BLOCK - 1);
            bit v2 = i++ % 2 == 1;
            int off = v2 ? adb_byte(b) >> 4 : adb_byte(b);
            int at = v2 ? int'(V2_OFFSET) + off : off;
            logic [15:0] word = hash(3, at >> 1);
            logic [7:0] exp = at[0] ? word[15:8] : word[7:0];
            adpcmb_addr = {v2, 24'(off)}; adpcmb_req = ~adpcmb_req;
            while (adpcmb_ack != adpcmb_req && cyc - t0 <= 1727) tick;
            note(ADB, int'(cyc - t0), adpcmb_ack == adpcmb_req && adpcmb_dout == exp);
            while (cyc - t0 < 1728) tick;
        end
    endtask

    // The 68K on PROG RAM (the P1 fill, as MAP_PROG overlaps it). With writes, some reads are of the
    // word the 68K wrote on the bus cycle before: the write is posted and the read ranks above it.
    // The strobes fall 12 clocks into a write cycle and 4 into a read, so the two edges are 24 apart.
    localparam int WR_TO_RD = 24;
    int cd_wr_words = 0;

    task automatic prog_client(bit with_writes);
        int i = 0;
        while (!stop) begin
            longint t0 = cyc;
            int w = int'(MAP_PROG >> 1) + p1_word($urandom_range(N_BLOCK - 1));
            logic [15:0] exp = hash(2, w);
            if (with_writes && $urandom_range(1) == 0) begin
                w   = 'hC0000 + (i & 'h3FFFF);      // above the fill
                exp = hash(5, i++);
                M68K_ADDR = 20'(w); M68K_DATA = exp; nAS = 0; nUDS = 0; nLDS = 0; CD_EXT_WR = 1;
                tick;
                while (!CD_EXT_WR_READY) tick;      // the top holds nDTACK
                tick;
                while (cyc - t0 < 16) tick;
                CD_EXT_WR = 0; nUDS = 1; nLDS = 1; nAS = 1;
                cd_wr_words++;
                while (cyc - t0 < WR_TO_RD) tick;
                t0 = cyc;
            end
            M68K_ADDR = 20'(w); nAS = 0; CD_EXT_RD = 1;
            while (!PROM_DATA_READY && cyc - t0 <= 300) tick;
            note(CPU, int'(cyc - t0), PROM_DATA_READY && PROM_DATA == exp);
            if (cyc - t0 > CPU_NO_WAIT) cpu_late++;
            tick(4);
            nAS = 1; CD_EXT_RD = 0;
            tick(2);
            while (cyc - t0 < 32) tick;
            if ($urandom_range(3) == 0) tick($urandom_range(7));
        end
    endtask

    // A CD DMA write stream, one word per 35 clocks, the 68K off the bus. Noted on the 68K's line:
    // the latency is how long DMA_SDRAM_BUSY held the engine.
    task automatic dma_client();
        int i = 0;
        DMA_RUNNING = 1;
        while (!stop) begin
            longint t0 = cyc;
            int at = 'h180000 + (i & 'h3FFFF) * 2;
            logic [15:0] d = hash(6, i++);
            DMA_ADDR_OUT = 24'(at); DMA_DATA_OUT = d; CD_EXT_WR = 1;
            tick;
            while (DMA_SDRAM_BUSY && cyc - t0 <= 300) tick;
            note(CPU, int'(cyc - t0), !DMA_SDRAM_BUSY && c0_read(at) == d);
            while (cyc - t0 < 30) tick;
            CD_EXT_WR = 0;
            while (cyc - t0 < 35) tick;
        end
        DMA_RUNNING = 0;
    endtask

    // Vertical blank pattern: refresh slots for 300 of each 2000 PCK periods. Moves half a
    // nanosecond ahead of the clients, so they all see the same value in a clock.
    task automatic vblank_client();
        while (!stop) begin
            @(posedge clk);
            #0.5;
            REFRESH_EN = (cyc % (2000 * PCK_PERIOD)) < (300 * PCK_PERIOD);
        end
        REFRESH_EN = 0;
    endtask

    // Loader words during gameplay, at the worst rate of the APF bridge (a 32-bit word per
    // 88 clocks of 74.25 MHz = 114 of these clocks), two 16-bit words two clocks apart, in
    // regions the clients do not read.
    int dl_c0_words = 0, dl_c1_words = 0, dl_sd_words = 0;

    task automatic loader_client();
        int i = 0;
        DL_EN = 1;
        while (!stop) begin
            longint t0 = cyc;
            int chip = i % 3;
            logic [7:0] idx = chip == 0 ? 8'd6 : chip == 1 ? 8'd47 : 8'd15;
            int off = (chip == 2 ? 'h3000000 : 'h60000) + (i / 3) * 4;
            if (chip == 1) off = (i / 3) * 4 & 'h7FFFF;
            if (chip == 0) off = 'h600000 + (i / 3) * 4;
            dl(idx, 27'(off), hash(4, off));
            tick;
            dl(idx, 27'(off + 2), hash(4, off + 2));
            if (chip == 0) dl_c0_words += 2;
            if (chip == 1) dl_c1_words += 2;
            if (chip == 2) dl_sd_words += 2;
            i++;
            while (cyc - t0 < 114) tick;
        end
    endtask

    // cd_mode: 0 the cart's 68K, 1 PROG RAM reads, 2 PROG RAM reads and writes, 3 CD DMA writes
    task automatic traffic_phase(string name, real p, int n, bit with_loader, int cd_mode = 0);
        int n0, n1;
        real ns;
        period = p;
        tick;
        foreach (lat_max[c]) begin lat_max[c] = 0; lat_sum[c] = 0; served[c] = 0; missed[c] = 0; end
        dl_c0_words = 0; dl_c1_words = 0; dl_sd_words = 0;
        cd_wr_words = 0;
        cpu_late = 0;
        // A load during gameplay does not exist in the cart build, so its sprite and fix misses are
        // reported here and do not fail the bench. Nothing may be lost or duplicated in any phase.
        video_enforced = !with_loader;
        n0 = mem_c0.access_count; n1 = mem_c1.access_count;
        rf_window_start();
        stop = 0;
        fork
            sprite_client(n);
            fix_client();
            if (cd_mode == 0) cpu_client();
            else if (cd_mode == 3) dma_client();
            else prog_client(cd_mode == 2);
            z80_client();
            ada_client();
            adb_client();
            vblank_client();
            if (with_loader) loader_client();
        join
        tick(40);
        for (int c = 0; c < int'(N_CLIENT); c++) begin
            ns = lat_max[c] * p;
            $display("%-12s %-8s worst %5d clk (%7.1f ns)  mean %6.1f  deadline %4d  served %6d  missed %0d", name, cname[c],
                     lat_max[c], ns, real'(lat_sum[c]) / served[c], deadline[c], served[c], missed[c]);
            if (video_enforced || (c != int'(SPR) && c != int'(FIX)))
                check(missed[c] == 0, $sformatf("%s: %s missed %0d deadlines", name, cname[c], missed[c]));
            check(served[c] > 0, $sformatf("%s: %s never served", name, cname[c]));
        end
        // Exactly one access per request: nothing duplicated, nothing lost
        // The CD build's fix is not on CRAM0
        check(mem_c0.access_count - n0 == (SYSTEM_CDx ? 0 : served[FIX]) + served[CPU] + served[Z80] + dl_c0_words + cd_wr_words,
              $sformatf("%s: CRAM0 made %0d accesses for %0d requests", name, mem_c0.access_count - n0,
                        (SYSTEM_CDx ? 0 : served[FIX]) + served[CPU] + served[Z80] + dl_c0_words + cd_wr_words));
        check(mem_c1.access_count - n1 == served[ADA] + served[ADB] + dl_c1_words,
              $sformatf("%s: CRAM1 made %0d accesses for %0d requests", name, mem_c1.access_count - n1,
                        served[ADA] + served[ADB] + dl_c1_words));
        check(rf_gap_max <= REFRESH_NS, $sformatf("%s: %0.0f ns without refresh", name, rf_gap_max));
        $display("%-12s refresh  largest gap %0.0f ns", name, rf_gap_max);
        check(dl_overflow === 1'b0, $sformatf("%s: dl_overflow", name));
        $display("%-12s 68K      %0.1f%% of reads past the %0d clock zero wait budget", name,
                 100.0 * cpu_late / served[CPU], CPU_NO_WAIT);
    endtask

    // ---- CD: PROG RAM in CRAM0 ----
    // A CPU write: CD_EXT_WR rises with the strobes, and the top holds nDTACK while it is not ready
    task automatic prog_write(input logic [20:1] a, input logic [15:0] d, input logic [1:0] lanes);
        tick;       // CD_EXT_WR must have been seen low, or a fall and a rise in one time step lose the edge
        M68K_ADDR = a; M68K_DATA = d; {nUDS, nLDS} = ~lanes; nAS = 0; CD_EXT_WR = 1;
        tick;
        while (!CD_EXT_WR_READY) tick;
        tick;
        CD_EXT_WR = 0; {nUDS, nLDS} = 2'b11; nAS = 1;
    endtask

    task automatic prog_write_read(input int at, input logic [15:0] d, input logic [1:0] lanes, input logic [15:0] exp);
        logic [15:0] q;
        int lat;
        prog_write(20'(at >> 1), d, lanes);
        tick(16);
        check(c0_read(at) == exp, $sformatf("PROG RAM %h lanes %b: chip has %h, expected %h", at, lanes, c0_read(at), exp));
        read_68k(3, 20'(at >> 1), 27'h0, q, lat);
        check(q == exp, $sformatf("PROG RAM %h lanes %b: read %h, expected %h", at, lanes, q, exp));
        check(lat <= CPU_NO_WAIT, $sformatf("PROG RAM read on an idle chip took %0d clocks", lat));
    endtask

    task automatic test_prog_ram_cpu_write_read();
        int at[2] = '{'h100000, 'h1FFFFE};
        SYSTEM_CDx = 1;
        foreach (at[i]) begin
            // The 68K puts a byte on both lanes, and the strobes choose
            prog_write_read(at[i], 16'h1234, 2'b11, 16'h1234);
            prog_write_read(at[i], 16'hABAB, 2'b01, 16'h12AB);
            prog_write_read(at[i], 16'hCDCD, 2'b10, 16'hCDAB);
        end
        SYSTEM_CDx = 0;
        $display("test_prog_ram_cpu_write_read done");
    endtask

    // As MiSTer, the CPU reads the low half through nROMOE, not CD_EXT_RD. It writes through CD_EXT_WR
    task automatic test_prog_ram_low_half();
        int at[2] = '{'h000100, 'h0F0000};
        logic [15:0] q;
        int lat;
        SYSTEM_CDx = 1;
        foreach (at[i]) begin
            prog_write(20'(at[i] >> 1), 16'hA55A ^ 16'(i), 2'b11);
            tick(16);
            check(c0_read(at[i]) == (16'hA55A ^ 16'(i)), $sformatf("PROG RAM %h: chip has %h", at[i], c0_read(at[i])));
            read_68k(0, 20'(at[i] >> 1), 27'h0, q, lat);
            check(q == (16'hA55A ^ 16'(i)), $sformatf("PROG RAM %h through nROMOE: read %h", at[i], q));
        end
        SYSTEM_CDx = 0;
        $display("test_prog_ram_low_half done");
    endtask

    // One DMA word: DMA_SDRAM_BUSY from the edge to the chip's ack, then a clock of ready for a read
    task automatic dma_word(input bit wr, input int at, input logic [15:0] d);
        longint t0 = cyc;
        string what = $sformatf("DMA %s %h", wr ? "write" : "read", at);
        if (wr) begin DMA_ADDR_OUT = 24'(at); DMA_DATA_OUT = d; CD_EXT_WR = 1; end
        else    begin DMA_ADDR_IN = 24'(at); CD_EXT_RD = 1; end
        tick;
        while (!dut.c0_ack && cyc - t0 < 30) begin
            check(DMA_SDRAM_BUSY === 1'b1, {what, ": not busy before the ack"});
            tick;
        end
        check(dut.c0_ack === 1'b1, {what, ": no ack"});
        check(DMA_SDRAM_BUSY === 1'b1, {what, ": not busy in the ack clock"});
        tick;
        check(DMA_SDRAM_BUSY === 1'b0, {what, ": still busy after the ack"});
        if (!wr) check(PROM_DATA_READY === 1'b1 && PROM_DATA == d, {what, ": wrong data or no ready"});
        tick;
        check(PROM_DATA_READY === 1'b0, {what, ": ready stays up, nAS never rises in a DMA"});
        while (cyc - t0 < 30) tick;
        CD_EXT_WR = 0; CD_EXT_RD = 0;
        while (cyc - t0 < 35) tick;
    endtask

    task automatic test_prog_ram_dma_copy();
        int base = 'h1FFF80;    // the last 64 words of PROG RAM
        int n0 = mem_c0.access_count;
        SYSTEM_CDx = 1;
        // What the 68K left on its bus is not the DMA's: it writes whole words at DMA_ADDR_*
        M68K_ADDR = 20'hABCDE; M68K_DATA = 16'hDEAD; nUDS = 1; nLDS = 1;
        DMA_RUNNING = 1;
        tick(2);
        for (int i = 0; i < 64; i++) dma_word(1'b1, base + i * 2, hash(400, i));
        for (int i = 0; i < 64; i++)
            check(c0_read(base + i * 2) == hash(400, i), $sformatf("DMA word %0d not in the chip", i));
        check(mem_c0.access_count - n0 == 64, $sformatf("%0d accesses for 64 DMA writes", mem_c0.access_count - n0));
        for (int i = 0; i < 64; i++) dma_word(1'b0, base + i * 2, hash(400, i));
        check(mem_c0.access_count - n0 == 128, $sformatf("%0d accesses for 64 DMA writes and reads", mem_c0.access_count - n0));
        DMA_RUNNING = 0;
        SYSTEM_CDx = 0;
        tick;
        check(DMA_SDRAM_BUSY === 1'b0 && PROM_DATA_READY === 1'b0, "busy or ready after the DMA");
        $display("test_prog_ram_dma_copy done");
    endtask

    task automatic test_prog_write_queue_holds_ready();
        int at[3] = '{'h140000, 'h140002, 'h140000};    // the third overwrites the first: order shows
        logic [15:0] d[3] = '{16'h1111, 16'h2222, 16'h3333};
        logic [15:0] m1_d = 16'h5EE5;
        int n0;
        int waited = 0;
        SYSTEM_CDx = 1;
        nSYSTEM_G = 1;
        // The CD build's fix is not on CRAM0: a Z80 read holds it instead, the mux does not know this Z80 has its own RAM
        mem_c0.mem[23'(int'(MAP_M1 >> 1) + 'h11)] = m1_d;
        open_z80_window();
        n0 = mem_c0.access_count;
        m1_addr = 19'h00022; m1_req = ~m1_req;
        tick;
        check(dut.c0_req === 1'b1 && dut.c0_owner == dut.C0_M1, "the Z80 read did not take CRAM0");
        for (int i = 0; i < 2; i++) begin
            M68K_ADDR = 20'(at[i] >> 1); M68K_DATA = d[i]; nUDS = 0; nLDS = 0; CD_EXT_WR = 1;
            tick;
            check(CD_EXT_WR_READY === 1'b1, $sformatf("write %0d: not ready, the queue has room", i));
            CD_EXT_WR = 0; nUDS = 1; nLDS = 1;
            tick;
            check(CD_EXT_WR_READY === 1'b1, $sformatf("after write %0d: ready fell with no write waiting", i));
        end
        // The third finds the queue full: the top holds nDTACK, so the CPU keeps it all up
        M68K_ADDR = 20'(at[2] >> 1); M68K_DATA = d[2]; nUDS = 0; nLDS = 0; CD_EXT_WR = 1;
        tick;
        check(CD_EXT_WR_READY === 1'b0, "third write: ready did not fall");
        check(dut.c0_req === 1'b1 && dut.c0_owner == dut.C0_M1, "third write: the Z80 read is over, no queue to test");
        while (!CD_EXT_WR_READY && waited < 60) begin waited++; tick; end
        check(CD_EXT_WR_READY === 1'b1, "ready never rose");
        tick;
        CD_EXT_WR = 0; nUDS = 1; nLDS = 1;
        tick(50);
        check(m1_ack == m1_req && m1_dout == m1_d[7:0], "Z80 read during the writes");
        check(c0_read(at[0]) == d[2] && c0_read(at[1]) == d[1],
              $sformatf("writes lost or out of order: %h %h", c0_read(at[0]), c0_read(at[1])));
        check(mem_c0.access_count - n0 == 4, $sformatf("%0d accesses for a Z80 read and 3 writes", mem_c0.access_count - n0));
        check(DMA_SDRAM_BUSY === 1'b0, "DMA_SDRAM_BUSY with no DMA");
        SYSTEM_CDx = 0;
        $display("test_prog_write_queue_holds_ready done: ready low for %0d clocks", waited);
    endtask

    // ---- CD: FIX, SPR and PCM RAM ----
    // fix_convert and spr_convert_dbl of neogeo_loader.cpp, as sim/apf
    function automatic int c_fix(input int i);
        return (i & ~32'h1F) | ((i >> 2) & 7) | ((i & 1) << 3) | (((i & 2) << 3) ^ 32'h10);
    endfunction

    function automatic int c_spr(input int i);
        return (i & ~32'h3F) | ((i ^ 1) & 1) | ((i >> 1) & 32'h1E) | (((i & 2) ^ 2) << 4);
    endfunction

    // nothing may see WE# low on the SRAM with the DMA engine not stalled
    int fx_unstalled = 0;
    always @(posedge clk) if (!s_we && DMA_RUNNING && !DMA_SDRAM_BUSY) fx_unstalled++;

    typedef enum int { W_SPR, W_PCM, W_FIX } tr_area_t;

    task automatic tr_strobe(tr_area_t area, bit v);
        case (area)
            W_SPR: CD_TR_WR_SPR = v;
            W_PCM: CD_TR_WR_PCM = v;
            default: CD_TR_WR_FIX = v;
        endcase
    endtask

    // The counts for rtl/test/wait_counter.sv's file. The DMA words by target and their stall against the bench's view;
    // then what the real engine and 68K never do: a strobe that leaves a full queue, the only way to lose a write
    // before it is queued, and a reset with writes queued
    wire [0:11][31:0] dbg_w = dut.dbg_dma;      // words PROG, FIX, SPR, PCM, stalls the same, full 68K, full DMA, lost, lost to a reset
    int busy_run = 0, busy_max = 0;
    always @(posedge clk) begin
        if (DMA_RUNNING && DMA_SDRAM_BUSY === 1'b1) begin
            busy_run++;
            if (busy_run > busy_max) busy_max = busy_run;
        end
        else busy_run = 0;
    end

    task automatic z80_holds_cram0();
        nSYSTEM_G = 1;
        open_z80_window();
        m1_addr = 19'h00022; m1_req = ~m1_req;
        tick;
        check(dut.c0_req === 1'b1 && dut.c0_owner == dut.C0_M1, "the Z80 read did not take CRAM0");
    endtask

    task automatic test_debug_dma_counts();
        bit stalled;
        logic [31:0] was [12];
        for (int i = 0; i < 4; i++) dut.dbg_stall[i] = 0;
        nRESET = 1;     // test_loader_overflow leaves it low
        tick(40);
        SYSTEM_CDx = 1;
        CD_USE_FIX = 1; CD_USE_SPR = 1;
        DMA_RUNNING = 1;
        tick(2);
        for (int i = 0; i < 12; i++) was[i] = dbg_w[i];
        // PROG, by target, and its stall as long as the bench saw DMA_SDRAM_BUSY up
        busy_max = 0;
        for (int i = 0; i < 3; i++) dma_word(1'b1, 'h1FF000 + i * 2, 16'h1000 + 16'(i));
        check(dbg_w[0] - was[0] == 3, $sformatf("%0d DMA words to PROG, want 3", dbg_w[0] - was[0]));
        check(int'(dbg_w[4]) >= busy_max - 1 && int'(dbg_w[4]) <= busy_max && dbg_w[4] != 0, $sformatf("PROG's stall %0d, the bench saw %0d", dbg_w[4], busy_max));
        busy_max = 0;
        for (int i = 0; i < 2; i++) tr_dma_word(W_FIX, 'h40 + i * 2, 16'h2000 + 16'(i), stalled);
        check(dbg_w[1] - was[1] == 2, $sformatf("%0d DMA words to FIX, want 2", dbg_w[1] - was[1]));
        check(int'(dbg_w[5]) >= busy_max - 1 && int'(dbg_w[5]) <= busy_max && dbg_w[5] != 0, $sformatf("FIX's stall %0d, the bench saw %0d", dbg_w[5], busy_max));
        busy_max = 0;
        for (int i = 0; i < 4; i++) tr_dma_word(W_SPR, 'h80 + i * 2, 16'h3000 + 16'(i), stalled);
        check(dbg_w[2] - was[2] == 4, $sformatf("%0d DMA words to SPR, want 4", dbg_w[2] - was[2]));
        check(int'(dbg_w[6]) >= busy_max - 1 && int'(dbg_w[6]) <= busy_max && dbg_w[6] != 0, $sformatf("SPR's stall %0d, the bench saw %0d", dbg_w[6], busy_max));
        busy_max = 0;
        tr_dma_word(W_PCM, 'h100, 16'h0044, stalled);
        check(dbg_w[3] - was[3] == 1, $sformatf("%0d DMA words to PCM, want 1", dbg_w[3] - was[3]));
        check(int'(dbg_w[7]) >= busy_max - 1 && int'(dbg_w[7]) <= busy_max && dbg_w[7] != 0, $sformatf("PCM's stall %0d, the bench saw %0d", dbg_w[7], busy_max));
        // An engine that waits on DMA_SDRAM_BUSY finds no full queue and loses nothing
        check(dbg_w[9] == was[9] && dbg_w[10] == was[10] && dbg_w[11] == was[11], "a DMA that waits on DMA_SDRAM_BUSY found a full queue or lost a write");
        DMA_RUNNING = 0;
        CD_USE_FIX = 0; CD_USE_SPR = 0;
        tick(40);

        // The 68K at a full queue, held: counted once, nothing lost
        for (int i = 0; i < 12; i++) was[i] = dbg_w[i];
        z80_holds_cram0();
        for (int i = 0; i < 2; i++) begin
            M68K_ADDR = 20'('h140000 >> 1); M68K_DATA = 16'h1111; nUDS = 0; nLDS = 0; CD_EXT_WR = 1;
            tick;
            CD_EXT_WR = 0; nUDS = 1; nLDS = 1;
            tick;
        end
        CD_EXT_WR = 1; nUDS = 0; nLDS = 0;
        tick(3);
        check(CD_EXT_WR_READY === 1'b0, "the third write did not find the queue full");
        while (!CD_EXT_WR_READY) tick;
        tick;
        CD_EXT_WR = 0; nUDS = 1; nLDS = 1;
        tick(60);
        check(dbg_w[8] - was[8] == 1, $sformatf("%0d queue-full events of the 68K, want 1", dbg_w[8] - was[8]));
        check(dbg_w[10] == was[10], "a held write counted as lost");

        // A DMA that does not wait: the strobe leaves the full queue, and that write is lost
        for (int i = 0; i < 12; i++) was[i] = dbg_w[i];
        z80_holds_cram0();
        DMA_RUNNING = 1;
        for (int i = 0; i < 2; i++) begin
            DMA_ADDR_OUT = 24'h140000; DMA_DATA_OUT = 16'h2222; CD_EXT_WR = 1;
            tick;
            CD_EXT_WR = 0;
            tick;
        end
        CD_EXT_WR = 1;
        tick;
        check(CD_EXT_WR_READY === 1'b0, "the DMA's third write did not find the queue full");
        CD_EXT_WR = 0;
        tick(2);
        check(dbg_w[9] - was[9] == 1, $sformatf("%0d queue-full events of a DMA, want 1", dbg_w[9] - was[9]));
        check(dbg_w[10] - was[10] == 1, $sformatf("%0d writes lost, want 1", dbg_w[10] - was[10]));
        DMA_RUNNING = 0;
        tick(60);

        // A reset with a write queued
        for (int i = 0; i < 12; i++) was[i] = dbg_w[i];
        z80_holds_cram0();
        M68K_ADDR = 20'('h140000 >> 1); M68K_DATA = 16'h3333; nUDS = 0; nLDS = 0; CD_EXT_WR = 1;
        tick;
        CD_EXT_WR = 0; nUDS = 1; nLDS = 1;
        tick;
        check(dut.cd_wq_used != 0, "no write in the queue for the reset");
        nRESET = 0;
        tick(3);
        nRESET = 1;
        tick(60);
        check(dbg_w[11] - was[11] == 1, $sformatf("%0d resets with writes queued, want 1", dbg_w[11] - was[11]));
        SYSTEM_CDx = 0;
        nRESET = 0;
        $display("test_debug_dma_counts done: stalls PROG %0d, FIX %0d, SPR %0d, PCM %0d CLK_96M", dbg_w[4], dbg_w[5], dbg_w[6], dbg_w[7]);
    endtask

    // A CPU write in the window. The top holds nDTACK: on the queue for SPR, on CD_PCM_DTACK for PCM and FIX
    task automatic tr_write(tr_area_t area, input logic [20:1] a, input logic [15:0] d, input logic [1:0] lanes);
        longint t0;
        tick;
        M68K_ADDR = a; M68K_DATA = d; {nUDS, nLDS} = ~lanes; nAS = 0;
        tr_strobe(area, 1'b1);
        t0 = cyc;
        tick;
        if (area == W_SPR) while (!CD_EXT_WR_READY && cyc - t0 < 100) tick;
        else while (!CD_PCM_DTACK && cyc - t0 < 100) tick;
        check(area == W_SPR ? CD_EXT_WR_READY === 1'b1 : CD_PCM_DTACK === 1'b1, $sformatf("window write %0d at %h: no DTACK", int'(area), a));
        tick;
        tr_strobe(area, 1'b0);
        {nUDS, nLDS} = 2'b11; nAS = 1;
        tick(2);
    endtask

    task automatic tr_read(input bit fix, input logic [20:1] a, output logic [15:0] q, output int lat);
        longint t0 = cyc;
        M68K_ADDR = a; nLDS = 0; nUDS = 0; nAS = 0;
        if (fix) CD_TR_RD_FIX = 1; else CD_TR_RD_SPR = 1;
        while (!PROM_DATA_READY && cyc - t0 < 100) tick;
        lat = int'(cyc - t0);
        q = PROM_DATA;
        check(PROM_DATA_READY === 1'b1, $sformatf("window read at %h: PROM_DATA_READY did not rise", a));
        tick(2);
        CD_TR_RD_FIX = 0; CD_TR_RD_SPR = 0; nLDS = 1; nUDS = 1; nAS = 1;
        tick(2);
        check(PROM_DATA_READY === 1'b0, "PROM_DATA_READY did not fall after nAS rose");
    endtask

    // One DMA word in the window, as the engine: the strobe for its timer, and on while busy
    task automatic tr_dma_word(tr_area_t area, input int a, input logic [15:0] d, output bit stalled);
        longint t0 = cyc;
        DMA_ADDR_OUT = 24'hE00000 + 24'(a); DMA_DATA_OUT = d;
        tr_strobe(area, 1'b1);
        tick;
        while (cyc - t0 < 30) tick;
        stalled = DMA_SDRAM_BUSY;
        while (DMA_SDRAM_BUSY && cyc - t0 < 300) tick;
        check(!DMA_SDRAM_BUSY, "DMA_SDRAM_BUSY stuck high");
        tr_strobe(area, 1'b0);
        while (cyc - t0 < 35) tick;
    endtask

    logic [7:0]  fix_p [32];
    logic [15:0] fix_golden [16];

    task automatic fix_rows(output logic [15:0] rows [16]);
        for (int w = 0; w < 16; w++) begin
            pck2_fetch({12'h000, 4'(w)}, 2'd0);
            rows[w] = SROM_DATA;
        end
    endtask

    task automatic test_cd_fix_remap();
        logic [15:0] rows [16];
        foreach (fix_p[i]) fix_p[i] = 8'(hash(500, i));
        // What the cart path shows: the converted file through the loader
        DL_EN = 1;
        nSYSTEM_G = 1;
        for (int i = 0; i < 32; i += 2) begin
            dl(8'd8, 27'(i), {fix_p[c_fix(i + 1)], fix_p[c_fix(i)]});
            tick(14);
        end
        DL_EN = 0;
        fix_rows(fix_golden);
        // The window. FIX is on an 8-bit bus: the high lane of the 68K's data goes nowhere
        SYSTEM_CDx = 1;
        CD_USE_FIX = 1;
        foreach (fix_p[i]) tr_write(W_FIX, 20'(i), {~fix_p[i], fix_p[i]}, 2'b01);
        CD_USE_FIX = 0;
        fix_rows(rows);
        foreach (rows[w]) check(rows[w] == fix_golden[w], $sformatf("tile 0 word %0d: %h, the loader's %h", w, rows[w], fix_golden[w]));
        // The same tile by DMA, one tile on: the addresses are the DMA's, and the engine stalls for each write
        begin
            bit stalled;
            CD_USE_FIX = 1;
            DMA_RUNNING = 1;
            M68K_ADDR = 20'h5A5A5;
            foreach (fix_p[i]) tr_dma_word(W_FIX, (32 + i) * 2, {8'hA5, fix_p[i]}, stalled);
            DMA_RUNNING = 0;
            CD_USE_FIX = 0;
            tick(4);
            for (int w = 0; w < 16; w++) begin
                pck2_fetch({12'h001, 4'(w)}, 2'd0);
                check(SROM_DATA == fix_golden[w], $sformatf("tile 1 by DMA, word %0d: %h, the loader's %h", w, SROM_DATA, fix_golden[w]));
            end
            check(fx_unstalled == 0, $sformatf("WE# low for %0d clocks with the DMA engine not stalled", fx_unstalled));
        end
        SYSTEM_CDx = 0;
        $display("test_cd_fix_remap done");
    endtask

    task automatic test_cd_fix_read_byte_select();
        logic [15:0] q;
        int lat, worst = 0;
        int n0 = mem_c0.access_count;
        SYSTEM_CDx = 1;
        CD_USE_FIX = 1;
        foreach (fix_p[i]) begin
            logic [20:1] a = 20'(i);
            logic [7:0] got;
            tr_read(1'b1, a, q, lat);
            got = a[4] ? q[15:8] : q[7:0];  // the top's byte select, cd's M68K_ADDR[4]
            check(got == fix_p[i], $sformatf("FIX byte %0d read %h, wrote %h", i, got, fix_p[i]));
            if (lat > worst) worst = lat;
        end
        check(mem_c0.access_count == n0, "a FIX read reached CRAM0");
        // A DMA from PROG RAM to the window: cd.sv's TR_ZONE looks at DMA_ADDR_OUT alone, so CD_TR_RD_FIX and
        // CD_EXT_RD rise together. The read is PROG RAM's, as the casez of sdram_mux.sv:112
        begin
            int at = 'h1FFF00;
            mem_c0.mem[23'(at >> 1)] = 16'h7E57;
            DMA_RUNNING = 1;
            DMA_ADDR_IN = 24'(at); DMA_ADDR_OUT = 24'hE00000;
            CD_EXT_RD = 1; CD_TR_RD_FIX = 1;
            begin
                longint t0 = cyc;
                bit seen = 0;
                logic st = fx_req;
                while (cyc - t0 < 30) begin
                    if (PROM_DATA_READY) begin seen = 1; q = PROM_DATA; end
                    tick;
                end
                check(seen && q == 16'h7E57, $sformatf("DMA read from PROG RAM with CD_TR_RD_FIX up: ready %b, %h", seen, q));
                check(fx_req == st, "DMA read from PROG RAM went to the SRAM");
            end
            CD_EXT_RD = 0; CD_TR_RD_FIX = 0;
            tick(8);
            DMA_RUNNING = 0;
        end
        CD_USE_FIX = 0;
        SYSTEM_CDx = 0;
        $display("test_cd_fix_read_byte_select done: rdy %0d clocks at worst on an idle SRAM", worst);
    endtask

    // File offset of bank 1: bits 21:20 of the SDRAM's word address are bits 21:20 of a CROM_ADDR
    localparam int SPR_BANK1 = 'h100000;

    task automatic test_cd_spr_remap();
        logic [15:0] w [64];
        logic [63:0] golden [16];
        logic [15:0] q;
        int lat;
        foreach (w[i]) w[i] = hash(501, i);
        // The converted file through the loader, on the same words
        DL_EN = 1;
        for (int i = 0; i < 64; i++) begin
            dl(8'd15, 27'(SPR_BANK1 + i * 2), w[c_spr(i)]);
            tick(12);
        end
        DL_EN = 0;
        for (int k = 0; k < 16; k++) begin
            CROM_ADDR = 27'(SPR_BANK1 + k * 8); PCK1 = 0; tick(40); PCK1 = 1; tick(4);
            golden[k] = CR_DOUBLE;
        end
        for (int i = 0; i < 64; i++) mem_sd.mem.delete(sd_key(25'((SPR_BANK1 >> 1) + i)));
        // The window, bank 1
        SYSTEM_CDx = 1;
        CD_USE_SPR = 1;
        CD_BANK_SPR = 2'd1;
        foreach (w[i]) tr_write(W_SPR, 20'(i), w[i], 2'b11);
        tick(20);
        for (int i = 0; i < 64; i++) begin
            tr_read(1'b0, 20'(i), q, lat);
            check(q == w[i], $sformatf("SPR word %0d read %h, wrote %h", i, q, w[i]));
        end
        // A byte write: only its lane
        tr_write(W_SPR, 20'd0, 16'hFFFF, 2'b01);
        tick(20);
        tr_read(1'b0, 20'd0, q, lat);
        check(q == {w[0][15:8], 8'hFF}, $sformatf("SPR byte write: %h", q));
        tr_write(W_SPR, 20'd0, w[0], 2'b11);
        tick(20);
        CD_USE_SPR = 0;
        CD_BANK_SPR = 2'd0;
        for (int k = 0; k < 16; k++) begin
            CROM_ADDR = 27'(SPR_BANK1 + k * 8); PCK1 = 0; tick(40); PCK1 = 1; tick(4);
            check(CR_DOUBLE === golden[k], $sformatf("SPR burst %0d: %h, the loader's %h", k, CR_DOUBLE, golden[k]));
        end
        // A refresh slot that finds a SPR write waiting passes to it, and the next one refreshes
        begin
            logic rf0;
            while (dut.rfsh_since < 20 || dut.rfsh_since > 600) tick;
            rf0 = dut.sd_refresh;
            CROM_ADDR = 27'(SPR_BANK1); PCK1 = 0;
            tick(3);
            M68K_ADDR = 20'h00010; M68K_DATA = 16'h4242; nUDS = 0; nLDS = 0; nAS = 0; CD_TR_WR_SPR = 1;
            tick(2);
            check(dut.cd_wq_sd === 1'b1, "the sprite burst is over: no SPR write waiting");
            CD_TR_WR_SPR = 0; nUDS = 1; nLDS = 1; nAS = 1;
            PCK1 = 1;
            tick;
            REFRESH_EN = 1; PCK1 = 0;
            tick(2);
            check(dut.sd_refresh === rf0, "a refresh slot went ahead of a SPR write");
            PCK1 = 1;
            tick(30);
            check(dut.cd_wq_valid === 1'b0, "the SPR write is still waiting");
            PCK1 = 0;
            tick(2);
            check(dut.sd_refresh !== rf0, "the next refresh slot did not refresh");
            PCK1 = 1; REFRESH_EN = 0;
            tick(30);
        end
        SYSTEM_CDx = 0;
        $display("test_cd_spr_remap done");
    endtask

    task automatic test_cd_pcm_byte_write_dtack();
        // bank, the 68K's word address: byte addresses of PCM RAM, as neogeo.sv:1693 and the ADPCM-A read side
        int cases [4][2] = '{'{0, 'h00100}, '{0, 'h00101}, '{1, 'h7FFFE}, '{1, 'h7FFFF}};
        logic [7:0] b;
        SYSTEM_CDx = 1;
        foreach (cases[c]) begin
            int k = (cases[c][0] << 19) | cases[c][1];
            bit [22:0] w = 23'(int'(MAP_PCM >> 1) + (k >> 1));
            longint t0;
            bit acked = 0;
            mem_c1.mem[w] = 16'hC33C;
            CD_BANK_PCM = 1'(cases[c][0]);
            tick;
            check(CD_PCM_DTACK === 1'b0, "CD_PCM_DTACK up before the write");
            M68K_ADDR = 20'(cases[c][1]); M68K_DATA = 16'hA55A; nUDS = 1; nLDS = 0; nAS = 0; CD_TR_WR_PCM = 1;
            t0 = cyc;
            tick;
            while (!CD_PCM_DTACK && cyc - t0 < 100) begin
                if (dut.c1_ack) acked = 1;
                tick;
            end
            check(CD_PCM_DTACK === 1'b1, "no CD_PCM_DTACK");
            check(acked, "CD_PCM_DTACK rose before the chip's ack");
            check(mem_c1.mem[w] == (k & 1 ? 16'h5A3C : 16'hC35A), $sformatf("PCM byte %h: the word holds %h", k, mem_c1.mem[w]));
            // It stays up with the cycle, and only that
            tick(8);
            check(CD_PCM_DTACK === 1'b1, "CD_PCM_DTACK fell with nAS low");
            CD_TR_WR_PCM = 0; nLDS = 1; nAS = 1;
            tick(2);
            check(CD_PCM_DTACK === 1'b0, "CD_PCM_DTACK did not fall with nAS");
            // What ADPCM-A reads there
            adpcm_read(1'b0, 25'(k), b);
            check(b == 8'h5A, $sformatf("ADPCM-A reads %h at %h", b, k));
        end
        // A DMA word: the DMA's address and data, and a DTACK nobody waits for does not stay up
        begin
            bit stalled;
            int k = 'h80200;
            mem_c1.mem[23'(k >> 1)] = 16'hC33C;
            CD_BANK_PCM = 1;
            DMA_RUNNING = 1;
            tr_dma_word(W_PCM, 'h200 * 2, 16'hFF77, stalled);
            DMA_RUNNING = 0;
            tick(2);
            check(mem_c1.mem[23'(k >> 1)] == 16'hC377, $sformatf("PCM by DMA: %h", mem_c1.mem[23'(k >> 1)]));
            check(CD_PCM_DTACK === 1'b0, "CD_PCM_DTACK up after a DMA word");
            CD_BANK_PCM = 0;
        end
        SYSTEM_CDx = 0;
        $display("test_cd_pcm_byte_write_dtack done");
    endtask

    // n words at one per 35 clocks. Duty: DMA_SDRAM_BUSY's share of the time, stalls: words the engine had to
    // wait for past its own timer
    task automatic dma_stream(tr_area_t area, input int n, input int base);
        longint t0 = cyc, busy = 0;
        int stalls = 0;
        DMA_RUNNING = 1;
        fork
            while (DMA_RUNNING) begin
                @(posedge clk);
                if (DMA_SDRAM_BUSY) busy++;
            end
        join_none
        for (int i = 0; i < n; i++) begin
            bit stalled;
            tr_dma_word(area, base + i * 2, hash(502, i), stalled);
            if (stalled) stalls++;
        end
        DMA_RUNNING = 0;
        $display("%s DMA: %0d words in %0d clocks, one per %0.1f, busy %0.1f%% of the time, %0d stalled the engine (%0.2f MB/s at AES clock)",
                 area == W_SPR ? "SPR" : "PCM", n, cyc - t0, real'(cyc - t0) / n, 100.0 * real'(busy) / real'(cyc - t0), stalls,
                 (area == W_SPR ? 2000.0 : 1000.0) * n / (real'(cyc - t0) * period));
        stop = 1;
    endtask

    task automatic test_cd_dma_write_bandwidth();
        localparam int SPR_BASE = 'h40000 * 2;      // above any sprite the client reads, checked here
        localparam int PCM_BASE = 'h78000 * 2;      // the end of bank 1: no ADPCM-A sample the client reads
        fill_memories();
        period = PERIOD_AES;
        tick;
        foreach (lat_max[c]) begin lat_max[c] = 0; lat_sum[c] = 0; served[c] = 0; missed[c] = 0; end
        video_enforced = 1;
        SYSTEM_CDx = 1;
        // The worst there is. In the core CD_USE_SPR turns the sprite off for the upload
        CD_BANK_SPR = 2'd3;
        stop = 0;
        fork
            sprite_client(1 << 30);
            dma_stream(W_SPR, 1000, SPR_BASE);
        join_any
        // The sprite client only ends with its count: it stops at the next period's end
        disable fork;
        PCK1 = 1;
        tick(40);
        $display("SPR DMA: sprite worst %0d clk, deadline %0d, served %0d, missed %0d", lat_max[SPR], deadline[SPR], served[SPR], missed[SPR]);
        check(missed[SPR] == 0, $sformatf("SPR DMA: %0d sprite misses", missed[SPR]));
        check(served[SPR] > 400, $sformatf("SPR DMA: only %0d sprite fetches", served[SPR]));
        for (int i = 0; i < 1000; i++) begin
            // The remap of a DMA word at the base + i: word {bank, A[19:7], A[5:2], ~A[6], ~A[1]}
            logic [19:1] a = 19'((SPR_BASE + i * 2) >> 1);
            logic [25:1] sw = {4'b0, 2'd3, a[19:7], a[5:2], ~a[6], ~a[1]};
            if (sd_read(int'(sw) * 2) != hash(502, i)) check(1'b0, $sformatf("SPR DMA word %0d not in the chip", i));
        end
        CD_BANK_SPR = 2'd0;
        $display("SPR stale read margin, with the sprite at full rate: write edge to queue head at worst %0d clocks, the read's edge at %0d, %0d stale reads",
                 spr_to_head_max, WR_TO_RD, spr_stale_reads);
        check(spr_to_head_max < WR_TO_RD, $sformatf("a SPR write waits %0d clocks, a read can overtake it", spr_to_head_max));
        // PCM with ADPCM-A at its rate
        foreach (lat_max[c]) begin lat_max[c] = 0; lat_sum[c] = 0; served[c] = 0; missed[c] = 0; end
        CD_BANK_PCM = 1;
        stop = 0;
        fork
            ada_client();
            dma_stream(W_PCM, 1000, PCM_BASE);
        join
        CD_BANK_PCM = 0;
        tick(40);
        $display("PCM DMA: ADPCM-A worst %0d clk, deadline %0d, served %0d, missed %0d", lat_max[ADA], deadline[ADA], served[ADA], missed[ADA]);
        check(missed[ADA] == 0, $sformatf("PCM DMA: %0d ADPCM-A misses", missed[ADA]));
        check(served[ADA] > 200, $sformatf("PCM DMA: only %0d ADPCM-A reads", served[ADA]));
        for (int i = 0; i < 1000; i++) begin
            int k = (1 << 19) | (((PCM_BASE + i * 2) >> 1) & 'h7FFFF);
            logic [15:0] word = c1_read(k & ~1);
            logic [15:0] d = hash(502, i);
            if ((k & 1 ? word[15:8] : word[7:0]) != d[7:0]) check(1'b0, $sformatf("PCM DMA word %0d not in the chip", i));
        end
        check(fx_unstalled == 0, "WE# low with the DMA engine not stalled");
        stop = 0;
        SYSTEM_CDx = 0;
        $display("test_cd_dma_write_bandwidth done");
    endtask

    // Against the 55 ns model, on every PCK2 of a run: alone on both phases of CLK_48M, then with all the traffic
    task automatic test_fix_sram_deadline();
        fill_memories();
        SYSTEM_CDx = 1;
        nSYSTEM_G = 1;
        foreach (lat_max[c]) begin lat_max[c] = 0; lat_sum[c] = 0; served[c] = 0; missed[c] = 0; end
        video_enforced = 1;
        for (int parity = 0; parity < 2; parity++) begin
            int worst = 0;
            @(posedge clk48);
            #1;
            tick(parity);
            for (int n = 0; n < 512; n++) begin
                longint t0 = cyc;
                logic [15:0] s, exp;
                int lat;
                do begin
                    s   = fix_latch($urandom_range(N_BLOCK - 1));
                    exp = hash(7, fix_ram_word(s));
                end while (exp == SROM_DATA);
                S_LATCH = s; PCK2 = 0;
                while (SROM_DATA !== exp && cyc - t0 < PCK_PERIOD - 1) tick;
                lat = int'(cyc - t0);
                if (lat > worst) worst = lat;
                check(SROM_DATA === exp, $sformatf("fix read of %h: %h, expected %h", s, SROM_DATA, exp));
                check(lat <= FIX_DEADLINE, $sformatf("fix read of %h took %0d clocks", s, lat));
                while (cyc - t0 < PCK_PERIOD - PCK_HIGH) tick;
                PCK2 = 1;
                while (cyc - t0 < PCK_PERIOD) tick;
            end
            $display("fix read on the SRAM, PCK2 %0s a CLK_48M edge: %0d clocks at worst, deadline %0d",
                     parity == 0 ? "on" : "off", worst, FIX_DEADLINE);
        end
        traffic_phase("CD fix AES", PERIOD_AES, 2000, 1'b0, 2);
        check(lat_max[FIX] <= FIX_DEADLINE, $sformatf("fix on the SRAM with traffic: %0d clocks", lat_max[FIX]));
        traffic_phase("CD fix MVS", PERIOD_MVS, 2000, 1'b0, 2);
        check(lat_max[FIX] <= FIX_DEADLINE, $sformatf("fix on the SRAM with traffic, MVS clock: %0d clocks", lat_max[FIX]));
        period = PERIOD_AES;
        tick;
        check(mem_s.error_count == 0, "SRAM model errors");
        SYSTEM_CDx = 0;
        $display("test_fix_sram_deadline done");
    endtask

    task automatic test_fix_never_on_cram0();
        int n0, fx0;
        fill_memories();
        SYSTEM_CDx = 1;
        n0 = mem_c0.access_count;
        for (int b = 0; b < 8; b++) begin
            logic [15:0] s = fix_latch(b + 1);
            pck2_fetch(s, 2'(b));       // FIX_BANK does not apply: FIX RAM is one 128 KB
            check(SROM_DATA == hash(7, fix_ram_word(s)), $sformatf("fix fetch %h: %h", s, SROM_DATA));
        end
        check(mem_c0.access_count == n0, $sformatf("%0d CRAM0 accesses for fix fetches in the CD build", mem_c0.access_count - n0));
        // CD_USE_FIX high: no video read, as sdram_mux.sv:103. FIXD is Z in the top then
        fx0 = int'(fx_req);
        CD_USE_FIX = 1;
        pck2_fetch(16'h0040, 2'd0);
        CD_USE_FIX = 0;
        check(int'(fx_req) == fx0, "a video read with CD_USE_FIX high");
        check(mem_c0.access_count == n0, "a video read with CD_USE_FIX high on CRAM0");
        // Should a video read and a write ever meet, one master: both served, the model sees no clash
        begin
            int w = fix_ram_word(16'h0050);
            logic [15:0] d = mem_s.mem[w];
            logic [15:0] old = mem_s.mem[1];
            S_LATCH = 16'h0050; PCK2 = 0;
            M68K_ADDR = 20'h00000; M68K_DATA = 16'h0099; nLDS = 0; nAS = 0; CD_TR_WR_FIX = 1;
            tick(60);
            check(SROM_DATA == d, $sformatf("video read met by a write: %h, expected %h", SROM_DATA, d));
            check(CD_PCM_DTACK === 1'b1, "write met by a video read: no DTACK");
            CD_TR_WR_FIX = 0; nLDS = 1; nAS = 1; PCK2 = 1;
            tick(4);
            check(mem_s.mem[1][7:0] == 8'h99 && mem_s.mem[1][15:8] == old[15:8], $sformatf("write met by a video read: %h", mem_s.mem[1]));
        end
        SYSTEM_CDx = 0;
        $display("test_fix_never_on_cram0 done");
    endtask

    task automatic test_bios_window_512k();
        int off[3] = '{'h20010, 'h60012, 'h7FFFE};
        logic [15:0] q;
        int lat;
        foreach (off[i]) mem_c0.mem[23'((int'(MAP_BIOS) + off[i]) >> 1)] = hash(401, i);
        mem_c0.mem[23'(int'(MAP_BIOS >> 1) + 8)] = hash(401, 3);    // where the cart's 128 KB wraps 'h20010 to
        SYSTEM_CDx = 1;
        foreach (off[i]) begin
            read_68k(2, 20'(off[i] >> 1), 27'h0, q, lat);
            check(q == hash(401, i), $sformatf("BIOS offset %h: read %h", off[i], q));
        end
        SYSTEM_CDx = 0;
        read_68k(2, 20'(off[0] >> 1), 27'h0, q, lat);
        check(q == hash(401, 3), $sformatf("the cart's BIOS window is not 128 KB: read %h", q));
        $display("test_bios_window_512k done");
    endtask

    task automatic test_sprite_deadline_under_full_load();
        fill_memories();
        nRESET = 1;
        tick(4);
        traffic_phase("AES", PERIOD_AES, 10000, 1'b0);
        traffic_phase("MVS", PERIOD_MVS, 10000, 1'b0);
        z80_cadence = 72;
        traffic_phase("AES Z80 72", PERIOD_AES, 2000, 1'b0);
        z80_cadence = 0;
        traffic_phase("AES+loader", PERIOD_AES, 2000, 1'b1);
        // Every loader word written during gameplay landed
        for (int k = 0; k < dl_sd_words; k += 2) begin
            int off = 'h3000000 + k * 2;
            check(sd_read(off) == hash(4, off) && sd_read(off + 2) == hash(4, off + 2), $sformatf("SDRAM loader word %h", off));
        end
        for (int k = 0; k < dl_c0_words; k += 2) begin
            int off = 'h600000 + k * 2;
            check(c0_read('h100000 + off) == hash(4, off), $sformatf("CRAM0 loader word %h", off));
        end
        for (int k = 0; k < dl_c1_words; k += 2) begin
            int off = (k * 2) & 'h7FFFF;
            check(c1_read('hF80000 + off) == hash(4, off), $sformatf("CRAM1 loader word %h", off));
        end
        DL_EN = 0;
        SYSTEM_CDx = 1;
        traffic_phase("CD PROG rd", PERIOD_AES, 2000, 1'b0, 1);
        $display("PROG RAM read with fix and Z80 traffic: worst rdy %0d clocks, zero wait budget %0d", lat_max[CPU], CPU_NO_WAIT);
        wr_to_head_max = 0;
        traffic_phase("CD PROG r/w", PERIOD_AES, 2000, 1'b0, 2);
        $display("PROG RAM read with posted writes too: worst rdy %0d clocks", lat_max[CPU]);
        $display("stale read margin: write edge to queue head at worst %0d clocks, the read's edge at %0d, %0d stale reads",
                 wr_to_head_max, WR_TO_RD, stale_reads);
        traffic_phase("CD DMA", PERIOD_AES, 2000, 1'b0, 3);
        SYSTEM_CDx = 0;
        period = PERIOD_AES;
        tick;
        $display("test_sprite_deadline_under_full_load done");
    endtask

    initial begin
        tick(8);
        mem_init = 0;
        while (!dut.sd_ready) tick;
        rf_on = 1;
        rf_tog_last = dut.sd_refresh;
        rf_cmds = mem_sd.refresh_count;
        rf_cmds0 = rf_cmds;
        rf_t_last = $realtime;
        tick(8);

        test_loader_routing();
        nRESET = 1;
        tick(4);
        test_fix_address_reorder();
        test_p_rom_bank_window();
        test_same_clock_requests();
        test_cd_ports_ignored();
        test_refresh_watchdog();
        test_top_word_sequence();
        test_loader_rate();
        test_sprite_deadline_under_full_load();
        // The CD tests stay after the deadline test: before it they shift the alignment of the cart's
        // phases, whose result lines must stay comparable between commits
        test_prog_ram_cpu_write_read();
        test_prog_ram_low_half();
        test_prog_ram_dma_copy();
        test_prog_write_queue_holds_ready();
        test_bios_window_512k();
        test_cd_fix_remap();
        test_cd_fix_read_byte_select();
        test_cd_spr_remap();
        test_cd_pcm_byte_write_dtack();
        test_fix_never_on_cram0();
        test_cd_dma_write_bandwidth();
        test_fix_sram_deadline();
        test_loader_overflow();
        test_debug_dma_counts();

        // Every toggle became one refresh
        while (dut.rfsh_since < 16) tick;
        check(rf_toggles == rf_cmds - rf_cmds0, $sformatf("%0d refresh toggles gave %0d commands", rf_toggles, rf_cmds - rf_cmds0));
        check(mem_sd.error_count == 0, "SDRAM model errors");
        check(mem_c0.error_count == 0, "CRAM0 model errors");
        check(mem_c1.error_count == 0, "CRAM1 model errors");
        check(mem_s.error_count == 0, "SRAM model errors");
        check(mem_c0.sw_seq_count == 0 && mem_c1.sw_seq_count == 0, "software access sequence");
        // The flag lasts until MEM_INIT
        rf_on = 0;
        mem_init = 1;
        tick(2);
        check(dl_overflow === 1'b0, "dl_overflow not cleared by MEM_INIT");
        mem_init = 0;
        $display("refresh: %0d toggles, %0d commands after init, closest toggles %0d clocks",
                 rf_toggles, rf_cmds, rf_spacing_min);
        if (failures != 0) $fatal(1, "%0d failures", failures);
        $display("PASS tb_pocket_mem_mux");
        $finish;
    end
endmodule
