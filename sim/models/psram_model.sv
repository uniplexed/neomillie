// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Behavioural AS1C8M16PL-70BIN of the Pocket (one chip: two 4M x 16 dies behind CE0#/CE1#,
// multiplexed A/DQ) in asynchronous mode, the BCR default after power-up, with timing checks.
// Numbers: Alliance Memory datasheet Rev 1.0 Aug 2018, tables 13 and 15 (pages 30 and 32).
// tVS runs from ADV# falling to the end of the WRITE (figure 31, page 42).
//
// The pins of this model see the FPGA registers with no delay, so two margins stand in for the
// real pads and board (the windows STA enforces in pocket.sdc; board flight 0.4 ns each way is
// assumed):
//  - IO_NS, round trip: output register -> pad -> chip -> pad -> input register, 8.71 + 0.4 +
//    0.4 + 1.71 = 11.22 (11.47 on the memory test top, see synth/memtest/memtest.sdc). Read data is only valid IO_NS after the datasheet time, and the bus
//    stays driven IO_NS past tOHZ/tHZ (pessimistic there: those pad delays mostly cancel).
//  - SKEW_NS, pad to pad: every minimum between two FPGA outputs must hold by this much more.
//    1.1 measured between pins, 0.4 assumed for the board, rounded up.
//
// Each check is an $error and bumps error_count (QUIET keeps only the count, for benches that
// expect a violation). Before tAA the model drives the inverse of the word, so sampling too
// early also gives wrong data.
//
// Not modelled: tPU (150 us after power, long gone when a core is running) and refresh
// collisions (hidden from asynchronous accesses as long as CE# rises within tCEM).
`timescale 1ns/1ps
module psram_model #(
    parameter real IO_NS   = 11.22,
    parameter real SKEW_NS = 2.0,
    parameter real T_ACC   = 70.0,  // tAA, tAADV, tCO, tBA; the data sheet's. Faster only to run RD_WAIT 7 or 6
    parameter real POLL_NS = 0.1,   // read and bus ownership are polled: a whole core runs slowly at 0.1
    parameter bit  QUIET   = 0
) (
    input  wire [21:16] a,
    inout  wire [15:0]  dq,
    input  wire         clk,
    input  wire         cre,
    input  wire         adv_n,
    input  wire         ce0_n,
    input  wire         ce1_n,
    input  wire         oe_n,
    input  wire         we_n,
    input  wire         ub_n,
    input  wire         lb_n,
    input  wire         fpga_dq_oe  // the controller's DQ output enable: Verilator resolves no Z to test
);
    localparam real T_OE   = 20.0;
    localparam real T_OLZ  = 3.0;
    localparam real T_OHZ  = 7.0;    // also tHZ, tBHZ
    localparam real T_VP   = 5.0;
    localparam real T_AVS  = 5.0;
    localparam real T_AVH  = 2.0;
    localparam real T_CVS  = 7.0;
    localparam real T_CPH  = 5.0;
    localparam real T_CEM  = 4000.0;
    localparam real T_AS   = 0.0;
    localparam real T_WRITE = 70.0;  // tAW, tBW, tCW, tVS
    localparam real T_WP   = 45.0;
    localparam real T_DW   = 20.0;
    localparam real T_DH   = 0.0;

    localparam logic [21:0] TOP_WORD = 22'h3FFFFF;

    logic [15:0] mem [bit [22:0]];

    wire ce_n = ce0_n & ce1_n;

    // Public status for the testbench
    int error_count  = 0;
    int access_count = 0;
    int sw_seq_count = 0;   // software access sequences seen (READ, READ, WRITE on the top word)
    // The reading of the datasheet the model does not assume by default: an access to another
    // address does not abort the sequence, the WRITE selects a register and the next access reads it
    bit seq_survives = 0;
    localparam logic [15:0] DIDR = 16'h0BAD;
    bit reg_next [2] = '{0, 0};
    logic [15:0] mem_before_write = 0;

    realtime t_ce_fall = -1000, t_ce_rise = -1000, t_adv_fall = -1000, t_adv_rise = -1000;
    realtime t_oe_fall = -1000, t_we_fall = -1000, t_ub_fall = -1000, t_lb_fall = -1000;
    realtime t_addr_change = -1000, t_wr_end = -1000;
    realtime t_fpga_release = -1000, t_chip_release = -1000;

    bit          die = 0;
    logic [21:0] addr = 0;
    bit          op_valid = 0, wr_seen = 0, wr_active = 0, ub_q = 1, lb_q = 1;
    int          sw_step [2] = '{0, 0};

    logic [15:0] dq_drv = 0;
    bit          dq_en = 0;
    assign dq = dq_en ? dq_drv : 16'bz;

    task automatic fail(string msg);
        error_count++;
        if (!QUIET) $error("psram_model t=%0.2f ns: %s", $realtime, msg);
    endtask

    function automatic realtime later(realtime x, realtime y);
        return x > y ? x : y;
    endfunction

    // When the read data is valid at the FPGA input register
    function automatic realtime read_valid_time();
        realtime t0 = later(later(t_ce_fall, t_adv_fall), later(t_ub_fall, t_lb_fall));
        return later(t0 + T_ACC, t_oe_fall + T_OE) + IO_NS;
    endfunction

    task automatic min_check(realtime since, real limit, string name);
        if ($realtime - since < limit + SKEW_NS)
            fail($sformatf("%s: %0.2f ns < %0.1f + %0.1f skew", name, $realtime - since, limit, SKEW_NS));
    endtask

    // ---- Chip enables ----

    always @(ce0_n or ce1_n)
        if (!ce0_n && !ce1_n) fail("CE0# and CE1# both low");

    always @(negedge ce_n) begin
        min_check(t_ce_rise, T_CPH, "tCPH");
        t_ce_fall = $realtime;
        die       = ce0_n;
        op_valid  = 0;
        wr_seen   = 0;
    end

    always @(posedge ce_n) begin
        t_ce_rise = $realtime;
        if ($realtime - t_ce_fall > T_CEM) fail("CE# low longer than tCEM");
        if (op_valid) begin
            // The data on DQ only turns at a poll, so a read is only certain one poll after the valid time
            if (!wr_seen && $realtime < read_valid_time() + POLL_NS)
                fail($sformatf("read ended %0.2f ns before valid data (tAA + %0.1f ns I/O + %0.1f ns poll)",
                               read_valid_time() + POLL_NS - $realtime, IO_NS, POLL_NS));
            access_count++;
            software_sequence(wr_seen);
        end
    end

    // The registers answer to READ, READ, WRITE, then READ or WRITE, all on the top word of the
    // die (datasheet page 19). The third step already commits the access, so it is flagged there.
    task automatic software_sequence(bit is_write);
        if (addr != TOP_WORD) begin
            if (!seq_survives) sw_step[die] = 0;
        end else if (!is_write) begin
            if (sw_step[die] < 2) sw_step[die]++;
            reg_next[die] = 0;
        end else begin
            if (sw_step[die] == 2) begin
                sw_seq_count++;
                if (seq_survives) begin
                    mem[{die, addr}] = mem_before_write;    // the WRITE only selected a register
                    reg_next[die] = 1;
                end else fail($sformatf("software access sequence on die %0d", die));
            end
            sw_step[die] = 0;
        end
    endtask

    // ---- Address phase ----

    always @(negedge adv_n) begin
        t_adv_fall = $realtime;
        if (!oe_n) fail("OE# low while the address is on the bus");
        if (clk || cre) fail("CLK or CRE not low: asynchronous array access expected");
    end

    always @(posedge adv_n) if (!ce_n) begin
        min_check(t_adv_fall, T_VP, "tVP");
        min_check(t_ce_fall, T_CVS, "tCVS");
        min_check(t_addr_change, T_AVS, "tAVS");
        if (!fpga_dq_oe) fail("address not driven at ADV# rising");
        t_adv_rise = $realtime;
        addr       = {a, dq};
        op_valid   = 1;
    end

    always @(dq or a or fpga_dq_oe) begin
        if (!ce_n && adv_n) min_check(t_adv_rise, T_AVH, "tAVH");
        min_check(t_wr_end, T_DH, "tDH");
        t_addr_change = $realtime;
    end

    // ---- Write ----

    always @(negedge ub_n) t_ub_fall = $realtime;
    always @(negedge lb_n) t_lb_fall = $realtime;

    always @(negedge we_n) if (!ce_n) begin
        min_check(t_adv_fall, T_AS, "tAS");
        t_we_fall = $realtime;
        wr_active = 1;
        wr_seen   = 1;
        ub_q      = ub_n;
        lb_q      = lb_n;
    end

    // The write ends on the first of WE# or CE# rising (the controller moves UB#/LB# with them,
    // and their levels were taken at WE# falling)
    always @(posedge we_n or posedge ce_n) if (wr_active) begin
        logic [22:0] key;
        key = {die, addr};
        wr_active = 0;
        min_check(t_we_fall, T_WP, "tWP");
        min_check(t_ce_fall, T_WRITE, "tCW");
        min_check(t_adv_fall, T_WRITE, "tVS");
        min_check(t_addr_change, T_DW, "tDW");
        if (!ub_q) min_check(t_ub_fall, T_WRITE, "tBW");
        if (!lb_q) min_check(t_lb_fall, T_WRITE, "tBW");
        if (!op_valid) fail("write without a latched address");
        if (!fpga_dq_oe) fail("write data not driven");
        if (!mem.exists(key)) mem[key] = 16'h0;
        mem_before_write = mem[key];
        if (!lb_q) mem[key][7:0]  = dq[7:0];
        if (!ub_q) mem[key][15:8] = dq[15:8];
        t_wr_end = $realtime;
    end

    // ---- Read and bus ownership ----

    always @(negedge oe_n) begin
        t_oe_fall = $realtime;
        if (!ce_n && (ub_n || lb_n)) fail("read with a byte disabled");
    end

    always @(posedge oe_n or posedge ce_n)
        if (dq_en) t_chip_release = $realtime + T_OHZ + IO_NS;

    always @(negedge fpga_dq_oe) t_fpga_release = $realtime;

    always @(posedge fpga_dq_oe)
        if (dq_en) fail($sformatf("DQ contention: FPGA drives %0.2f ns before the chip has released (tOHZ + %0.1f ns I/O)",
                                  t_chip_release - $realtime, IO_NS));

    always #(POLL_NS) begin
        if (!ce_n && !oe_n && we_n && $realtime >= t_oe_fall + T_OLZ) begin
            if (!dq_en) begin
                if ($realtime - t_fpga_release < IO_NS || fpga_dq_oe)
                    fail($sformatf("DQ contention: chip drives while the FPGA has not released (%0.1f ns I/O)", IO_NS));
                dq_en = 1;
            end
            dq_drv = reg_next[die] ? DIDR : mem.exists({die, addr}) ? mem[{die, addr}] : 16'h0;
            if ($realtime < read_valid_time()) dq_drv = ~dq_drv;
        end else if (dq_en && $realtime >= t_chip_release) begin
            dq_en = 0;
        end
    end
endmodule
