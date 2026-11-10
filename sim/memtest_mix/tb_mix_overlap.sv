// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// pocket_mem_mux alone, with fix, sprite, 68K and Z80 requests swept against each other: every 68K
// start offset (odd ones too, for 48 against 96 MHz phases), every Z80 offset that changes the
// relation (period 72 against 64: its own phase walks 8 clocks a line), two 68K periods and two
// strobe lengths. Data and the fix and sprite deadlines are checked at every fetch, and the first
// failure stops with the sequence that led to it.
`timescale 1ns/1ps
module tb_mix_overlap;
`include "mem_map.svh"

    localparam int FILL = 1 << 10;
    localparam int FIX_DEADLINE = 23, SPR_DEADLINE = 27;
    localparam int WINDOW = 576;        // 64 and 72 line up again after this many clocks

    logic clk = 0;
    always #5.17 clk = ~clk;

    logic        mem_init = 1, nRESET = 0;
    logic [20:1] M68K_ADDR = 0;
    logic        nAS = 1, nROMOE = 1;
    logic [26:0] CROM_ADDR = 0;
    logic        PCK1 = 1, PCK2 = 1;
    logic [15:0] S_LATCH = 0;
    logic        m1_req = 0;
    logic [18:0] m1_addr = 0;
    wire  [15:0] PROM_DATA, SROM_DATA;
    wire         PROM_DATA_READY, m1_ack, adpcma_ack, adpcmb_ack;
    wire  [63:0] CR_DOUBLE;
    wire   [7:0] m1_dout;

    tri   [15:0] dram_dq, c0_dq, c1_dq;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire         c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;

    pocket_mem_mux dut (
        .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(1'b1), .SYSTEM_CDx(1'b0),
        .M68K_ADDR(M68K_ADDR), .M68K_DATA(16'h0), .nAS(nAS), .nLDS(1'b1), .nUDS(1'b1),
        .nROMOE(nROMOE), .nPORTOE(1'b1), .nSROMOE(1'b1), .P2ROM_ADDR(27'd0),
        .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
        .PCK2(PCK2), .S_LATCH(S_LATCH), .FIX_BANK(2'b00), .FIX_EN(1'b1), .SROM_DATA(SROM_DATA),
        .PCK1(PCK1), .CROM_ADDR(CROM_ADDR), .SPR_EN(1'b1), .CR_DOUBLE(CR_DOUBLE), .REFRESH_EN(1'b0),
        .DL_EN(1'b0), .DL_DATA(16'd0), .DL_ADDR(27'd0), .DL_WR(1'b0), .DL_INDEX(8'd0), .dl_overflow(),
        .CD_TR_AREA(3'd0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
        .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'd0),
        .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
        .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
        .fx_req(), .fx_we(), .fx_word(), .fx_be(), .fx_wdata(), .fx_ack(1'b0), .fx_rdata(16'h0),
        .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0), .DMA_SDRAM_BUSY(),
        .adpcma_addr(25'd0), .adpcma_dout(), .adpcma_req(1'b0), .adpcma_ack(adpcma_ack),
        .adpcmb_addr(25'd0), .adpcmb_dout(), .adpcmb_req(1'b0), .adpcmb_ack(adpcmb_ack),
        .v2_offset(24'd0),
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

    sdram_model mem_sd (
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

    initial begin
        #400_000_000;
        $fatal(1, "timeout");
    end

    function automatic logic [15:0] hash(logic [22:0] w);
        return w[15:0] ^ {w[6:0], w[15:7]} ^ {w[22:16], 9'h155};
    endfunction

    function automatic bit [24:0] sd_key(logic [25:1] w);
        return {w[24:23], w[22:10], w[25], w[9:1]};
    endfunction

    // The last CRAM0 grants, for the report of a failure
    string  grants [$];
    logic   c0_req_q = 0;
    longint cyc = 0;
    always @(posedge clk) begin
        cyc++;
        if (dut.c0_req && !c0_req_q) begin
            grants.push_back($sformatf("%0d:owner %0d word %06x", cyc, dut.c0_owner, dut.c0_addr));
            if (grants.size() > 8) void'(grants.pop_front());
        end
        c0_req_q = dut.c0_req;
    end

    task automatic fail(string what, int hold, int period, int a, int z, int c, logic [15:0] got, logic [15:0] exp);
        $display("FAIL %s: hold %0d period %0d 68K offset %0d Z80 offset %0d clock %0d got %04x exp %04x", what, hold, period, a, z, c, got, exp);
        foreach (grants[i]) $display("  grant %s", grants[i]);
        $fatal(1, "%s", what);
    endtask

    int n_fix = 0, n_spr = 0, n_68k = 0, n_z80 = 0;
    int w_fix = 0, w_spr = 0, w_68k = 0, w_z80 = 0;
    logic [15:0] tile = 0;
    logic [22:0] spr = 0;
    logic [15:0] m_idx = 0;
    logic [16:0] z_idx = 0;

    task automatic run(input int hold, input int period, input int a, input int z);
        bit fix_on = 0, fix_seen = 0, spr_on = 0, spr_seen = 0, m_on = 0, z_on = 0;
        int fix_t = 0, spr_t = 0, m_t = 0, z_t = 0, next_m = a;
        logic [15:0] fix_exp = 0, m_exp = 0, z_w = 0;
        logic [63:0] spr_exp = 0;
        logic  [7:0] z_exp = 0;
        for (int c = 0; c < WINDOW; c++) begin
            case (c % 64)
                0: begin
                    logic [22:0] w = {spr[22:2], 2'b00};
                    PCK1 = 0;
                    CROM_ADDR = {3'b000, w, 1'b0};
                    spr_exp = {hash({w[22:2], 2'd0}), hash({w[22:2], 2'd1}), hash({w[22:2], 2'd2}), hash({w[22:2], 2'd3})};
                    spr = (spr + 23'd4) & 23'(FILL - 1);
                    spr_on = 1; spr_seen = 0; spr_t = 0;
                end
                60: PCK1 = 1;
                32: begin
                    PCK2 = 0;
                    S_LATCH = {tile[15:4], ~tile[0], tile[3:1]};
                    fix_exp = hash({MAP_SROM[23:19], 2'b00, tile});
                    tile = (tile + 16'd1) & 16'(FILL - 1);
                    fix_on = 1; fix_seen = 0; fix_t = 0;
                end
                28: PCK2 = 1;
                default: ;
            endcase

            if (!m_on && c >= next_m) begin
                M68K_ADDR = 20'(m_idx);
                m_exp = hash(23'(m_idx));
                m_idx = (m_idx + 16'd1) & 16'(FILL - 1);
                nROMOE = 0; nAS = 0;
                m_on = 1; m_t = 0;
                next_m = c + period;
            end

            if (!z_on && c % 72 == z) begin
                z_w = z_idx[16:1];
                m1_addr = {2'b00, z_w, z_idx[0]};
                begin
                    logic [15:0] d = hash({MAP_M1[23:19], 2'b00, z_w});
                    z_exp = z_idx[0] ? d[15:8] : d[7:0];
                end
                z_idx = (z_idx + 17'd1) & 17'(FILL * 2 - 1);
                m1_req = ~m1_req;
                z_on = 1; z_t = 0;
            end

            @(posedge clk);
            #1;
            fix_t++; spr_t++; m_t++; z_t++;

            if (fix_on) begin
                if (!fix_seen && SROM_DATA == fix_exp) begin
                    fix_seen = 1;
                    if (fix_t > w_fix) w_fix = fix_t;
                end
                if (fix_t == FIX_DEADLINE) begin
                    if (!fix_seen) fail("fix", hold, period, a, z, c, SROM_DATA, fix_exp);
                    fix_on = 0;
                    n_fix++;
                end
            end
            if (spr_on) begin
                if (!spr_seen && CR_DOUBLE == spr_exp) begin
                    spr_seen = 1;
                    if (spr_t > w_spr) w_spr = spr_t;
                end
                if (spr_t == SPR_DEADLINE) begin
                    if (!spr_seen) fail("sprite", hold, period, a, z, c, CR_DOUBLE[63:48], spr_exp[63:48]);
                    spr_on = 0;
                    n_spr++;
                end
            end
            if (m_on && PROM_DATA_READY) begin
                if (PROM_DATA !== m_exp) fail("68K", hold, period, a, z, c, PROM_DATA, m_exp);
                if (m_t > w_68k && nAS == 0 && m_t < 200) w_68k = m_t;
                if (hold == 0 || m_t >= hold) begin
                    nROMOE = 1; nAS = 1;
                    m_on = 0;
                    n_68k++;
                end
            end
            if (z_on && m1_ack == m1_req) begin
                if (m1_dout !== z_exp) fail("Z80", hold, period, a, z, c, {8'd0, m1_dout}, {8'd0, z_exp});
                if (z_t > w_z80) w_z80 = z_t;
                z_on = 0;
                n_z80++;
            end
        end
        // Let everything finish before the next combination
        PCK1 = 1; PCK2 = 1;
        while (m_on || z_on) begin
            @(posedge clk);
            #1;
            m_t++;
            if (m_on && PROM_DATA_READY && m_t >= hold) begin nROMOE = 1; nAS = 1; m_on = 0; end
            if (z_on && m1_ack == m1_req) z_on = 0;
        end
        repeat (40) @(posedge clk);
        #1;
    endtask

    initial begin
        // Backdoor fill: this bench is about the requests
        for (int i = 0; i < FILL; i++) begin
            automatic bit [22:0] p = 23'(i), s = {MAP_SROM[23:19], 2'b00, 16'(i)}, m = {MAP_M1[23:19], 2'b00, 16'(i)};
            mem_c0.mem[p] = hash(p);
            mem_c0.mem[s] = hash(s);
            mem_c0.mem[m] = hash(m);
            mem_sd.mem[sd_key(25'(i))] = hash(23'(i));
        end
        repeat (20) @(posedge clk);
        #1 mem_init = 0;
        #130_000;
        nRESET = 1;
        repeat (40) @(posedge clk);
        #1;
        for (int hi = 0; hi < 2; hi++)
            for (int pi = 0; pi < 2; pi++)
                for (int a = 0; a < (pi == 0 ? 32 : 35); a++)
                    for (int z = 0; z < 8; z++)
                        run(hi == 0 ? 0 : 24, pi == 0 ? 32 : 35, a, z);
        $display("fetches: fix %0d sprite %0d 68K %0d Z80 %0d", n_fix, n_spr, n_68k, n_z80);
        $display("worst clocks: fix %0d of %0d, sprite %0d of %0d, 68K %0d, Z80 %0d", w_fix, FIX_DEADLINE, w_spr, SPR_DEADLINE, w_68k, w_z80);
        if (mem_c0.error_count != 0 || mem_c1.error_count != 0 || mem_sd.error_count != 0) $fatal(1, "model errors");
        $display("PASS tb_mix_overlap");
        $finish;
    end
endmodule
