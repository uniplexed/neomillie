//
// sdram_ctrl.sv
//
// SDRAM controller for the Analogue Pocket (single 64 MB x16 chip, no chip select pin).
// Port of sdram.sv from NeoGeo_MiSTer.
//
// Static RAM controller implementation using SDRAM MT48LC16M16A2
//
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//
// furrtek 2019-01-24 : Added ugly burst reading
// Sorgelig 2019-08   : rework, support mem copy and larger chips.
// Pocket port        : single chip, memory copy FSM and chip select logic removed,
//                      Pocket pin names, timing parameters in clocks for the
//                      AS4C32M16MSA-6BIN (CL3, tRFC, read precharge, extended mode
//                      register at startup). The combined
//                      work is distributed under GPL-3.
//
// Interface semantics are those of the MiSTer controller:
// - A request is a level on rd or wr, sampled in the idle state. 'ready' falls when the
//   request is accepted; the master drops rd/wr on that falling edge.
// - Write: single word, 'ready' rises again when the write command was issued.
// - Read: burst of 4 words starting at addr (sequential, aligned to 4 words by the caller).
//   When 'ready' rises, 'dout' holds word 0 and words 1..3 follow on the next three clocks.
// - 'refresh' is a toggle: every edge issues one auto refresh.
// - Every access ends with auto precharge, so all banks are closed whenever idle.

module sdram_ctrl #(
    // Defaults are for the AS4C32M16MSA-6BIN of the Pocket at 96.7 MHz (10.34 ns clock).
    // Chip limits in ns -> clocks: tRCD 18 -> 2, tRP 18 -> 2, tRAS 48 -> 5, tRC 60 -> 6,
    // tRFC 80 -> 8, tWR 2 clocks, tMRD 2 clocks.
    parameter CAS   = 3,    // CAS latency in clocks; CL=2 is only allowed up to 83 MHz
    parameter T_RCD = 2,    // ACTIVE to READ/WRITE, clocks (>= 2)
    parameter T_RP  = 2,    // PRECHARGE to ACTIVE, clocks
    parameter T_RAS = 5,    // ACTIVE to start of precharge, clocks
    parameter T_WR  = 2,    // last write data to start of precharge, clocks
    parameter T_RFC = 8,    // AUTO REFRESH to next command, clocks (>= 2); also the startup step
    // Extended mode register, programmed once at startup: A7:A5 = 010 is 25% output drive
    // (the value used on real Pockets), A2:A0 = 000 is full-array self refresh.
    parameter [12:0] EMR = 13'b0_0000_0100_0000
) (
    input  wire        init,        // reset to initialize RAM
    input  wire        clk,         // CLK_96M

    // SDRAM pins
    inout  wire [15:0] dram_dq,
    output reg  [12:0] dram_a,
    output wire  [1:0] dram_dqm,
    output reg   [1:0] dram_ba,
    output wire        dram_we_n,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_cke,
    output wire        dram_clk,

    input       [25:1] addr,        // word address
    output reg  [15:0] dout,        // data output
    input       [15:0] din,         // data input
    input        [1:0] bs,          // bit1 - write high byte, bit0 - write low byte, ignored while reading
    input              wr,          // request write
    input              rd,          // request read
    input              refresh,     // toggle: request one auto refresh
    output reg         ready
);

localparam BURST_LENGTH        = 4;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam [2:0] CAS_LATENCY   = CAS;
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

// Clocks from a READ/WRITE command to the start of the (auto) precharge; the bank must also
// have been active for T_RAS. The wait before the next command is the largest case plus T_RP,
// used for reads and writes alike so the idle timing does not depend on the access.
// A READ with auto precharge starts the precharge BURST_LENGTH clocks after the command: the
// chip keeps the last CL-1 outputs valid after a precharge, so this does not depend on CL.
localparam PRE_RD   = BURST_LENGTH;
localparam PRE_WR   = 1 + T_WR;
localparam PRE_RAS  = T_RAS - T_RCD;
localparam PRE_MAX  = (PRE_RD > PRE_WR) ? ((PRE_RD > PRE_RAS) ? PRE_RD : PRE_RAS) : ((PRE_WR > PRE_RAS) ? PRE_WR : PRE_RAS);
localparam GAP      = PRE_MAX + T_RP;      // READ/WRITE command to next ACTIVE, clocks (6 by default)

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
localparam [2:0] CMD_NOP          = 3'b111;
localparam [2:0] CMD_ACTIVE       = 3'b011;
localparam [2:0] CMD_READ         = 3'b101;
localparam [2:0] CMD_WRITE        = 3'b100;
localparam [2:0] CMD_PRECHARGE    = 3'b010;
localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
localparam [2:0] CMD_LOAD_MODE    = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command = CMD_NOP;
reg [15:0] dq_out;
reg        dq_oe = 0;

// The Pocket SDRAM has no chip select pin (tied low on the board).
assign dram_ras_n = command[2];
assign dram_cas_n = command[1];
assign dram_we_n  = command[0];
assign dram_cke   = 1;
assign dram_dqm   = dram_a[12:11];
assign dram_dq    = dq_oe ? dq_out : 16'bZ;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;   // ACTIVE to READ/WRITE delay
localparam STATE_RW      = 2;
localparam STATE_GAP     = 3;   // recovery after READ/WRITE/REFRESH
localparam STATE_IDLE    = 4;

initial begin
    ready = 0;
    dout  = 0;
end

always @(posedge clk) begin
    reg [CAS_LATENCY:0] data_ready_delay = 0;

    reg        saved_wr;
    reg [12:0] cas_addr;
    reg [15:0] saved_data;
    reg  [3:0] state = STATE_STARTUP;
    reg  [3:0] tcnt;
    reg        refresh_old = 0;

    refresh_count <= refresh_count+1'b1;

    data_ready_delay <= data_ready_delay>>1;
    if(data_ready_delay[0]) ready <= 1;

    dout  <= dram_dq;
    dq_oe <= 0;

    command <= CMD_NOP;
    case (state)
        STATE_STARTUP: begin
            //------------------------------------------------------------------------
            //-- This is the initial startup state, where we wait for at least 100us
            //-- before starting the start sequence
            //--
            //-- The initialisation is sequence is
            //--  * de-assert dram_cke
            //--  * 100us wait,
            //--  * assert dram_cke
            //--  * wait at least one cycle,
            //--  * PRECHARGE
            //--  * wait 2 cycles
            //--  * REFRESH,
            //--  * tRFC wait
            //--  * REFRESH,
            //--  * tRFC wait
            //--  * LOAD_MODE_REG
            //--  * 2 cycles wait
            //--  * LOAD_MODE_REG (extended)
            //--  * 2 cycles wait
            //------------------------------------------------------------------------
            dram_a      <= 0;
            dram_ba     <= 0;
            refresh_old <= refresh;

            // All the commands during the startup are NOPS, except these, T_RFC clocks apart
            // (that covers tRP, tRFC and tMRD)
            if (refresh_count == startup_refresh_max-(7*T_RFC-1)) begin
                // ensure all rows are closed
                command     <= CMD_PRECHARGE;
                dram_a[10]  <= 1;  // all banks
                dram_ba     <= 2'b00;
            end
            if (refresh_count == startup_refresh_max-(6*T_RFC-1) || refresh_count == startup_refresh_max-(5*T_RFC-1)) begin
                // these refreshes need to be at least tRFC apart
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-(4*T_RFC-1)) begin
                // Now load the mode register
                command     <= CMD_LOAD_MODE;
                dram_a      <= MODE;
            end
            if (refresh_count == startup_refresh_max-(3*T_RFC-1)) begin
                // and the extended mode register (BA1=1, BA0=0)
                command     <= CMD_LOAD_MODE;
                dram_ba     <= 2'b10;
                dram_a      <= EMR;
            end

            //------------------------------------------------------
            //-- if startup is complete then go into idle mode,
            //-- get prepared to accept a new command, and schedule
            //-- the first refresh cycle
            //------------------------------------------------------
            if (!refresh_count) begin
                state   <= STATE_IDLE;
                ready   <= 1;
                refresh_count <= 0;
            end
        end

        // Wait out the remaining recovery time (tcnt holds the clocks left minus one)
        STATE_GAP: begin
            tcnt <= tcnt - 1'd1;
            if (!tcnt) state <= STATE_IDLE;
        end

        STATE_IDLE: begin
            if (refresh ^ refresh_old) begin
                state      <= STATE_GAP;
                tcnt       <= T_RFC - 2;
                command    <= CMD_AUTO_REFRESH;
                refresh_old<= refresh;
            end
            else if (rd | wr) begin
                {cas_addr[12:9],dram_ba,dram_a,cas_addr[8:0]} <= {~wr ? 2'b00 : ~bs, 1'b1, addr[25:1]};
                saved_data <= din;
                saved_wr   <= wr;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
                tcnt       <= T_RCD - 2;
                ready      <= 0;
            end
        end

        STATE_WAIT: begin
            tcnt <= tcnt - 1'd1;
            if (!tcnt) state <= STATE_RW;
        end

        STATE_RW: begin
            state         <= STATE_GAP;
            tcnt          <= GAP - 2;
            dram_a        <= cas_addr;
            if(saved_wr) begin
                command    <= CMD_WRITE;
                dq_out     <= saved_data;
                dq_oe      <= 1;
                ready      <= 1;
            end
            else begin
                command    <= CMD_READ;
                data_ready_delay[CAS_LATENCY] <= 1;
            end
        end
    endcase

    if (init) begin
        state         <= STATE_STARTUP;
        refresh_count <= startup_refresh_max - sdram_startup_cycles;
    end
end

altddio_out
#(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
)
sdramclk_ddr
(
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk),
    .dataout(dram_clk),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

endmodule
