// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// FIX RAM of the CD build in the Analogue Pocket's AS6C2016-55BIN (128K x 16 asynchronous SRAM, 55 ns):
// SRAM word 0x0000-0xFFFF, 128 KB. It takes sram_ctrl's place: the CD's work RAM is PROG RAM, and there is no
// clear, as the BIOS uploads the fix. Nothing here relies on a reset: an access always runs to its end.
//
// One access at a time, from pocket_mem_mux's arbiter: req toggles with we, word, be and wdata stable, and ack
// is made equal to req when the access is over. The two are in the related CLK_96M: a CLK_48M edge sees req at
// most a CLK_96M after it changes. rdata is the chip's data registered once, every clock, and the only pin
// path of the read data. After a read the pins stay as they are, so rdata holds until the next access.
//
// Every pin is a register on CLK_48M, in the windows of pocket.sdc (shortest period T = 20.687 ns; of two pins
// launched a clock apart the later cannot arrive first, sram_model's ORDER_NS of 17.6 ns):
//  - Read: address, OE# and both lanes on one edge, and the data is taken RD_CLKS edges later. pocket.sdc's
//    -setup 4 from the pins (input delay 74.5 ns, 82.7 ns available) is met by STA at edge 4. RD_CLKS is 5, a
//    clock over that for the board's unknowns: the fix's budget has room for it, see below.
//  - Write: the address and the lanes on one edge. OE# rises there too, and if it was low the data pins wait
//    RELEASE_CLKS (62 ns against tBHZ 25 ns plus the 26 ns round trip of sram_model). A clock after them WE# falls for
//    WE_CLKS (62 ns against tWP 45 ns plus 2 ns of skew). The lanes then have 5 clocks to WE#'s rise (103 ns
//    against tBW 50 ns plus the 17.6 ns window), the address too (tAW 50), the data 4 (82 ns against tDW 25).
//    The data pins stay driven a clock past WE#, as tDH is 0, and nothing moves for another clock (tWR 0).
//    OE# stays high until the next read, so a stream of writes does not wait to release.
//  - Read after write: the data pins were released at least 2 clocks before OE# falls (41 ns against the round trip).
//
// From PCK2's fall: a CLK_96M to the mux's arbiter, a CLK_48M at most to the address, RD_CLKS to the data and a
// CLK_96M to SROM_DATA, 13 or 14 clocks of CLK_96M against FIX_DEADLINE's 23.
module cd_fix_sram #(
    parameter RD_CLKS      = 5,
    parameter RELEASE_CLKS = 3,
    parameter WE_CLKS      = 3
) (
    input             clk,          // CLK_48M

    input             req,          // toggle
    input             we,
    input      [15:0] word,
    input       [1:0] be,           // bit 1 high byte, bit 0 low byte, for writes
    input      [15:0] wdata,
    output reg        ack = 0,      // toggle, equal to req when the access is over
    output reg [15:0] rdata = 0,

    // Pocket pins
    output     [16:0] sram_a,
    inout      [15:0] sram_dq,
    output reg        sram_oe_n = 1,
    output reg        sram_we_n = 1,
    output reg        sram_ub_n = 1,
    output reg        sram_lb_n = 1
);

localparam [2:0] S_IDLE = 0, S_READ = 1, S_RELEASE = 2, S_DATA = 3, S_PULSE = 4, S_HOLD = 5, S_END = 6;

reg   [2:0] state = S_IDLE;
reg   [2:0] cnt = 0;
reg  [15:0] a_r = 0;
reg  [15:0] dq_o = 0;
reg   [1:0] dq_oe = 0;

assign sram_a = {1'b0, a_r};
assign sram_dq[7:0]  = dq_oe[0] ? dq_o[7:0]  : 8'bz;
assign sram_dq[15:8] = dq_oe[1] ? dq_o[15:8] : 8'bz;

always @(posedge clk) begin
    rdata <= sram_dq;

    case (state)
        S_IDLE: if (req != ack) begin
            a_r <= word;
            if (we) begin
                sram_oe_n <= 1;
                {sram_ub_n, sram_lb_n} <= ~be;
                cnt   <= sram_oe_n ? 3'd0 : 3'(RELEASE_CLKS - 1);
                state <= S_RELEASE;
            end else begin
                sram_oe_n <= 0;
                {sram_ub_n, sram_lb_n} <= 2'b00;
                cnt   <= 3'(RD_CLKS - 1);
                state <= S_READ;
            end
        end
        S_READ: begin
            cnt <= cnt - 1'd1;
            if (cnt == 0) begin     // rdata takes the data on this edge
                ack   <= req;
                state <= S_IDLE;
            end
        end
        S_RELEASE: begin
            cnt <= cnt - 1'd1;
            if (cnt == 0) begin
                dq_o  <= wdata;
                dq_oe <= be;
                state <= S_DATA;
            end
        end
        S_DATA: begin
            sram_we_n <= 0;
            cnt   <= 3'(WE_CLKS - 1);
            state <= S_PULSE;
        end
        S_PULSE: begin
            cnt <= cnt - 1'd1;
            if (cnt == 0) begin
                sram_we_n <= 1;
                state <= S_HOLD;
            end
        end
        S_HOLD: begin
            dq_oe <= 0;
            state <= S_END;
        end
        S_END: begin
            ack   <= req;
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
    endcase
end

endmodule
