// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Asynchronous controller for one AS1C8M16PL-70BIN PSRAM chip of the Analogue Pocket (CRAM0 or
// CRAM1: two 4M x 16 dies behind CE0#/CE1#, A[15:0] multiplexed on DQ). Timing sequence after
// Mazamars312's psram_controller.v, reimplemented with a registered data input, a level
// request and an idle bus cycle on each DQ direction change.
//
// Numbers: Alliance Memory AS1C8M16PL-70BIN datasheet, Rev 1.0 Aug 2018, tables 13 and 15.
// Clock: CLK_96M, shortest period T = 10.34 ns. E<n> is the clock edge n clocks after CE#/ADV#
// fall; every chip pin changes on an edge.
//
//   Read:  E0 CE#, ADV#, UB#, LB# low, address on A and DQ
//          E1 ADV# high (tVP 5, tAVS 5, tCVS 7)
//          E2 DQ released (tAVH 2)
//          E3 OE# low (tOLZ 3 is not enough against the FPGA's own output disable, so a clock apart)
//          E<RD_WAIT> sample, CE#, OE#, UB#, LB# high, ack
//   Write: E0 CE#, ADV#, UB#/LB# as be, address on A and DQ
//          E1 WE# low (tAS 0, with ADV# still low)
//          E2 ADV# high
//          E3 data on DQ (tAVH 2)
//          E<WR_WAIT+1> CE#, WE#, UB#, LB# high, ack; DQ held one more clock (tDH 0)
//
// Request: addr, we, wdata and be stay stable while req is high. ack is one clock; rdata is only
// valid in that clock (it is the IOE input register, free running). A registered master sees ack
// when req is still up, so req is not looked at until the clock after ack: the next access can
// start 2 clocks after ack rises.
//
// CE# is high whenever idle, which also gives the chip its refresh opportunity (tCEM 4 us; the
// longest access here is under 100 ns). The BCR powers up in asynchronous mode (9D1Fh) and is
// never written, so CLK and CRE stay low and WAIT is ignored, as the datasheet says for
// asynchronous reads. Power-up tPU 150 us has passed long before a core is loaded.
module cram_ctrl #(
    // Must cover tAA 70 ns plus 11.22 ns of pads and flight (pocket.sdc, 0.8 ns assumed for the
    // board): 8 clocks = 82.72 ns at T = 10.34 ns. At least 4, or OE# is never low.
    parameter RD_WAIT = 8,      // clk cycles from ADV# low to data sample
    // E0 to the end of the write must cover tCW = tAW = tBW = tVS = 70 ns plus 2 ns of pad skew:
    // 7 clocks = 72.38 ns. tWP 45 and tDW 20 are then well inside.
    parameter WR_WAIT = 6,      // clk cycles WE# held low
    // Idle cycles between OE# rising and the state that can drive DQ again. Must be at least 1:
    // it covers the ack clock, and 0 re-drives DQ one clock after OE# rises on a stale request.
    // 1 gives 2 clocks = 20.68 ns against tOHZ 7 ns plus the same 11.22 ns.
    parameter TURN    = 1
) (
    input             clk,
    input             rst,

    // Pocket pins
    output reg [21:16] cram_a = 0,
    inout      [15:0]  cram_dq,
    input              cram_wait,
    output             cram_clk,
    output reg         cram_adv_n = 1,
    output             cram_cre,
    output reg         cram_ce0_n = 1,
    output reg         cram_ce1_n = 1,
    output reg         cram_oe_n = 1,
    output reg         cram_we_n = 1,
    output reg         cram_ub_n = 1,
    output reg         cram_lb_n = 1,

    // Request port (level handshake)
    input              req,     // held high until ack
    input              we,
    input      [23:1]  addr,    // word address, bit 23 selects the die (CE1#)
    input      [15:0]  wdata,
    input      [1:0]   be,      // byte enables for writes: bit 1 high byte, bit 0 low byte
    output     [15:0]  rdata,   // valid with ack
    output reg         ack = 0  // one clk pulse; req may drop or change the same cycle
);

localparam STATE_IDLE   = 0;
localparam STATE_ACCESS = 1;
localparam STATE_GAP    = 2;

reg  [1:0] state = STATE_IDLE;
reg  [4:0] t = 0;               // ACCESS: n in E<n> of the next edge; GAP: clocks left
reg [15:0] dq_out = 0;
reg [15:0] dq_in = 0;
reg        dq_oe = 0;

assign cram_dq  = dq_oe ? dq_out : 16'bZ;
assign rdata    = dq_in;
assign cram_clk = 0;
assign cram_cre = 0;

always @(posedge clk) begin
    dq_in <= cram_dq;
    ack   <= 0;

    case (state)
        STATE_IDLE:
            if (req) begin
                cram_ce0_n <=  addr[23];
                cram_ce1_n <= ~addr[23];    // never both low
                cram_adv_n <= 0;
                cram_a     <= addr[22:17];
                dq_out     <= addr[16:1];
                dq_oe      <= 1;
                {cram_ub_n, cram_lb_n} <= we ? ~be : 2'b00;
                t          <= 1;
                state      <= STATE_ACCESS;
            end

        STATE_ACCESS: begin
            t <= t + 1'd1;
            if (we) begin
                if (t == 1) cram_we_n  <= 0;
                if (t == 2) cram_adv_n <= 1;
                if (t == 3) dq_out     <= wdata;
            end else begin
                if (t == 1) cram_adv_n <= 1;
                if (t == 2) dq_oe      <= 0;
                if (t == 3) cram_oe_n  <= 0;
            end
            if (t == (we ? WR_WAIT + 1 : RD_WAIT)) begin
                {cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n} <= '1;
                ack   <= 1;
                t     <= we ? 5'd1 : 5'(TURN);
                state <= (we || TURN != 0) ? STATE_GAP : STATE_IDLE;
            end
        end

        STATE_GAP: begin
            dq_oe <= 0;
            t     <= t - 1'd1;
            if (t == 1) state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
    endcase

    if (rst) begin
        {cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n, cram_adv_n} <= '1;
        dq_oe <= 0;
        ack   <= 0;
        state <= STATE_IDLE;
    end
end

endmodule
