// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// 68000 work RAM in the Analogue Pocket's AS6C2016-55BIN (128K x 16 asynchronous SRAM, 55 ns):
// SRAM word 0x0000-0x7FFF = 64 KB, nothing else (the memory card stays in block RAM).
// Pin handling and clear-on-reset after Mazamars312's SRAM_CONTROLLER_NEOGEO.v, reimplemented:
// the clear writes 0x0000 and keeps every pin edge a clock from the others.
//
// Asynchronous like the SRAM it replaces on the real console: address, data and the four 68K
// strobes go combinationally to the pins (nWRL/nWRU read strobes -> OE#, nWWL/nWWU write strobes
// -> WE#, both -> the byte enables UB#/LB#). The 68K must keep wram_addr/wram_din stable from
// before a strobe to after it (the fx68k does, by at least 2 CLK_48M cycles). Each write
// strobe must last 4 CLK_48M cycles or more (tBW 50 ns plus the 17.6 ns pin window of pocket.sdc;
// the shortest real one, measured with the fx68k in sim/top, is 6). The data pins stay driven a
// clock after the write strobe, as tDH is 0. wram_dout is the chip's data registered once, one
// clock behind the pins: the only pin path of the read data is pad to register, and the 68K sees
// the data a clock later.
//
// Clear: a falling edge of rst_n, even a one clock pulse, starts a sweep that always runs to the
// end: every one of the 32768 words is written with 0x0000, CLR_CYCLE_CLKS (5) clocks per word
// (WE# low CLR_WE_CLKS = 3 clocks = 62 ns for tWP 45, then the rest high around the address
// change), from word 0, whatever rst_n does meanwhile. A second falling edge during the sweep
// does not restart it. A sweep is 32768 x CLR_CYCLE_CLKS = 163840 CLK_48M cycles (3.39 ms at
// 48.336 MHz) plus 5. It also runs once after configuration. rst_n must be synchronous to clk.
// A reset lands wherever the 68K is, so the strobes go inactive first and the sweep takes the pins 3
// clocks later (62 ns): a read in flight leaves the chip driving for tOHZ 20 ns plus the pad and board
// delays, and a write in flight gets its data held a clock past WE# and its address past that. The
// Overdrive switches at once and runs on real Pockets; this is the data sheet's order, with the 3
// clocks counted by the entry register.
// busy is high from the clock after rst_n falls until the last word's WE# is high and the pins
// are released: when it falls the whole work RAM is 0x0000. The 68K signals are ignored while
// the sweep owns the pins.
//
// Task 9 rule: hold the core in reset with  core_reset = ~rst_n | busy  on the same synchronous
// rst_n that feeds sram_ctrl. busy alone has a one clock gap after rst_n falls (it rises on the
// next edge), and the core must not touch the work RAM while either is high.
module sram_ctrl #(
    // Clear: clocks per word and of them WE# low. The address changes while WE# has been high
    // for a clock and WE# falls a clock after that: CLR_CYCLE_CLKS >= CLR_WE_CLKS + 2. WE# low
    // 3 clocks = 62.1 ns at the shortest period of 20.687 ns (AES 48.336 MHz) against tWP 45 +
    // 2 ns; 5 clocks = 103 ns against tWC 55 ns.
    parameter CLR_WE_CLKS    = 3,
    parameter CLR_CYCLE_CLKS = 5
) (
    input             clk,          // CLK_48M
    input             rst_n,

    // Pocket pins
    output     [16:0] sram_a,
    inout      [15:0] sram_dq,
    output            sram_oe_n,
    output            sram_we_n,
    output            sram_ub_n,
    output            sram_lb_n,

    // 68K work RAM window, asynchronous
    input      [15:1] wram_addr,
    input      [15:0] wram_din,
    output     [15:0] wram_dout,    // the chip's data, registered (one clock behind the pins)
    input             nWRL,         // read strobes, low byte / high byte
    input             nWRU,
    input             nWWL,         // write strobes
    input             nWWU,

    output            busy          // a clear sweep is running: the work RAM is not all 0 yet
);

localparam CPW = $clog2(CLR_CYCLE_CLKS);        // clear phase 0 .. CLR_CYCLE_CLKS-1

`ifndef SYNTHESIS
initial if (CLR_CYCLE_CLKS < CLR_WE_CLKS + 2 || CLR_WE_CLKS < 1)
    $error("sram_ctrl: CLR_CYCLE_CLKS must be at least CLR_WE_CLKS + 2");
`endif

// ---- Clear sweep ----

reg        run      = 1;    // a sweep is running (also after configuration): the 68K's strobes are off
reg        clearing = 1;    // the pins belong to the sweep: run, 3 clocks later
reg  [1:0] entry    = 0;    // clocks since run rose, up to when clearing rises
reg        clr_we_n = 1;
reg [14:0] clr_a    = 0;
reg [CPW-1:0] clr_ph = 0;   // WE# is low in 1..CLR_WE_CLKS, the address changes after the last phase
reg        rst_q    = 1;

wire [CPW-1:0] clr_ph_next = (clr_ph == CPW'(CLR_CYCLE_CLKS - 1)) ? {CPW{1'b0}} : clr_ph + 1'd1;

always @(posedge clk) begin
    rst_q <= rst_n;
    if (run) begin
        if (!clearing) begin
            entry <= entry + 1'd1;
            if (entry == 2'd2) clearing <= 1;
        end else begin          // the first clock only takes the pins: address and WE# apart
            clr_we_n <= (clr_ph_next == 0) || (clr_ph_next > CPW'(CLR_WE_CLKS));
            clr_ph   <= clr_ph_next;
            if (clr_ph_next == 0) begin
                clr_a <= clr_a + 1'd1;
                if (clr_a == 15'h7FFF) begin    // the last word is done, its WE# has been high a clock
                    run      <= 0;
                    clearing <= 0;
                    entry    <= 0;
                end
            end
        end
    end else if (rst_q && !rst_n) begin
        run <= 1;
    end
end

assign busy = run;

// ---- Pins: the sweep, else the 68K ----

// The data pins are released a clock after the write strobe, so they are still driven when WE#
// rises (tDH is 0 and an output enable path is not the same as a data path).
reg [1:0] wr_hold = 0;
always @(posedge clk) wr_hold <= ~{nWWU, nWWL};

assign sram_a    = clearing ? {2'b00, clr_a} : {2'b00, wram_addr};
assign sram_oe_n = run      ? 1'b1           : &{nWRL, nWRU};
assign sram_we_n = clearing ? clr_we_n       : run ? 1'b1 : &{nWWL, nWWU};
assign sram_ub_n = clearing ? 1'b0           : run ? 1'b1 : &{nWWU, nWRU};
assign sram_lb_n = clearing ? 1'b0           : run ? 1'b1 : &{nWWL, nWRL};

wire [15:0] dq_o  = clearing ? 16'h0000 : wram_din;
wire  [1:0] dq_oe = clearing ? 2'b11    : run ? (entry == 0 ? wr_hold : 2'b00) : ~{nWWU, nWWL} | wr_hold;

assign sram_dq[7:0]  = dq_oe[0] ? dq_o[7:0]  : 8'bz;
assign sram_dq[15:8] = dq_oe[1] ? dq_o[15:8] : 8'bz;

reg [15:0] wram_q = 0;
always @(posedge clk) wram_q <= sram_dq;
assign wram_dout = wram_q;

endmodule
