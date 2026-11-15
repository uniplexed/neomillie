// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The Turbo path's sector streamer, at CLK_48M: cd_fetch's job, from a ring of 16 chunks of 16 sectors in SDRAM (word
// 0x0200000, 602,112 bytes) instead of the 6-sector bank, so that one host command brings 16 sectors. cdd_drive asks for
// a sector of a file (req_file, req_file_lba) with a toggle of req_valid; this streams it from the ring to cd_sys as
// cd_fetch does and toggles req_done.
//
// Chunks: a tag each, {valid, pending, file, flba0}, flba0 the file position of its first sector. After a flush the
// chunks hold ring_lba, ring_lba + 16, ... in order, chunk k sector s at ring_lba + 16k + s (+ 256m once the ring has
// wrapped), so a request has one candidate chunk, d[7:4] for d = lba - ring_lba, and its tag says whether it is there.
// A request inside a valid chunk streams from word 0x0200000 + chunk * 18816 + (lba - flba0) * 1176; inside the pending
// chunk it waits for its read; anywhere else every tag drops (a flush) and chunk 0 is read from the requested sector.
// A position below the disc, a position at or past file_bytes, or no disc: fetch_err with no read.
//
// Filling: while no request waits and no read is in flight, the chunk after the newest (head + 1) is read with the next
// 16 sectors if it is free, once every sector of it is more than FREE sectors behind the last request (so the BIOS's
// retry after a header mismatch, a short step back, still hits), and if those sectors start before file_bytes. A read
// asks min(37,632, file_bytes - offset) bytes from slot 2 for file 0, the picked file, else slot 3, at bridge
// 0x7400_0000 + chunk * 37,632, which cd_ring_wr turns into the chunk's SDRAM words. A read that fails stops the
// filling; the next request outside a valid chunk flushes and starts again.
//
// Read-after-write contract with pocket_mem_mux: the mux does not order the ring's reads after its writes. A chunk is
// streamed only once its host read has completed (fr_done with fr_err 0), when the bridge has carried its last word and
// cd_ring_wr's FIFO of 4 drains in well under a bridge word; a pending chunk is never read from SDRAM. The words that
// may still be in that FIFO at fr_done are the chunk's last, which a stream from the chunk reaches last.
//
// The stream: cd_dl_* exactly as cd_fetch drives them (1,176 words, a one-clock cd_dl_wr per WORD_CLKS 3 clocks into its
// slot, cd_dl_download from before the first word to WORD_CLKS after the last word's slot, cd_dl_audio by req_audio, the
// sink's ready waited for). The words come from SDRAM in bursts of 4 (rr_*, a toggle like fr_req) into 2 bursts of
// registers: bursts 0 and 1 before cd_dl_download rises, then burst b + 2 as soon as burst b's last word is out and
// burst b + 1 is in. So a burst asked for on time has 5 word slots less a few clocks, about 97 CLK_48M, to come back:
// about 194 CLK_96M from the mux seeing rr_req to rr_done. With one burst in flight at a time they must also average
// under 4 word slots, 80 CLK_48M, so one slow burst is covered when those around it are not (sim/mem: 59 CLK_96M at
// worst). If a burst is ever later, the word's slot waits for it, which only stretches the stream (cd_sys takes a word
// on the stretched pulse's falling edge), never sends a wrong word.
//
// Errors, disc loss and reset, as cd_fetch: a host read that answers err != 0, or a disc gone while it ran, leaves its
// chunk invalid; the request waiting for it gets fetch_err and req_done toggled with nothing streamed. fetch_err is
// cleared by the next request. Under nRESET a stream is abandoned and req_done never moves, during or after; req_done is
// only ever inverted. A host read or a burst in flight at nRESET is seen through, so both toggles stay in step.
// disc_present low drops every tag and stops the filling, and a stream not begun does not begin.
module cd_ring #(
    parameter int WORD_CLKS = 20            // CLK_48M per streamed word: ioctl_wr_x is 16 wide
) (
    input             CLK_48M,
    input             nRESET,
    input             disc_present,
    input      [31:0] file_bytes,       // the data file's size: no read past it
    // cdd_drive
    input      [23:0] req_lba,
    input             req_audio,
    input       [6:0] req_file,
    input      [23:0] req_file_lba,
    input             req_valid,
    output reg        req_done = 0,
    // cd_host's fetch client
    output reg        fr_req = 0,
    output reg [15:0] fr_slot = 0,
    output reg [31:0] fr_offset = 0,
    output reg [31:0] fr_bridge = 0,
    output reg [31:0] fr_len = 0,
    input             fr_done,
    input             fr_err,
    // pocket_mem_mux's ring read client
    output reg        rr_req = 0,
    output reg [24:0] rr_word = 0,
    input             rr_done,
    input      [63:0] rr_data,
    // to cd_sys, through neogeo_pocket.sv's glue
    output reg        cd_dl_download = 0,
    output reg        cd_dl_audio = 0,
    output reg        cd_dl_wr = 0,
    output reg [11:1] cd_dl_addr = 0,
    output reg [15:0] cd_dl_data = 0,
    input             cd_data_ready,
    input             cdda_ready,
`ifdef NEOGEO_WAIT_COUNTER
    output    [127:0] dbg_ring,         // wait_counter.sv, words in the order of the assign at the end
`endif
    output reg        fetch_err = 0     // the last request could not be read; cleared by the next request
);

localparam int    STREAM      = 1176;           // words of a sector
localparam int    BURSTS      = STREAM / 4;
localparam int    FREE        = 32;             // sectors kept behind the last request
localparam [31:0] CHUNK_BYTES = 32'd37632;
localparam [24:0] RING_WORD   = 25'h0200000;

typedef enum logic [3:0] {
    S_IDLE, S_MUL, S_LOOK, S_DECIDE, S_OFF1, S_OFF2, S_OFF3, S_WAIT_F, S_SINK, S_PRIME, S_STREAM, S_TAIL, S_DONE
} state_t;

state_t state = S_IDLE;

// ---- Tags ----
reg [15:0] valid = 0, pending = 0;
reg  [6:0] tag_file [0:15];
reg [23:0] tag_lba  [0:15];
initial for (int n = 0; n < 16; n++) begin
    tag_file[n] = 0;
    tag_lba[n]  = 0;
end
reg  [3:0] head = 0;                // the newest chunk
reg [23:0] ring_lba = 0;            // chunk 0's first sector at the last flush
reg [23:0] last_lba = 0;            // the last request
reg        fill_on = 0;
reg  [6:0] fill_file = 0;
reg [23:0] nxt_lba = 0;             // the next fill's first sector, and its byte offset
reg [31:0] nxt_off = 0;

// ---- The host read in flight ----
reg        fbusy = 0, fabandon = 0, ffill = 0, mine = 0, stale = 0;
reg  [3:0] fchunk = 0;
reg  [6:0] ffile = 0;
reg [23:0] flba = 0;
reg [31:0] foff = 0, rem = 0;
reg        f_err = 0, f_lost = 0;   // how the last read ended: err != 0, or the disc went meanwhile

// ---- The request ----
reg  [6:0] cur_file = 0;
reg [23:0] cur_lba = 0;
reg        cur_audio = 0;
reg [31:0] off_a = 0, off_b = 0, cur_off = 0;

// ---- Lookups, registered, every clock: the request's candidate chunk, and whether head + 1 is free ----
wire [24:0] d = {1'b0, cur_lba} - {1'b0, ring_lba};
wire  [3:0] dc = d[7:4];
wire        tag_ok = !d[24] && tag_file[dc] == cur_file && tag_lba[dc] == cur_lba - 24'(d[3:0]);
wire  [3:0] nc = head + 1'd1;
wire [24:0] behind = {1'b0, last_lba} - {1'b0, tag_lba[nc]};
reg         hv = 0, hp = 0, nc_free = 0;
reg   [7:0] hit_sector = 0;         // {chunk, sector in it}: the ring's sector

wire disc_ok     = disc_present;
wire req_pending = req_valid != req_done;
wire bad_pos     = cur_lba[23:20] != 0 || !disc_ok || cur_off >= file_bytes;  // [23] below the disc
wire fill_go     = fill_on && !fbusy && disc_ok && nc_free && nxt_off < file_bytes;

// ---- Stream ----
reg [10:0] j = 0, wl = 0;           // the word in its slot; words sent
reg  [7:0] t = 0;
reg  [8:0] rb = 0, got = 0;         // bursts asked for; bursts in
reg        rr_wait = 0;
reg [24:0] base = 0;
reg [63:0] buf0 = 0, buf1 = 0;      // bursts 2i and 2i + 1
wire [63:0] bufw = j[2] ? buf1 : buf0;

always @(posedge CLK_48M) begin
    cd_dl_wr <= 0;

    hv         <= valid[dc] && tag_ok;
    hp         <= pending[dc] && tag_ok;
    hit_sector <= d[7:0];
    nc_free    <= !(valid[nc] || pending[nc]) || (!behind[24] && behind > 25'(15 + FREE));

    // A host read ends
    if (fbusy && fr_done == fr_req) begin
        fbusy           <= 0;
        f_err           <= fr_err;
        f_lost          <= fabandon || !disc_ok;
        pending[fchunk] <= 0;
        if (!fr_err && !fabandon && disc_ok) valid[fchunk] <= 1;
        else fill_on <= 0;
    end

    // A burst ends; the next is asked for when its buffer's burst is all sent
    if (rr_wait && rr_done == rr_req) begin
        if (got[0]) buf1 <= rr_data;
        else        buf0 <= rr_data;
        got     <= got + 1'd1;
        rr_word <= rr_word + 25'd4;
        rr_wait <= 0;
    end
    else if (nRESET && (state == S_PRIME || state == S_STREAM) && !rr_wait && rb != 9'(BURSTS) && rb < 9'(wl >> 2) + 9'd2) begin
        rr_req  <= ~rr_req;
        rr_wait <= 1;
        rb      <= rb + 1'd1;
    end

    if (!nRESET) begin
        // Abandon the stream; req_done stays as it is. A read or a burst in flight is still seen through above
        cd_dl_download <= 0;
        state          <= S_IDLE;
    end
    else case (state)
        S_IDLE:
            if (req_pending) begin
                cur_file  <= req_file;
                cur_lba   <= req_file_lba;
                cur_audio <= req_audio;
                fetch_err <= 0;
                state     <= S_MUL;
            end
            else if (fill_go) begin
                fchunk <= nc;
                ffile  <= fill_file;
                flba   <= nxt_lba;
                foff   <= nxt_off;
                ffill  <= 1;
                state  <= S_OFF1;
            end

        S_MUL: begin
            off_a <= (32'(cur_lba) << 11) + (32'(cur_lba) << 8);
            off_b <= (32'(cur_lba) << 5) + (32'(cur_lba) << 4);
            state <= S_LOOK;
        end

        // hv and hp take this clock; a read that ended meanwhile may have changed the answer: look again
        S_LOOK: begin
            cur_off <= off_a + off_b;       // cur_lba * 2352
            stale   <= 0;
            state   <= S_DECIDE;
        end

        S_DECIDE:
            if (stale) state <= S_LOOK;
            else if (bad_pos) begin
                fetch_err <= 1;
                state     <= S_DONE;
            end
            else begin
                last_lba <= cur_lba;
                if (hv) begin
                    base  <= RING_WORD + 25'(hit_sector) * 25'd1176;
                    state <= S_SINK;
                end
                else if (hp) begin
                    mine  <= 1;             // its chunk is on its way
                    state <= S_WAIT_F;
                end
                else if (fbusy) begin
                    mine  <= 0;             // a fill first; then look again
                    state <= S_WAIT_F;
                end
                else begin
                    valid    <= 0;          // flush; chunk 0 from here
                    ring_lba <= cur_lba;
                    fchunk   <= 0;
                    ffile    <= cur_file;
                    flba     <= cur_lba;
                    foff     <= cur_off;
                    ffill    <= 0;
                    mine     <= 1;
                    state    <= S_OFF1;
                end
            end

        // ---- A host read of (ffile, flba) into fchunk ----
        S_OFF1: begin
            valid[fchunk]    <= 0;
            tag_file[fchunk] <= ffile;
            tag_lba[fchunk]  <= flba;
            fr_offset        <= foff;
            fr_slot          <= ffile == 0 ? 16'd2 : 16'd3;
            fr_bridge        <= 32'h7400_0000 + 32'(fchunk) * CHUNK_BYTES;
            rem              <= file_bytes - foff;
            state            <= S_OFF2;
        end

        S_OFF2: begin
            fr_len <= rem < CHUNK_BYTES ? rem : CHUNK_BYTES;
            state  <= S_OFF3;
        end

        // The toggle, a clock after its parameters, which stay until fr_done. The ring moves on only here, so a
        // reset before it leaves at most an invalid chunk with a tag
        S_OFF3: begin
            fr_req          <= ~fr_req;
            fbusy           <= 1;
            fabandon        <= 0;
            pending[fchunk] <= 1;
            head            <= fchunk;
            nxt_lba         <= flba + 24'd16;
            nxt_off         <= foff + CHUNK_BYTES;
            if (!ffill) begin
                fill_on   <= 1;
                fill_file <= ffile;
            end
            state <= ffill ? S_IDLE : S_WAIT_F;
        end

        S_WAIT_F:
            if (!fbusy) begin
                if (mine && (f_err || f_lost)) begin
                    fetch_err <= 1;
                    state     <= S_DONE;
                end
                else state <= S_LOOK;   // there now, or the read was a fill of another chunk
            end

        // ---- Stream ----
        S_SINK:
            if (!disc_ok) begin
                fetch_err <= 1;
                state     <= S_DONE;
            end
            else if (!rr_wait) begin    // an abandoned stream's burst is in
                rr_word <= base;
                rb      <= 0;
                got     <= 0;
                wl      <= 0;
                state   <= S_PRIME;
            end

        // Bursts 0 and 1 in, then the sink's ready
        S_PRIME:
            if (!disc_ok) begin
                fetch_err <= 1;
                state     <= S_DONE;
            end
            else if (got == 9'd2 && (cur_audio ? cdda_ready : cd_data_ready)) begin
                j              <= 0;
                t              <= 0;
                cd_dl_download <= 1;
                cd_dl_audio    <= cur_audio;
                state          <= S_STREAM;
            end

        S_STREAM:
            if (t != 8'd3 || got > 9'(j >> 2)) begin   // else the word's burst is late: its slot waits
                t <= t + 1'd1;
                if (t == 8'd3) begin
                    cd_dl_data <= bufw[16 * j[1:0] +: 16];
                    cd_dl_addr <= j;
                    cd_dl_wr   <= 1;
                    wl         <= j + 1'd1;
                end
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
                state          <= S_DONE;
            end
        end

        S_DONE: begin
            req_done <= ~req_done;
            state    <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase

    if (fbusy && fr_done == fr_req) stale <= 1;

    // No disc: the ring is empty, and a read in flight will not fill it
    if (!disc_ok) begin
        valid   <= 0;
        pending <= 0;
        fill_on <= 0;
        if (fbusy) fabandon <= 1;
    end
end

`ifdef NEOGEO_WAIT_COUNTER
// What tells if the ring keeps ahead of a 4x read, for wait_counter.sv's file. It only watches. n_hit: requests whose
// first look found a valid chunk; n_wait and worst_wait: requests that waited for a host read, and the longest wait
// from the request to its stream (or its fetch_err) in units of 4,096 CLK_48M; min_ahead: at a hit, the fewest sectors
// from the requested one to the end of the newest valid chunk; n_flush: flushes; n_err: host reads that answered err.
reg [31:0] n_hit = 0, n_err = 0;
reg [15:0] n_wait = 0, n_flush = 0, min_ahead = 16'hFFFF;
reg [27:0] w_clks = 0, w_worst = 0;     // CLK_48M, stops at 5.5 s
reg [23:0] vend = 0;                    // the end of the newest valid chunk
reg        first_look = 0, waited = 0;
wire [23:0] ahead = vend - cur_lba;

always @(posedge CLK_48M) begin
    if (!(&w_clks)) w_clks <= w_clks + 1'd1;
    if (nRESET && state == S_IDLE && req_pending) begin
        first_look <= 1;
        waited     <= 0;
        w_clks     <= 0;
    end
    if (state == S_DECIDE && !stale && first_look) begin
        first_look <= 0;
        if (!bad_pos) begin
            if (hv) begin
                n_hit <= n_hit + 1'd1;
                if (ahead < 24'(min_ahead)) min_ahead <= 16'(ahead);
            end
            else waited <= 1;
        end
    end
    if (waited && (state == S_SINK || state == S_DONE)) begin
        waited <= 0;
        n_wait <= n_wait + 1'd1;
        if (w_clks > w_worst) w_worst <= w_clks;
    end
    if (state == S_DECIDE && !stale && !bad_pos && !hv && !hp && !fbusy) begin
        n_flush <= n_flush + 1'd1;
        vend    <= cur_lba;
    end
    if (fbusy && fr_done == fr_req) begin
        if (fr_err) n_err <= n_err + 1'd1;
        else if (!fabandon && disc_ok) vend <= tag_lba[fchunk] + 24'd16;
    end
end

assign dbg_ring = {n_hit, n_wait, w_worst[27:12], min_ahead, n_flush, n_err};
`endif

endmodule
