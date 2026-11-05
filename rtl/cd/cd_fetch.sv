// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The sector streamer, at CLK_48M: what MiSTer's ARM does when megacdd sends a sector. cdd_drive asks for a
// sector of a file (req_file, req_file_lba) with a toggle of req_valid; this finds it in cd_host's bank of 4
// sectors or reads it there from the host (fr_*, slot 2 for file 0, the picked file, else slot 3), streams
// it to cd_sys as MiSTer's HPS does, and toggles req_done. Then it prefetches the next three sectors of the
// same file into the other slots, one host read at a time, while no request waits.
//
// A slot's tag is {valid, file, file_lba}: by file position, not disc LBA, since with the PREGAP keyword a
// disc LBA has no BIN sector. A slot being read from the host has its new tag and valid low; it becomes
// valid only if the read answers err 0 and the disc did not go meanwhile. The slot for a new sector is one
// outside the window of the sector asked for and its next three (any slot outside that window is of no use
// to a sequential read, so this is the least recently useful one).
//
// The stream: 1,176 words {byte 2i+1, byte 2i} from the bank's words {b0, b1, b2, b3} (word 2k is
// {q[23:16], q[31:24]}, word 2k+1 {q[7:0], q[15:8]}), cd_dl_addr 0..1175, a one-clock cd_dl_wr per
// WORD_CLKS, data and address held from that pulse to the next. neogeo_pocket.sv stretches cd_dl_wr to 16
// clocks (ioctl_wr_x), and cd_sys takes the header words 6 and 7 at its falling edge, 18 clocks after the
// pulse: WORD_CLKS 20 is the least that keeps a word still that long, not a knob. cd_dl_download is high
// from before the first word until WORD_CLKS after the last word's window, low between sectors; cd_dl_audio
// picks cdda.v (CDDA_WR_READY) over the LC8951 (CD_DATA_WR_READY), and a stream waits for its sink's ready.
//
// Errors: a host read that answers err != 0, or a disc gone while it ran, leaves the slot invalid, sets
// fetch_err and toggles req_done with nothing streamed: the drive moves on and the sector is simply not
// delivered (spec 9). So does a position below the disc (req_file_lba[23], cdd_drive's two's complement)
// and a request with no disc, without a host read. fetch_err is cleared by the next request.
//
// Contracts with cdd_drive (Task 5): under nRESET a stream is abandoned and req_done never moves, during or
// after; req_done is only ever inverted, never loaded from req_valid, as cdd_drive loads req_valid from
// req_done in its reset. A host read in flight at nRESET is seen through: the toggle with cd_host stays in
// step. A request in flight at a seek is not cancelled: cdd_drive asks for the next only after req_done.
// disc_present (CLK_48M, the one view neogeo_pocket.sv takes of cd_mount's and gives cdd_drive too) low empties the
// bank, and a stream not begun does not begin. fr_offset's multiply by 2,352 is shift-adds over two clocks.
module cd_fetch #(
    parameter int WORD_CLKS = 20            // CLK_48M per streamed word: ioctl_wr_x is 16 wide
) (
    input             CLK_48M,
    input             nRESET,
    input             disc_present,
    // cdd_drive
    input      [23:0] req_lba,
    input             req_audio,
    input       [6:0] req_file,
    input      [23:0] req_file_lba,
    input             req_valid,
    output reg        req_done = 0,
    // cd_host's fetch client and bank port B
    output reg        fr_req = 0,
    output reg [15:0] fr_slot = 0,
    output reg [31:0] fr_offset = 0,
    output reg  [1:0] fr_bank_slot = 0,
    input             fr_done,
    input             fr_err,
    output reg [11:0] bank_rd_addr = 0,
    input      [31:0] bank_rd_q,
    // to cd_sys, through neogeo_pocket.sv's glue
    output reg        cd_dl_download = 0,
    output reg        cd_dl_audio = 0,
    output reg        cd_dl_wr = 0,
    output reg [11:1] cd_dl_addr = 0,
    output reg [15:0] cd_dl_data = 0,
    input             cd_data_ready,
    input             cdda_ready,
`ifdef NEOGEO_WAIT_COUNTER
    input             dbg_poll,         // the drive's poll with PLAY and no latency left: it would send a sector now
    output    [319:0] dbg_fetch,        // wait_counter.sv, words in the order of the assign at the end
`endif
    output reg        fetch_err = 0     // the last request could not be read; cleared by the next request
);

localparam int WORDS  = 588;
localparam int STREAM = 2 * WORDS;

typedef enum logic [3:0] {
    S_IDLE, S_LOOK, S_DECIDE, S_OFF1, S_OFF2, S_OFF3, S_WAIT_F, S_SINK, S_STREAM, S_TAIL, S_DONE, S_PF_LOOK, S_PF_DECIDE
} state_t;

state_t state = S_IDLE;

// ---- The bank's tags ----
reg  [3:0] valid = 0;
reg  [6:0] tag_file [0:3];
reg [23:0] tag_lba  [0:3];
initial for (int n = 0; n < 4; n++) begin
    tag_file[n] = 0;
    tag_lba[n]  = 0;
end

// ---- The host read in flight ----
reg        fbusy = 0, fabandon = 0, pf_issue = 0, stale = 0;
reg  [1:0] fslot = 0;
reg  [6:0] ffile = 0;
reg [23:0] flba = 0;
reg        f_err = 0, f_lost = 0;   // how the last read ended: err != 0, or the disc went meanwhile
reg [31:0] off_a = 0, off_b = 0;

// ---- The request being served, and the prefetch after it ----
reg  [6:0] cur_file = 0;
reg [23:0] cur_lba = 0;
reg        cur_audio = 0;
reg  [1:0] cur_slot = 0;
reg  [6:0] pf_file = 0;
reg [23:0] pf_base = 0;
reg  [1:0] pf_left = 0, pf_n = 0;

// Lookups, registered: hit for (look_file, look_lba), useful for the window (look_file, look_base .. + 3)
reg  [6:0] look_file = 0;
reg [23:0] look_lba = 0, look_base = 0;
reg  [3:0] hit = 0, useful = 0;

// ---- Stream ----
reg [10:0] j = 0;
reg  [7:0] t = 0;
reg [31:0] q_hold = 0;

function automatic [11:0] slot_base(input [1:0] s);     // s * 588
    case (s)
        2'd0: return 12'd0;
        2'd1: return 12'd588;
        2'd2: return 12'd1176;
        default: return 12'd1764;
    endcase
endfunction

function automatic [1:0] first(input [3:0] v);
    return v[0] ? 2'd0 : v[1] ? 2'd1 : v[2] ? 2'd2 : 2'd3;
endfunction

wire disc_ok = disc_present;

wire req_pending = req_valid != req_done;
wire [3:0] spare = ~useful;          // slots outside the window

always @(posedge CLK_48M) begin
    cd_dl_wr <= 0;

    // Lookups, every clock, on whatever look_* holds
    for (int n = 0; n < 4; n++) begin
        hit[n]    <= valid[n] && tag_file[n] == look_file && tag_lba[n] == look_lba;
        useful[n] <= valid[n] && tag_file[n] == look_file && tag_lba[n] - look_base < 24'd4;
    end

    // A host read ends
    if (fbusy && fr_done == fr_req) begin
        fbusy  <= 0;
        f_err  <= fr_err;
        f_lost <= fabandon || !disc_ok;
        if (!fr_err && !fabandon && disc_ok) valid[fslot] <= 1;
    end

    if (!nRESET) begin
        // Abandon the stream; req_done stays as it is. A read in flight is still seen through above
        cd_dl_download <= 0;
        pf_left        <= 0;
        state          <= S_IDLE;
    end
    else case (state)
        S_IDLE:
            if (req_pending) begin
                cur_file  <= req_file;
                cur_lba   <= req_file_lba;
                cur_audio <= req_audio;
                look_file <= req_file;
                look_lba  <= req_file_lba;
                look_base <= req_file_lba;
                fetch_err <= 0;
                pf_left   <= 0;
                state     <= S_LOOK;
            end
            else if (pf_left != 0 && !fbusy) begin
                look_file <= pf_file;
                look_lba  <= pf_base + 24'(pf_n);
                look_base <= pf_base;
                state     <= S_PF_LOOK;
            end

        // hit and useful take this clock
        // A read that ended meanwhile may have changed the answer: look again
        S_LOOK: begin
            stale <= 0;
            state <= S_DECIDE;
        end

        S_DECIDE:
            if (stale) state <= S_LOOK;
            else if (cur_lba[23] || !disc_ok) begin
                fetch_err <= 1;             // below the disc, or no disc: no read
                state     <= S_DONE;
            end
            else if (hit != 0) begin
                cur_slot <= first(hit);
                state    <= S_SINK;
            end
            else if (fbusy) state <= S_WAIT_F;  // a prefetch first; then look again
            else begin
                fslot    <= first(spare);
                ffile    <= cur_file;
                flba     <= cur_lba;
                pf_issue <= 0;
                state    <= S_OFF1;
            end

        // ---- A host read of (ffile, flba) into fslot ----
        S_OFF1: begin
            valid[fslot]    <= 0;
            tag_file[fslot] <= ffile;
            tag_lba[fslot]  <= flba;
            off_a           <= (32'(flba) << 11) + (32'(flba) << 8);
            off_b           <= (32'(flba) << 5) + (32'(flba) << 4);
            state           <= S_OFF2;
        end

        S_OFF2: begin
            fr_offset    <= off_a + off_b;          // flba * 2352
            fr_slot      <= ffile == 0 ? 16'd2 : 16'd3;
            fr_bank_slot <= fslot;
            state        <= S_OFF3;
        end

        // The toggle, a clock after its parameters, which stay until fr_done
        S_OFF3: begin
            fr_req   <= ~fr_req;
            fbusy    <= 1;
            fabandon <= 0;
            state    <= pf_issue ? S_IDLE : S_WAIT_F;
        end

        S_WAIT_F:
            if (!fbusy) begin
                if (ffile == cur_file && flba == cur_lba && (f_err || f_lost)) begin
                    fetch_err <= 1;
                    state     <= S_DONE;
                end
                else state <= S_LOOK;               // hit now, or the read was another sector's
            end

        // ---- Stream ----
        S_SINK:
            if (!disc_ok) begin
                fetch_err <= 1;             // the bank is cd_mount's now
                state     <= S_DONE;
            end
            else if (cur_audio ? cdda_ready : cd_data_ready) begin
                j              <= 0;
                t              <= 0;
                cd_dl_download <= 1;
                cd_dl_audio    <= cur_audio;
                state          <= S_STREAM;
            end

        S_STREAM: begin
            t <= t + 1'd1;
            case (t)
                8'd0: bank_rd_addr <= slot_base(cur_slot) + 12'(j >> 1);
                8'd2: q_hold <= bank_rd_q;
                8'd3: begin
                    cd_dl_data <= j[0] ? {q_hold[7:0], q_hold[15:8]} : {q_hold[23:16], q_hold[31:24]};
                    cd_dl_addr <= j;
                    cd_dl_wr   <= 1;
                end
                default: ;
            endcase
            if (t == 8'(WORD_CLKS - 1)) begin
                t <= 0;
                if (j == 11'(STREAM - 1)) state <= S_TAIL;
                else j <= j + 1'd1;
            end
        end

        // The last word's falling edge reaches cd_sys 18 clocks after its pulse: hold the download past it
        S_TAIL: begin
            t <= t + 1'd1;
            if (t == 8'(WORD_CLKS - 1)) begin
                cd_dl_download <= 0;
                pf_file        <= cur_file;
                pf_base        <= cur_lba;
                pf_n           <= 1;
                pf_left        <= 3;
                state          <= S_DONE;
            end
        end

        S_DONE: begin
            req_done <= ~req_done;
            state    <= S_IDLE;
        end

        // ---- Prefetch of pf_base + pf_n ----
        S_PF_LOOK: state <= S_PF_DECIDE;

        S_PF_DECIDE: begin
            pf_n    <= pf_n + 1'd1;
            pf_left <= pf_left - 1'd1;
            state   <= S_IDLE;
            if (req_pending || !disc_ok) pf_left <= 0;
            else if (hit == 0 && spare != 0) begin
                fslot    <= first(spare);
                ffile    <= look_file;
                flba     <= look_lba;
                pf_issue <= 1;
                state    <= S_OFF1;
            end
        end

        default: state <= S_IDLE;
    endcase

    if (fbusy && fr_done == fr_req) stale <= 1;

    // No disc: the bank is empty, and a read in flight will not fill it
    if (!disc_ok) begin
        valid   <= 0;
        pf_left <= 0;
        if (fbusy) fabandon <= 1;
    end
end

`ifdef NEOGEO_WAIT_COUNTER
// What tells if a CD Speed outruns the host or the data path, for wait_counter.sv's file. It only watches.
// cdd_drive asks for a sector only when the last is done and the sink has room, and otherwise its poll passes:
// no sector is ever skipped, the position just moves later. So a poll that finds the last request unanswered is
// the "late" count, and a request can arrive on a busy fetch only with a prefetch still under way.
// Dropped: a failed read (fetch_err, counted in the counter) and a stream abandoned by nRESET.
reg [23:0] n_data = 0, n_audio = 0, n_hit = 0, n_miss = 0, n_late = 0, n_sink_poll = 0;
reg [15:0] n_busy = 0, n_sink_wait = 0, n_abandon = 0;
reg [25:0] f_clks = 0, f_worst = 0;         // CLK_48M, stops at 1.39 s
reg        first_look = 0, valid_d = 0, sink_seen = 0;

always @(posedge CLK_48M) begin
    valid_d <= req_valid;
    if (nRESET && req_valid != valid_d && req_pending && (fbusy || state != S_IDLE)) n_busy <= n_busy + 1'd1;

    if (nRESET && state == S_IDLE && req_pending) begin
        if (req_audio) n_audio <= n_audio + 1'd1;
        else           n_data  <= n_data + 1'd1;
        first_look <= 1;
    end
    // The request's first answer: later looks are the same request after its read
    if (state == S_DECIDE && !stale && first_look) begin
        first_look <= 0;
        if (!cur_lba[23] && disc_ok) begin
            if (hit != 0) n_hit  <= n_hit + 1'd1;
            else          n_miss <= n_miss + 1'd1;
        end
    end

    if (fbusy) begin
        if (!(&f_clks)) f_clks <= f_clks + 1'd1;
        if (f_clks > f_worst) f_worst <= f_clks;
    end
    else f_clks <= 0;

    if (dbg_poll && req_pending) n_late <= n_late + 1'd1;
    if (dbg_poll && !req_pending && !(req_audio ? cdda_ready : cd_data_ready)) n_sink_poll <= n_sink_poll + 1'd1;

    // A request on its way, with the sink full after the drive looked
    if (state != S_SINK) sink_seen <= 0;
    else if (disc_ok && !(cur_audio ? cdda_ready : cd_data_ready) && !sink_seen) begin
        sink_seen   <= 1;
        n_sink_wait <= n_sink_wait + 1'd1;
    end

    if (!nRESET && (state == S_SINK || state == S_STREAM || state == S_TAIL)) n_abandon <= n_abandon + 1'd1;
end

assign dbg_fetch = {32'(n_data), 32'(n_audio), 32'(n_hit), 32'(n_miss), 32'(f_worst), 32'(n_busy), 32'(n_late),
                    32'(n_sink_poll), 32'(n_sink_wait), 32'(n_abandon)};
`endif

endmodule
