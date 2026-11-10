// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The command sequence follows Analogue's target command documentation and core_bridge_cmd.v; the shape
// of one owner for the target commands, the bank at bridge 0x7000_{slot}000 and the parameter struct
// layout were read in neutralinsomniac's openfpga-megacd as a design reference, no code copied.

// The one owner of the APF target commands in the CD build: data-slot read, getfile and openfile for
// cd_mount and cd_fetch, and the wait counter's slot write. One command in flight at a time. The host's
// data lands in the sector bank, and the parameter and response structs live here too.
//
// Clients:
//   mount (clk_74a)   mr_req is a level held until mr_done; mr_done stays high until mr_req falls, so a
//                     request is never taken twice. mr_err is the command's target_dataslot_err.
//   fetch (CLK_48M)   fr_req toggles, one request outstanding; fr_done takes the value fr_req had when the
//                     request was taken, once the read is over, and fr_err is set before. fr_slot, fr_offset and fr_bank_slot are held from the toggle to fr_done.
//   wait (clk_74a)    ws_req is the wait counter's save_now: each rising edge asks for one write of slot
//                     0x103, offset 0, from 0x8000_0000, 4,096 bytes; ws_done pulses at its end, with ws_err.
// Order when idle: the fetch, unless a mount openfile is also pending (an openfile goes first and is never
// split from the reads that follow it); then the mount; then the slot write. A done with err != 0 is passed
// on and nothing else: the clients never mark a bank slot valid from it.
//
// Command handshake with core_bridge_cmd.v (:474-563): the command line's rising edge queues the command;
// done falls when it starts (TARG_ST_DATASLOTOP) and rises with err when the host answers. The line falls
// once done has fallen. done is high between commands, so "low, then high" is this command's answer.
// core_bridge_cmd has no reset: rst must not rise with a command in flight (core_top.v ties it low).
//
// Sector bank: 4 slots x 588 words in one M10K RAM of 2,352 words, linear: slot s word w is s * 588 + w,
// which is what bank_rd_addr and bank_rd_addr_74 take. The host writes slot s at bridge 0x7000_s000 + 4w,
// a word {b0, b1, b2, b3} as the bridge carries it (bridge_endian_little = 0). Port A (clk_74a) takes the
// host's writes and cd_mount's reads, a write first: bank_rd_q_74 is the word of bank_rd_addr_74 one clock
// later, except after a clock that wrote, and the host writes the bank only during a read command, when
// cd_mount waits. Port B reads at CLK_48M, one clock of latency.
//
// Path buffer, two MLAB RAMs of 128 words behind one port: path_addr[7] = 0 is the parameter struct at
// 0x7100_0000 (path 256 bytes, flags at 0x100, size at 0x104), written by cd_mount through path_wr and read
// by the host through the bridge; path_addr[7] = 1 is the response struct at 0x7100_0400, written by the
// host and read by cd_mount on path_q, one clock of latency. cd_mount writes all 66 words of the parameter
// struct before an openfile, so nothing of an earlier path is left. 0x7100_xxxx writes reach apf_loader's
// save path too (0x6 and 0x7), harmless in the CD build, which has no backup RAM; 0x70 and 0x71 are no slot.
// The bridge reads 0x7100_0000-0x01FF here, loaded on the strobe like core_bridge_cmd.v (bridge_bfm.sv: the host
// allows for a one-read lag); core_top.v muxes 0x71 to this module.
//
// Clock crossings: fr_req, CLK_48M to clk_74a, two flops; fr_slot, fr_offset, fr_bank_slot are sampled
// after it and held by the client. fr_done, clk_74a to CLK_48M, two flops; fr_err is set a clock before
// fr_done toggles and held until the next request. bank port B is a dual-clock RAM read.
module cd_host (
    input             clk_74a,
    input             CLK_48M,
    input             rst,
    // APF, clk_74a
    output reg        target_dataslot_read = 0,
    output reg        target_dataslot_getfile = 0,
    output reg        target_dataslot_openfile = 0,
    output reg        target_dataslot_write = 0,
    input             target_dataslot_ack,
    input             target_dataslot_done,
    input       [2:0] target_dataslot_err,
    output reg [15:0] target_dataslot_id = 0,
    output reg [31:0] target_dataslot_slotoffset = 0,
    output reg [31:0] target_dataslot_bridgeaddr = 0,
    output reg [31:0] target_dataslot_length = 0,
    output     [31:0] target_buffer_param_struct,
    output     [31:0] target_buffer_resp_struct,
    input      [31:0] bridge_addr,
    input             bridge_wr,
    input      [31:0] bridge_wr_data,
    input             bridge_rd,
    output reg [31:0] bridge_rd_data = 0,
    // mount client, clk_74a
    input             mr_req,
    input       [1:0] mr_kind,          // 0 read, 1 getfile, 2 openfile
    input      [15:0] mr_slot,
    input      [31:0] mr_offset,
    input      [31:0] mr_len,
    input       [1:0] mr_bank_slot,
    output reg        mr_done = 0,
    output reg  [2:0] mr_err = 0,
    // apf_loader's save on Reset Core owns the host's commands while rs_hold, from the first clock rs_free is seen with it
    input             rs_hold,
    output            rs_free,
    // fetch client, CLK_48M
    input             fr_req,
    input      [15:0] fr_slot,
    input      [31:0] fr_offset,
    input       [1:0] fr_bank_slot,
    output            fr_done,
    output            fr_err,
`ifdef NEOGEO_WAIT_COUNTER
    // the wait counter's slot write, clk_74a
    input             ws_req,
    output reg        ws_done = 0,
    output reg  [2:0] ws_err = 0,
`endif
    // sector bank
    input      [11:0] bank_rd_addr,     // CLK_48M
    output reg [31:0] bank_rd_q,
    input      [11:0] bank_rd_addr_74,  // clk_74a
    output reg [31:0] bank_rd_q_74,
    // path buffer, clk_74a
    input       [7:0] path_addr,
    input             path_wr,
    input      [31:0] path_wdata,
    output reg [31:0] path_q
);

localparam int SECTOR = 2352;
localparam int WORDS  = SECTOR / 4;

localparam logic [31:0] PARAM_STRUCT = 32'h7100_0000;
localparam logic [31:0] RESP_STRUCT  = 32'h7100_0400;
assign target_buffer_param_struct = PARAM_STRUCT;
assign target_buffer_resp_struct  = RESP_STRUCT;

// ---- Fetch client crossing ----
reg  [1:0] fr_req_s = 0;
reg        fr_done_74 = 0, fr_err_74 = 0, fr_taken = 0;
reg  [1:0] fr_done_s = 0;
always @(posedge clk_74a) fr_req_s <= {fr_req_s[0], fr_req};
always @(posedge CLK_48M) fr_done_s <= {fr_done_s[0], fr_done_74};
assign fr_done = fr_done_s[1];
assign fr_err  = fr_err_74;
wire fr_pending = fr_req_s[1] != fr_done_74;

`ifdef NEOGEO_WAIT_COUNTER
reg ws_req_d = 0, ws_pending = 0;
`else
wire ws_pending = 0;
`endif

// ---- Commands ----
typedef enum logic [2:0] { S_IDLE, S_ISSUE, S_WAIT_LOW, S_WAIT_DONE, S_FETCH_DONE } state_t;
typedef enum logic [1:0] { C_FETCH, C_MOUNT, C_WAIT } client_t;
localparam logic [1:0] K_READ = 0, K_GETFILE = 1, K_OPENFILE = 2, K_WRITE = 3;

state_t     state = S_IDLE;
client_t    client = C_FETCH;
reg   [1:0] kind = K_READ;

wire mount_pending = mr_req && !mr_done;
wire mount_open    = mount_pending && mr_kind == K_OPENFILE;

assign rs_free = state == S_IDLE;

function automatic [11:0] slot_base(input [1:0] slot);     // slot * 588
    case (slot)
        2'd0: return 12'd0;
        2'd1: return 12'd588;
        2'd2: return 12'd1176;
        default: return 12'd1764;
    endcase
endfunction

function automatic [31:0] bank_bridge(input [1:0] slot);
    return 32'h7000_0000 | {18'd0, slot, 12'd0};
endfunction

always @(posedge clk_74a) begin
`ifdef NEOGEO_WAIT_COUNTER
    ws_done  <= 0;
    ws_req_d <= ws_req;
    if (ws_req && !ws_req_d) ws_pending <= 1;
`endif
    if (!mr_req) mr_done <= 0;

    case (state)
        S_IDLE:
            if (rs_hold) state <= S_IDLE;
            else if (fr_pending && !mount_open) begin
                fr_taken                   <= fr_req_s[1];     // the done answers this request, not a later toggle
                client                     <= C_FETCH;
                kind                       <= K_READ;
                target_dataslot_id         <= fr_slot;
                target_dataslot_slotoffset <= fr_offset;
                target_dataslot_bridgeaddr <= bank_bridge(fr_bank_slot);
                target_dataslot_length     <= SECTOR;
                state                      <= S_ISSUE;
            end
            else if (mount_pending) begin
                client                     <= C_MOUNT;
                kind                       <= mr_kind == 2'd3 ? K_READ : mr_kind;
                target_dataslot_id         <= mr_slot;
                target_dataslot_slotoffset <= mr_offset;
                target_dataslot_bridgeaddr <= bank_bridge(mr_bank_slot);
                target_dataslot_length     <= mr_len;
                state                      <= S_ISSUE;
            end
`ifdef NEOGEO_WAIT_COUNTER
            else if (ws_pending) begin
                ws_pending                 <= 0;
                client                     <= C_WAIT;
                kind                       <= K_WRITE;
                target_dataslot_id         <= 16'h0103;
                target_dataslot_slotoffset <= 0;
                target_dataslot_bridgeaddr <= 32'h8000_0000;
                target_dataslot_length     <= 32'd8192;    // wait_counter.sv, layout 3: its 8 records and its timelines
                state                      <= S_ISSUE;
            end
`endif

        // The parameters are on the ports since the last clock; now the rising edge
        S_ISSUE: begin
            target_dataslot_read     <= kind == K_READ;
            target_dataslot_getfile  <= kind == K_GETFILE;
            target_dataslot_openfile <= kind == K_OPENFILE;
            target_dataslot_write    <= kind == K_WRITE;
            state                    <= S_WAIT_LOW;
        end

        S_WAIT_LOW:
            if (!target_dataslot_done) begin
                {target_dataslot_read, target_dataslot_getfile, target_dataslot_openfile, target_dataslot_write} <= 0;
                state <= S_WAIT_DONE;
            end

        S_WAIT_DONE:
            if (target_dataslot_done) begin
                state <= S_IDLE;
                case (client)
                    C_FETCH: begin
                        fr_err_74 <= target_dataslot_err != 0;
                        state     <= S_FETCH_DONE;
                    end
                    C_MOUNT: begin
                        mr_err  <= target_dataslot_err;
                        mr_done <= 1;
                    end
                    default: begin
`ifdef NEOGEO_WAIT_COUNTER
                        ws_err  <= target_dataslot_err;
                        ws_done <= 1;
`endif
                    end
                endcase
            end

        // fr_err has settled: now the toggle
        S_FETCH_DONE: begin
            fr_done_74 <= fr_taken;
            state      <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase

    if (rst) begin
        state <= S_IDLE;
        {target_dataslot_read, target_dataslot_getfile, target_dataslot_openfile, target_dataslot_write} <= 0;
        mr_done    <= 0;
`ifdef NEOGEO_WAIT_COUNTER
        ws_pending <= 0;
`endif
    end
end

// ---- Bridge writes, clk_74a: registered, then the bank's linear address ----
reg        b_wr = 0;
reg [31:0] b_addr = 0, b_data = 0;
reg        bank_we = 0;
reg [11:0] bank_wa = 0;
reg [31:0] bank_wd = 0;

wire [9:0] b_word = b_addr[11:2];
wire [1:0] b_slot = b_addr[13:12];

always @(posedge clk_74a) begin
    b_wr    <= bridge_wr;
    b_addr  <= bridge_addr;
    b_data  <= bridge_wr_data;
    bank_we <= b_wr && b_addr[31:14] == 18'h1_C000 && b_word < 10'(WORDS);   // 0x7000_0000-0x7000_3FFF
    bank_wa <= slot_base(b_slot) + 12'(b_word);
    bank_wd <= b_data;
end

// ---- Sector bank ----
(* ramstyle = "M10K, no_rw_check" *) reg [31:0] bank [0:4 * WORDS - 1];

// One address on this port: with two, a write's and a read's, Quartus makes two RAMs, 20 M10K for 10
wire [11:0] bank_a = bank_we ? bank_wa : bank_rd_addr_74;

always @(posedge clk_74a) begin
    if (bank_we) bank[bank_a] <= bank_wd;
    else bank_rd_q_74 <= bank[bank_a];
end

always @(posedge CLK_48M) bank_rd_q <= bank[bank_rd_addr];

// ---- Parameter and response structs ----
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] param [0:127];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] resp  [0:127];

wire resp_we = b_wr && b_addr[31:9] == RESP_STRUCT[31:9];      // 0x7100_0400-0x7100_05FF
reg [31:0] param_q = 0;

always @(posedge clk_74a) begin
    if (path_wr && !path_addr[7]) param[path_addr[6:0]] <= path_wdata;
    param_q <= param[bridge_addr[8:2]];        // the address is on the bus 4 clocks before the host samples
    if (resp_we) resp[b_addr[8:2]] <= b_data;
    path_q <= resp[path_addr[6:0]];
    // Loaded on the strobe, as core_bridge_cmd.v and every target here: the host allows for that lag
    if (bridge_rd) bridge_rd_data <= bridge_addr[31:9] == PARAM_STRUCT[31:9] ? param_q : 32'd0;
end

endmodule
