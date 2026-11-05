// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Behavioural 64 MB (32M x 16, 4 banks, 13 row bits, 10 column bits) SDR SDRAM with
// protocol and timing checks, modelled on the AS4C32M16MSA-6BIN of the Pocket (the numbers
// come from the AS4C16M32MSA-6BIN datasheet, the x32 sibling of the same family). Command
// pins are sampled on the rising edge of dram_clk; the chip select is assumed tied low.
//
// Checks (each one is an $error and bumps error_count):
//  - power-up: first command no earlier than 100 us, then PRECHARGE ALL first, then 2x AUTO
//    REFRESH, LOAD MODE (mode register) and LOAD MODE (extended mode register) in any order,
//    and no ACTIVE/READ/WRITE before all of them are done;
//  - mode register: CL must be legal for the clock period (CL2 only below 83 MHz), burst
//    length 4, sequential, standard operation, and A9=1 (single-location writes: a burst
//    write would overwrite the neighbouring words); extended mode register: BA=10, A12:A8=0;
//  - tRCD, tRAS, tRC, tRP (after the auto precharge too), tRFC, tMRD and bank state (ACTIVE on
//    an open bank, READ/WRITE on a closed bank, REFRESH/LOAD MODE with a busy bank);
//  - refresh rate: after init, the AUTO REFRESH count may not fall more than MAX_POSTPONE
//    behind elapsed_time / REFRESH_NS (8192 rows per 64 ms is 7.8 us on average; a few
//    postponed refreshes are allowed, as JEDEC does).
//
// Timing in ns is converted to clocks with CLK_NS. Use the shortest clock period the design
// runs at (96.671316 MHz AES = 10.344 ns): it is the strict one, since the ns limits then
// take the most clocks (the MVS 96.000 MHz clock, 10.417 ns, only gives more margin).
//
// Auto precharge start: READ at t -> t + BL (the chip keeps CL-1 outputs valid after a
// precharge, so it does not depend on CL); WRITE at t -> t + 1 + tWR; never before ACTIVE +
// tRAS. The next ACTIVE needs tRP more.
`timescale 1ns/1ps
module sdram_model #(
    parameter real CLK_NS       = 10.34,
    parameter real TRCD_NS      = 18.0,
    parameter real TRP_NS       = 18.0,
    parameter real TRAS_NS      = 48.0,
    parameter real TRC_NS       = 60.0,
    parameter real TRFC_NS      = 80.0,
    parameter real CL2_MAX_MHZ  = 83.0,   // CL=2 is only allowed up to this frequency
    parameter real POWERUP_NS   = 100000.0,
    parameter int  TWR_CLK      = 2,
    parameter int  TMRD_CLK     = 2,
    parameter real REFRESH_NS   = 7800.0,
    parameter int  MAX_POSTPONE = 8
) (
    input  wire        dram_clk,
    input  wire        dram_cke,
    input  wire        dram_ras_n,
    input  wire        dram_cas_n,
    input  wire        dram_we_n,
    input  wire [12:0] dram_a,
    input  wire  [1:0] dram_ba,
    input  wire  [1:0] dram_dqm,
    inout  wire [15:0] dram_dq
);
    localparam int BL   = 4;
    localparam int TRCD = int'($ceil(TRCD_NS / CLK_NS));
    localparam int TRP  = int'($ceil(TRP_NS  / CLK_NS));
    localparam int TRAS = int'($ceil(TRAS_NS / CLK_NS));
    localparam int TRC  = int'($ceil(TRC_NS  / CLK_NS));
    localparam int TRFC = int'($ceil(TRFC_NS / CLK_NS));
    localparam bit CL2_OK = (1000.0 / CLK_NS) <= CL2_MAX_MHZ;

    localparam [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101,
                     CMD_WRITE = 3'b100, CMD_PRECHARGE = 3'b010, CMD_REFRESH = 3'b001,
                     CMD_LMR = 3'b000;

    logic [15:0] mem [bit [24:0]];

    longint      cyc = 0;
    bit          bank_open [4];
    longint      t_last_act [4];
    logic [12:0] bank_row  [4];
    longint      t_act     [4];
    longint      t_act_ok  [4];     // earliest legal ACTIVE (precharge finished)
    longint      t_cmd_ok = 0;      // earliest legal command after REFRESH / LOAD MODE

    // Public status for the testbench
    bit          init_done = 0;
    int          refresh_count = 0; // AUTO REFRESH commands after init
    int          error_count = 0;

    bit          pre_seen = 0, mrs_done = 0, emrs_done = 0;
    int          init_refs = 0;
    int          cl = 3;            // CAS latency from the mode register
    bit          seen_cmd = 0;
    realtime     t_init_done = 0;
    bit          rate_error = 0;

    // Read data pipeline: slot 0 is driven after the current edge
    logic [15:0] pipe_d [8];
    bit          pipe_v [8];
    logic  [1:0] dqm_d1 = 0, dqm_d2 = 0;
    logic [15:0] dq_drv = 0;
    bit          dq_en = 0;
    assign dram_dq = dq_en ? dq_drv : 16'bz;

    initial begin
        for (int i = 0; i < 4; i++) begin
            bank_open[i] = 0; t_act[i] = 0; t_last_act[i] = -1000; t_act_ok[i] = 0; bank_row[i] = 0;
        end
        for (int i = 0; i < 8; i++) begin pipe_v[i] = 0; pipe_d[i] = 0; end
    end

    task automatic fail(string msg);
        error_count++;
        $error("sdram_model cyc %0d: %s", cyc, msg);
    endtask

    function automatic bit all_idle();
        for (int b = 0; b < 4; b++)
            if (bank_open[b] || cyc < t_act_ok[b]) return 0;
        return 1;
    endfunction

    task automatic precharge_bank(int b);
        if (bank_open[b] && (cyc - t_act[b] < TRAS))
            fail($sformatf("tRAS violated on bank %0d (%0d < %0d clocks)", b, cyc - t_act[b], TRAS));
        bank_open[b] = 0;
        t_act_ok[b]  = cyc + TRP;
    endtask

    // Auto precharge: starts 'offset' clocks after this edge, finishes tRP later
    task automatic auto_precharge(int b, int offset);
        longint start;
        start = cyc + offset;
        if (start < t_act[b] + TRAS) start = t_act[b] + TRAS;
        bank_open[b] = 0;
        t_act_ok[b]  = start + TRP;
    endtask

    always @(posedge dram_clk) begin
        logic  [2:0] cmd;
        logic [24:0] key;
        logic  [9:0] col;
        int          b;
        cmd = {dram_ras_n, dram_cas_n, dram_we_n};
        b   = int'(dram_ba);
        cyc++;

        // Drive the read data due at this edge (DQM has a 2 clock latency), then advance
        if (pipe_v[0] && dqm_d2 == 2'b00) begin
            dq_drv <= pipe_d[0];
            dq_en  <= 1;
        end else begin
            dq_en  <= 0;
        end
        for (int i = 0; i < 7; i++) begin pipe_d[i] = pipe_d[i+1]; pipe_v[i] = pipe_v[i+1]; end
        pipe_v[7] = 0;

        if (!dram_cke) fail("CKE low");
        if (cmd != CMD_NOP) begin
            if (!seen_cmd) begin
                seen_cmd = 1;
                if (real'(cyc) * CLK_NS < POWERUP_NS) fail("first command before the 100 us power-up wait");
            end
            if (cyc < t_cmd_ok) fail("command inside tRFC/tMRD window");
        end

        case (cmd)
            CMD_PRECHARGE: begin
                if (dram_a[10]) for (int i = 0; i < 4; i++) precharge_bank(i);
                else precharge_bank(b);
                if (!init_done) begin
                    if (dram_a[10] && !pre_seen && init_refs == 0 && !mrs_done && !emrs_done) pre_seen = 1;
                    else fail("unexpected PRECHARGE during init (PRECHARGE ALL must come first)");
                end
            end
            CMD_REFRESH: begin
                if (!all_idle()) fail("AUTO REFRESH with an open or precharging bank");
                t_cmd_ok = cyc + TRFC;
                if (!init_done) begin
                    if (!pre_seen) fail("AUTO REFRESH before PRECHARGE ALL");
                    else init_refs++;
                end else refresh_count++;
            end
            CMD_LMR: begin
                if (!all_idle()) fail("LOAD MODE with an open or precharging bank");
                if (!pre_seen && !init_done) fail("LOAD MODE before PRECHARGE ALL");
                t_cmd_ok = cyc + TMRD_CLK;
                if (dram_ba == 2'b00) begin
                    // Mode register
                    if (dram_a[6:4] == 3'b011) cl = 3;
                    else if (dram_a[6:4] == 3'b010) begin
                        cl = 2;
                        if (!CL2_OK) fail($sformatf("mode register CL2 not allowed at %0.1f MHz (limit %0.0f MHz)", 1000.0 / CLK_NS, CL2_MAX_MHZ));
                    end else fail($sformatf("mode register CL field %0d not supported", dram_a[6:4]));
                    if (dram_a[2:0] != 3'b010) fail("mode register burst length is not 4");
                    if (dram_a[3]) fail("mode register burst type is not sequential");
                    if (dram_a[8:7] != 0) fail("mode register operating mode is not 0");
                    if (!dram_a[9]) fail("mode register A9=0: burst writes would overwrite neighbouring words");
                    if (dram_a[12:10] != 0) fail("mode register reserved bits are not 0");
                    mrs_done = 1;
                end else if (dram_ba == 2'b10) begin
                    // Extended mode register
                    if (dram_a[12:8] != 0 || dram_a[4:3] != 0) fail("extended mode register reserved bits are not 0");
                    emrs_done = 1;
                end else fail($sformatf("LOAD MODE with BA=%b", dram_ba));
            end
            CMD_ACTIVE: begin
                if (!init_done) fail($sformatf("ACTIVE before init sequence complete (PRE %0d, refreshes %0d, MRS %0d, EMRS %0d)", pre_seen, init_refs, mrs_done, emrs_done));
                else if (bank_open[b]) fail($sformatf("ACTIVE on open bank %0d", b));
                else if (cyc < t_act_ok[b]) fail($sformatf("tRP violated on bank %0d (ACTIVE %0d clocks early)", b, t_act_ok[b] - cyc));
                if (cyc - t_last_act[b] < TRC) fail($sformatf("tRC violated on bank %0d (%0d < %0d clocks)", b, cyc - t_last_act[b], TRC));
                t_last_act[b] = cyc;
                bank_open[b] = 1;
                bank_row[b]  = dram_a;
                t_act[b]     = cyc;
            end
            CMD_READ, CMD_WRITE: begin
                if (!init_done) fail("READ/WRITE before init sequence complete");
                else if (!bank_open[b]) fail($sformatf("READ/WRITE on closed bank %0d", b));
                else begin
                    if (cyc - t_act[b] < TRCD)
                        fail($sformatf("tRCD violated on bank %0d (%0d < %0d clocks)", b, cyc - t_act[b], TRCD));
                    col = dram_a[9:0];
                    if (cmd == CMD_WRITE) begin
                        key = {dram_ba, bank_row[b], col};
                        // DQM high masks the byte; dqm[0] is the low byte
                        if (!mem.exists(key)) mem[key] = 16'h0;
                        if (!dram_dqm[0]) mem[key][7:0]  = dram_dq[7:0];
                        if (!dram_dqm[1]) mem[key][15:8] = dram_dq[15:8];
                    end else begin
                        for (int i = 0; i < BL; i++) begin
                            key = {dram_ba, bank_row[b], col[9:2], 2'((int'(col[1:0]) + i) & 3)};
                            pipe_d[cl-1+i] = mem.exists(key) ? mem[key] : 16'hxxxx;
                            pipe_v[cl-1+i] = 1;
                        end
                    end
                    if (dram_a[10]) auto_precharge(b, cmd == CMD_READ ? BL : 1 + TWR_CLK);
                end
            end
            CMD_NOP: ;
            default: fail("unsupported command (burst terminate)");
        endcase

        if (!init_done && pre_seen && init_refs >= 2 && mrs_done && emrs_done) begin
            init_done   = 1;
            t_init_done = $realtime;
        end

        dqm_d2 = dqm_d1;
        dqm_d1 = dram_dqm;

        // Refresh rate, after init only
        if (init_done && !rate_error &&
            int'($floor(($realtime - t_init_done) / REFRESH_NS)) - refresh_count > MAX_POSTPONE) begin
            rate_error = 1;
            fail($sformatf("refresh rate too low: %0d refreshes in %0.0f ns", refresh_count, $realtime - t_init_done));
        end
    end
endmodule
