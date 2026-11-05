// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Based on the PLL reconfiguration block of NeoGeo_MiSTer (neogeo.sv, GPL-2.0-or-later).

// Switches the Neo Geo PLL between the AES/CD clock family (96.671316 MHz) and the
// MVS family (96.000 MHz) by rewriting the fractional multiplier (altera_pll_reconfig
// register 7) and issuing a start (register 2). The integer multiplier is the same in
// both modes (M = 10 for the 74.25 MHz reference, see tools/pll_calc.py).
//
// Notes for users:
// - 'reconfiguring' is in the clk_74a domain.
// - It is not asserted during the initial power-up lock; consumers must also use ~locked.
// - 'rst' must stay tied low in normal operation: a reset while in MVS mode makes
//   mvs_cur (assumed AES after reset) disagree with the K the PLL still holds.
//
// Release sequence after the start write: wait for 'locked' to drop (at most
// UNLOCK_TIMEOUT cycles; a small K change may legitimately never drop lock), then wait
// for locked && !waitrequest, then hold 'reconfiguring' for SETTLE_CYCLES more.
module pll_mvs_cfg #(
    parameter UNLOCK_TIMEOUT = 4096,    // clk_74a cycles to wait for lock to drop
    parameter SETTLE_CYCLES  = 256      // clk_74a cycles to hold after relock
) (
    input  wire        clk_74a,
    input  wire        rst,
    input  wire        mvs,                 // 1 = MVS (96.000 MHz) family; any clock domain
    input  wire        locked,              // PLL lock; any clock domain
    output reg         reconfiguring,       // high from an mvs change until the PLL relocked

    // Avalon-MM master to altera_pll_reconfig_top
    input  wire        mgmt_waitrequest,
    output reg         mgmt_write,
    output reg  [5:0]  mgmt_address,
    output reg  [31:0] mgmt_writedata
);
    // K = round(frac(M) * 2^32), values from tools/pll_calc.py
    localparam [31:0] K_AES = 32'd1785695733;
    localparam [31:0] K_MVS = 32'd1475039273;

    localparam [5:0] REG_K     = 6'd7;
    localparam [5:0] REG_START = 6'd2;

    localparam [2:0] IDLE = 3'd0, WRITE_K = 3'd1, WRITE_START = 3'd2,
                     WAIT_UNLOCK = 3'd3, WAIT_RELOCK = 3'd4, SETTLE = 3'd5;

    reg [2:0]  state = IDLE;
    reg [15:0] cnt;
    reg        mvs_cur = 1'b0;              // mode the PLL is configured for (AES at power-up)
    reg [1:0]  mvs_sync = 2'b00, lock_sync = 2'b00;

    always @(posedge clk_74a) begin
        mvs_sync  <= {mvs_sync[0], mvs};
        lock_sync <= {lock_sync[0], locked};

        if (rst) begin
            state         <= IDLE;
            mgmt_write    <= 1'b0;
            reconfiguring <= 1'b0;
            mvs_cur       <= 1'b0;
        end else case (state)
            IDLE: if (mvs_sync[1] != mvs_cur) begin
                mvs_cur        <= mvs_sync[1];
                reconfiguring  <= 1'b1;
                mgmt_address   <= REG_K;
                mgmt_writedata <= mvs_sync[1] ? K_MVS : K_AES;
                mgmt_write     <= 1'b1;
                state          <= WRITE_K;
            end

            // A write is accepted on the clock edge where write && !waitrequest.
            WRITE_K: if (!mgmt_waitrequest) begin
                mgmt_address   <= REG_START;
                mgmt_writedata <= 32'd0;
                state          <= WRITE_START;
            end

            WRITE_START: if (!mgmt_waitrequest) begin
                mgmt_write <= 1'b0;
                cnt        <= 16'd0;
                state      <= WAIT_UNLOCK;
            end

            // The slave's waitrequest can fall before 'locked' drops, so look at lock itself.
            WAIT_UNLOCK: begin
                cnt <= cnt + 16'd1;
                if (!lock_sync[1] || cnt == UNLOCK_TIMEOUT - 1) state <= WAIT_RELOCK;
            end

            WAIT_RELOCK: if (lock_sync[1] && !mgmt_waitrequest) begin
                cnt   <= 16'd0;
                state <= SETTLE;
            end

            SETTLE: begin
                cnt <= cnt + 16'd1;
                if (cnt == SETTLE_CYCLES - 1) begin
                    reconfiguring <= 1'b0;
                    state         <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase
    end
endmodule
