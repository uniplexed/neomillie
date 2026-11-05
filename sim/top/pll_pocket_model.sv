// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Stands in for pll_pocket in the top-level bench: same ports, the real pll_mvs_cfg, and behavioural
// clocks and reconfiguration slave in place of altera_pll and altera_pll_reconfig. The slave is as
// sim/pll models it: waitrequest high while busy or unlocked, lock drops 16 clocks after the start
// write. What the clocks do while unlocked was not measured on the real PLL, and both cases matter:
// clocks running is what makes logic see locked low (MEM_INIT, RESET), clocks stopped freezes everything
// mid-way. Relocks 1 and 2 run, relock 3 stops: boot, MVS to AES, AES to MVS in the bench. All four
// clocks come from one process, so that the 48 MHz edge lands on the 96 MHz edge with no delta between
// them, as with one VCO.
`timescale 1ns/1ps
module pll_pocket #(
    parameter real POWERUP_US = 20.0,
    parameter real RELOCK_US  = 50.0
) (
    input  wire refclk,
    input  wire rst,
    input  wire mvs,
    output reg  CLK_96M = 0,
    output reg  CLK_48M = 0,
    output reg  CLK_PIX = 0,
    output reg  CLK_PIX_90 = 0,
    output reg  locked = 0,
    output wire reconfiguring
);
    localparam real PERIOD_AES = 10.344;    // 96.671316 MHz
    localparam real PERIOD_MVS = 10.417;    // 96.000 MHz

    real period = PERIOD_AES;
    bit  run = 0;
    int  relocks = 0;       // for the bench

    // ---- The slave ----
    wire        mgmt_write;
    wire  [5:0] mgmt_address;
    wire [31:0] mgmt_writedata;
    logic       busy = 0;
    int         sc = -1;
    logic [31:0] k = 32'd1785695733;

    pll_mvs_cfg cfg (
        .clk_74a(refclk), .rst(rst), .mvs(mvs), .locked(locked), .reconfiguring(reconfiguring),
        .mgmt_waitrequest(busy | ~locked), .mgmt_write(mgmt_write),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata)
    );

    always @(posedge refclk) begin
        if (mgmt_write && !(busy | ~locked)) begin
            if (mgmt_address == 6'd7) k <= mgmt_writedata;
            if (mgmt_address == 6'd2) begin
                busy <= 1;
                sc   <= 0;
            end
        end
        if (sc >= 0) begin
            sc <= sc + 1;
            if (sc == 10) busy <= 0;
            if (sc == 16) begin
                sc <= -1;
                relocks++;
                run    = relocks != 3;
                locked = 0;
                period = k == 32'd1475039273 ? PERIOD_MVS : PERIOD_AES;
                relock_ev = !relock_ev;
            end
        end
    end

    // ---- Lock ----
    bit relock_ev = 0;
    initial begin
        #(POWERUP_US * 1000.0);
        run    = 1;
        locked = 1;
    end
    always @(relock_ev) begin
        #(RELOCK_US * 1000.0);
        run    = 1;
        locked = 1;
    end

    // ---- Clocks ----
    int n = 0;
    initial forever begin
        #(period / 2);
        if (run) begin
            CLK_96M = 1;
            CLK_48M = ~CLK_48M;
            if (n % 8 == 0)     CLK_PIX    = ~CLK_PIX;
            if (n % 8 == 4)     CLK_PIX_90 = ~CLK_PIX_90;
            n++;
        end
        #(period / 2);
        CLK_96M = 0;
    end
endmodule
