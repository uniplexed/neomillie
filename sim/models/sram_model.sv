// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Behavioural AS6C2016-55BIN (128K x 16 asynchronous SRAM, 55 ns) of the Analogue Pocket, with
// timing checks. Numbers: Alliance Memory AS6C2016 datasheet Rev 1.1, May 2021, "AC electrical
// characteristics", page 6 (read and write cycle tables, 55 ns column).
//
// CE# is not on the Pocket's pin list (sram_a, sram_dq, sram_oe_n, sram_we_n, sram_ub_n,
// sram_lb_n), so it is ASSUMED tied active on the board: the chip is always selected, a write is
// WE# low with UB# or LB# low, and each byte lane is written on its own.
//
// The pins of this model see the FPGA signals with no delay, so two margins stand in for the real
// pads, board and fabric (the windows STA enforces in pocket.sdc; board flight 0.4 ns each way is
// ASSUMED, there is no board data):
//  - IO_NS, round trip: FPGA register -> fabric -> pad -> chip -> pad -> fabric -> capture
//    register. Read data is only valid IO_NS after the datasheet time, and the bus stays driven
//    IO_NS past tOHZ/tBHZ/tWHZ (pessimistic there: those pad delays mostly cancel).
//  - SKEW_NS: a pulse (WE#) is this much narrower at the chip than at the FPGA register, the
//    rise and fall of one output differ (ASSUMED 2.0 ns, as in psram_model).
//  - ORDER_NS: two outputs launched by edges one clock apart can arrive this close in the wrong
//    order. It is the width of the output window pocket.sdc enforces: no pin arrives more than
//    OUT_MAX 2.0 ns before the next edge or less than 1.0 ns after its own, 20.687 - 2.0 - 1.0 -
//    0.12 (clock uncertainty) = 17.6 ns. Every setup and hold between two different pins (tAS,
//    tAW, tDW, tBW, tWR, tDH) must hold by this much more, which a controller only meets by
//    keeping the pins a whole clock apart.
//
// Each check is an $error and bumps error_count; with quiet set only expected_count is bumped
// (for benches that expect a violation). Before the read data is valid the model drives the
// inverse of the word, so sampling too early gives wrong data too.
//
// Not modelled: tOH (data hold after an address change; the model switches at once, which is
// pessimistic for a late sampler), tOW (output active after a write, OE# is high during writes).
`timescale 1ns/1ps
module sram_model #(
    parameter real IO_NS    = 26.0,
    parameter real SKEW_NS  = 2.0,
    parameter real POLL_NS  = 1.0,
    parameter real ORDER_NS = 17.6,
    parameter bit  QUIET   = 0
) (
    input  wire [16:0] a,
    inout  wire [15:0] dq,
    input  wire        oe_n,
    input  wire        we_n,
    input  wire        ub_n,
    input  wire        lb_n,
    input  wire [1:0]  fpga_dq_oe,  // [1] high byte, [0] low byte: Verilator resolves no Z to test
    // A reset can cut a write short: that word is undefined, and the sweep that follows writes every
    // word again. High only in the clocks where sram_port takes WE# away, and it spares only the
    // width checks of the write ending then; the bench checks the sweep's result.
    input  wire        cut_write_ok
);
    // Read cycle, AS6C2016-55
    localparam real T_AA   = 55.0;   // address access
    localparam real T_OE   = 30.0;   // OE# access
    localparam real T_OLZ  = 5.0;    // OE# to low-Z
    localparam real T_OHZ  = 20.0;   // OE# to high-Z
    localparam real T_BA   = 55.0;   // UB#/LB# access
    localparam real T_BHZ  = 25.0;   // UB#/LB# to high-Z
    localparam real T_BLZ  = 10.0;   // UB#/LB# to low-Z
    // Write cycle, AS6C2016-55
    localparam real T_WC   = 55.0;
    localparam real T_AW   = 50.0;   // address valid to end of write
    localparam real T_AS   = 0.0;
    localparam real T_WP   = 45.0;
    localparam real T_WR   = 0.0;
    localparam real T_DW   = 25.0;
    localparam real T_DH   = 0.0;
    localparam real T_WHZ  = 20.0;
    localparam real T_BW   = 50.0;

    logic [15:0] mem [0:131071];

    // Power-up contents: not zero anywhere, so a reset clear is really observed
    initial for (int i = 0; i < 131072; i++) mem[i] = 16'hC000 | 16'(i);

    // Public status for the testbench
    int error_count    = 0;
    int expected_count = 0;
    bit quiet          = QUIET;

    realtime t_addr_change = -1000, t_data_change = -1000, t_oe_fall = -1000, t_wend = -1000;
    realtime t_lane_fall [2] = '{-1000, -1000};
    realtime t_fpga_release [2] = '{-1000, -1000};
    realtime t_chip_release [2] = '{-1000, -1000};

    logic [15:0] dq_drv = 0;
    bit   [1:0]  dq_en = 0;
    assign dq[7:0]  = dq_en[0] ? dq_drv[7:0]  : 8'bz;
    assign dq[15:8] = dq_en[1] ? dq_drv[15:8] : 8'bz;

    wire [1:0] lane_n = {ub_n, lb_n};

    task automatic fail(string msg);
        if (quiet) expected_count++;
        else begin
            error_count++;
            $error("sram_model t=%0.2f ns: %s", $realtime, msg);
        end
    endtask

    function automatic realtime later(realtime x, realtime y);
        return x > y ? x : y;
    endfunction

    task automatic min_check(realtime since, real limit, string name);
        if ($realtime - since < limit + SKEW_NS)
            fail($sformatf("%s: %0.2f ns < %0.1f + %0.1f skew", name, $realtime - since, limit, SKEW_NS));
    endtask

    task automatic order_check(realtime since, real limit, string name);
        if ($realtime - since < limit + ORDER_NS)
            fail($sformatf("%s: %0.2f ns < %0.1f + %0.1f order margin", name, $realtime - since, limit, ORDER_NS));
    endtask

    // When the read data of one byte lane is valid at the FPGA capture register
    function automatic realtime read_valid_time(int l);
        realtime t = later(t_addr_change + T_AA, t_oe_fall + T_OE);
        return later(t, t_lane_fall[l] + T_BA) + IO_NS;
    endfunction

    // ---- Address, data and control events ----

    always @(a) begin
        if ({~we_n & ~ub_n, ~we_n & ~lb_n} != 0) fail($sformatf("address changed to %h during a write (WE# %b UB# %b LB# %b)", a, we_n, ub_n, lb_n));
        order_check(t_wend, T_WR, "tWR");
        t_addr_change = $realtime;
    end

    // The FPGA's own data lines: a change or a release is a data event
    always @(dq or fpga_dq_oe) if (fpga_dq_oe != 0) begin
        order_check(t_wend, T_DH, "tDH");
        t_data_change = $realtime;
    end

    always @(negedge oe_n) t_oe_fall = $realtime;
    always @(negedge lb_n) t_lane_fall[0] = $realtime;
    always @(negedge ub_n) t_lane_fall[1] = $realtime;

    // ---- Write, per byte lane: WE# low and the lane enable low ----

    generate
        for (genvar l = 0; l < 2; l++) begin : g_lane
            wire wr = ~we_n & ~lane_n[l];
            realtime t_start = -1000, t_prev_start = -1000;
            logic [16:0] wr_addr;

            always @(posedge wr) begin
                t_prev_start = t_start;
                t_start      = $realtime;
                wr_addr      = a;
                order_check(t_addr_change, T_AS, "tAS");
                if (t_start - t_prev_start < T_WC) fail("tWC");
                if (!oe_n) fail("OE# low during a write");
            end

            always @(negedge wr) if (t_start >= 0) begin
                if (!cut_write_ok) begin
                    min_check(t_start, T_WP, "tWP");
                    order_check(t_addr_change, T_AW, "tAW");
                    order_check(t_data_change, T_DW, "tDW");
                    order_check(t_lane_fall[l], T_BW, "tBW");
                end
                if (!fpga_dq_oe[l]) fail("write data not driven");
                mem[wr_addr][8*l +: 8] = dq[8*l +: 8];
                t_wend = $realtime;
            end
        end
    endgenerate

    // ---- Read and bus ownership, per byte lane ----

    always @(posedge oe_n)
        for (int l = 0; l < 2; l++)
            if (dq_en[l]) t_chip_release[l] = later(t_chip_release[l], $realtime + T_OHZ + IO_NS);
    always @(posedge lb_n) if (dq_en[0]) t_chip_release[0] = later(t_chip_release[0], $realtime + T_BHZ + IO_NS);
    always @(posedge ub_n) if (dq_en[1]) t_chip_release[1] = later(t_chip_release[1], $realtime + T_BHZ + IO_NS);
    always @(negedge we_n)
        for (int l = 0; l < 2; l++)
            if (dq_en[l]) t_chip_release[l] = later(t_chip_release[l], $realtime + T_WHZ + IO_NS);

    always @(negedge fpga_dq_oe[0]) t_fpga_release[0] = $realtime;
    always @(negedge fpga_dq_oe[1]) t_fpga_release[1] = $realtime;

    always @(posedge fpga_dq_oe[0])
        if (dq_en[0]) fail($sformatf("DQ contention: FPGA drives the low byte %0.2f ns before the chip has released",
                                     t_chip_release[0] - $realtime));
    always @(posedge fpga_dq_oe[1])
        if (dq_en[1]) fail($sformatf("DQ contention: FPGA drives the high byte %0.2f ns before the chip has released",
                                     t_chip_release[1] - $realtime));

    // The chip drives a lane while OE# and the lane enable are low and WE# is high, from the low-Z
    // time on, and for the release time after that. Polled: pin events are not in simulation steps.
    always #(POLL_NS) begin
        for (int l = 0; l < 2; l++) begin
            if (!oe_n && we_n && !lane_n[l]
                && $realtime >= later(t_oe_fall + T_OLZ, t_lane_fall[l] + T_BLZ)) begin
                if (!dq_en[l]) begin
                    if ($realtime - t_fpga_release[l] < IO_NS || fpga_dq_oe[l])
                        fail($sformatf("DQ contention: chip drives byte %0d while the FPGA has not released (%0.1f ns I/O)", l, IO_NS));
                    dq_en[l] = 1;
                end
                dq_drv[8*l +: 8] = $realtime < read_valid_time(l) ? ~mem[a][8*l +: 8] : mem[a][8*l +: 8];
            end else if (dq_en[l] && $realtime >= t_chip_release[l]) begin
                dq_en[l] = 0;
            end
        end
    end
endmodule
