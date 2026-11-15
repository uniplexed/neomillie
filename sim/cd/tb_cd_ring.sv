// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cd_ring between cd_host (with core_bridge_cmd.v and host_bfm serving prepare.py's ring disc of
// tools/make_test_disc.py --data-sectors 3600) and the bench's model of SDRAM. Bridge writes reach the ring's array
// through the real cd_ring_wr, taken one word per two clocks as pocket_mem_mux takes them (its CLK_96M is CLK_48M here:
// the FIFO drains a bridge word in 4 clocks of 57, and a third clock would add a third of the run time). Reads are a
// model of the mux's ring read client: rr_req toggles with rr_word, a burst of 4 words comes back 3 to 32 CLK_48M later
// (sim/mem measured 59 CLK_96M at worst), every eighth 96, about 192 CLK_96M, the mux's slow case; half of them at a
// CLK_96M edge between CLK_48M's; rr_data scrambled while one is under way. The sinks' ready lines are the bench's.
// The disc is opened in slot 3, so file 1 and fr_slot 3. Disc layout: data 0-3599, INDEX 00 at 3600, track 2 at 3602.
//
// Every stream is checked word by word against the file's sector the bench asked for, with cd_fetch's timing: the
// first cd_dl_wr 4 clocks after cd_dl_download rises, then one per WORD_CLKS, cd_dl_addr 0 to 1175.
//
// test_stream_matches_fetch       sector 16 gives test_stream_byte_order's words (header 00:02:16 mode 1, data the
//                                 sector number) after one host read of its chunk, 37,632 bytes at 0x7400_0000
// test_sequential_4x_with_spikes  300 to 3299 at the 4x pace with 6.4 ms per host command and 500 ms every 400
//                                 sectors: all in order, only the first waits, no error
// test_retry_step_back            after 3299, 3279 is a hit: no host read, no flush
// test_seek_flushes               2279: the tags drop (one flush) and one host read serves it
// test_last_chunk_short           file_bytes 100 sectors: after 80, the read of 96 asks 9,408 bytes; none at 100
// test_error_chunk                err 1 on the read of 1500's chunk: fetch_err, req_done, nothing streamed; the next
//                                 request for 1500 reads it again and streams it
// test_audio_through_ring         after data sector 3598, audio 3602 (in the same chunk) waits for cdda_ready, then
//                                 streams with cd_dl_audio
// test_disc_change_and_reset      disc_present low drops every tag; nRESET mid-stream abandons it and req_done
//                                 never moves, as test_reset_abandons_stream
`timescale 1ns/1ps
module tb_cd_ring;
    import host_bfm_pkg::*;

    localparam real PERIOD_48 = 20.688;
    localparam real PERIOD_74 = 13.468;
    localparam int  SECTOR = 2352;
    localparam string DISC = "/Assets/ngcd/common/ring/disc.bin";
    localparam int  DISC_SECTORS = 3600 + 2 + 10 + 2 + 10;
    localparam int  AUDIO_LBA = 3602;
    localparam int  WORD_CLKS = 20;
    localparam int  PACE = 161118;              // CLK_48M per sector at 4x
    localparam int  CMD_LAT = 475200;           // 6.4 ms of clk_74a
    localparam int  SPIKE_LAT = 37125000;       // 500 ms
    localparam int  RING_WORD = 25'h0200000;
    localparam int  RING_WORDS = 301056;

    logic clk74 = 0, clk48 = 0;
    always #(PERIOD_74 / 2) clk74 = ~clk74;
    always #(PERIOD_48 / 2) clk48 = ~clk48;

    // ---- Bridge, host, core_bridge_cmd.v ----
    wire [31:0] bridge_addr, bridge_wr_data, cmd_rd_data, host_rd_data;
    wire        bridge_wr, bridge_rd;
    wire [31:0] bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_rd_data :
                                 bridge_addr[31:24] == 8'h71 ? host_rd_data : 32'h0;

    host_bfm #(.POLL_CLKS(200), .LATENCY_CLKS(2000)) host (
        .clk(clk74), .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data);

    wire        t_read, t_write, t_getfile, t_openfile, t_ack, t_done;
    wire  [2:0] t_err;
    wire [15:0] t_id;
    wire [31:0] t_offset, t_addr, t_len, param_struct, resp_struct;

    core_bridge_cmd icb (
        .clk(clk74), .reset_n(),
        .bridge_endian_little(1'b0), .bridge_addr, .bridge_rd, .bridge_rd_data(cmd_rd_data),
        .bridge_wr, .bridge_wr_data,
        .status_boot_done(1'b1), .status_setup_done(1'b1), .status_running(1'b1),
        .dataslot_requestread(), .dataslot_requestread_id(), .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite(), .dataslot_requestwrite_id(), .dataslot_requestwrite_size(),
        .dataslot_requestwrite_ack(1'b1), .dataslot_requestwrite_ok(1'b1),
        .dataslot_update(), .dataslot_update_id(), .dataslot_update_size(), .dataslot_allcomplete(),
        .rtc_epoch_seconds(), .rtc_date_bcd(), .rtc_time_bcd(), .rtc_valid(),
        .savestate_supported(1'b0), .savestate_addr(32'd0), .savestate_size(32'd0), .savestate_maxloadsize(32'd0),
        .osnotify_inmenu(),
        .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
        .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
        .target_dataslot_read(t_read), .target_dataslot_write(t_write),
        .target_dataslot_getfile(t_getfile), .target_dataslot_openfile(t_openfile),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_addr), .target_dataslot_length(t_len),
        .target_buffer_param_struct(param_struct), .target_buffer_resp_struct(resp_struct),
        .datatable_addr(10'd0), .datatable_wren(1'b0), .datatable_data(32'd0), .datatable_q()
    );

    // ---- cd_host ----
    wire        fr_req, fr_done, fr_err;
    wire [15:0] fr_slot;
    wire [31:0] fr_offset, fr_bridge, fr_len;

    cd_host chost (
        .clk_74a(clk74), .CLK_48M(clk48), .rst(1'b0),
        .target_dataslot_read(t_read), .target_dataslot_getfile(t_getfile), .target_dataslot_openfile(t_openfile),
        .target_dataslot_write(t_write),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_addr), .target_dataslot_length(t_len),
        .target_buffer_param_struct(param_struct), .target_buffer_resp_struct(resp_struct),
        .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data(host_rd_data),
        .mr_req(1'b0), .mr_kind(2'd0), .mr_slot(16'd0), .mr_offset(32'd0), .mr_len(32'd0), .mr_bank_slot(2'd0),
        .mr_done(), .mr_err(), .rs_hold(1'b0), .rs_free(),
        .fr_req, .fr_slot, .fr_offset, .fr_bridge, .fr_len, .fr_done, .fr_err,
        .ws_req(1'b0), .ws_done(), .ws_err(),
        .bank_rd_addr(12'd0), .bank_rd_q(), .bank_rd_addr_74(12'd0), .bank_rd_q_74(),
        .path_addr(8'd0), .path_wr(1'b0), .path_wdata(32'd0), .path_q()
    );

    // ---- SDRAM: the ring's words, written through cd_ring_wr as the mux takes them ----
    logic [15:0] sdram [0:RING_WORDS-1];
    initial for (int i = 0; i < RING_WORDS; i++) sdram[i] = 16'hBAD0;

    wire        rw_valid;
    wire [24:0] rw_word;
    wire [15:0] rw_data;
    logic       rw_take = 0;

    cd_ring_wr ring_wr (
        .clk_74a(clk74), .bridge_wr, .bridge_addr, .bridge_wr_data,
        .CLK_96M(clk48), .rw_valid, .rw_word, .rw_data, .rw_take);

    always @(posedge clk48) begin
        rw_take <= rw_valid && !rw_take;
        if (rw_take) sdram[int'(rw_word) - RING_WORD] <= rw_data;
    end

    // ---- The mux's ring read client ----
    wire        rr_req;
    wire [24:0] rr_word;
    logic       rr_done = 0;
    logic [63:0] rr_data = 0;
    int         rr_n = 0;

    // ---- DUT ----
    logic        nRESET = 0, disc_present = 1;
    logic [23:0] req_lba = 0, req_file_lba = 0;
    logic        req_audio = 0, req_valid = 0;
    logic  [6:0] req_file = 0;
    logic        data_ready = 1, cdda_ready = 1;
    logic [31:0] file_bytes = DISC_SECTORS * SECTOR;
    wire         req_done, cd_dl_download, cd_dl_audio, cd_dl_wr, fetch_err;
    wire  [11:1] cd_dl_addr;
    wire  [15:0] cd_dl_data;
    wire [127:0] dbg_ring;
    wire  [31:0] n_hit = dbg_ring[127:96], n_err = dbg_ring[31:0];
    wire  [15:0] n_wait = dbg_ring[95:80], worst_wait = dbg_ring[79:64], min_ahead = dbg_ring[63:48],
                 n_flush = dbg_ring[47:32];

    cd_ring dut (
        .CLK_48M(clk48), .nRESET, .disc_present,
        .req_lba, .req_audio, .req_file, .req_file_lba, .req_valid, .req_done,
        .file_bytes,
        .fr_req, .fr_slot, .fr_offset, .fr_bridge, .fr_len, .fr_done, .fr_err,
        .rr_req, .rr_word, .rr_done, .rr_data,
        .cd_dl_download, .cd_dl_audio, .cd_dl_wr, .cd_dl_addr, .cd_dl_data,
        .cd_data_ready(data_ready), .cdda_ready,
        .dbg_ring,
        .fetch_err
    );

    // ---- Checks ----
    int errors = 0, tests = 0;
    string test = "";
    function automatic void check(input bit ok, input string msg);
        if (!ok) begin
            errors++;
            if (errors <= 40) $display("%0s: %0s", test, msg);
        end
    endfunction

    // The read client: one burst at a time, rr_word a multiple of 4 inside the ring and still until the answer
    initial forever begin
        @(rr_req);
        @(posedge clk48);
        begin
            automatic int lat = ++rr_n % 8 == 0 ? 96 : $urandom_range(3, 32);
            automatic logic [24:0] w = rr_word;
            check(w[1:0] == 0 && int'(w) >= RING_WORD && int'(w) + 3 < RING_WORD + RING_WORDS,
                  $sformatf("ring read at %h", w));
            repeat (2) @(posedge clk48);
            rr_data <= 64'hDEAD_BEEF_DEAD_BEEF;     // the mux shifts words in while it reads
            repeat (lat - 2) @(posedge clk48);
            check(rr_word == w, "rr_word moved during its read");
            if ($urandom_range(0, 1)) @(negedge clk48);
            rr_data <= {sdram[w - RING_WORD + 3], sdram[w - RING_WORD + 2], sdram[w - RING_WORD + 1], sdram[w - RING_WORD]};
            rr_done <= ~rr_done;
        end
    end

    // The disc, to check streams against
    logic [7:0] disc [0:DISC_SECTORS*SECTOR-1];
    function automatic logic [15:0] want_word(input int lba, input int j);
        return {disc[lba * SECTOR + 2 * j + 1], disc[lba * SECTOR + 2 * j]};
    endfunction

    // Every stream: its words against the sector asked for, and cd_fetch's timing
    int exp_lba = -1, streams = 0, s_words = 0, s_bad = 0, s_late = 0, since = 0;
    logic [15:0] s_word [0:1175];
    realtime t_stream = 0;
    logic dl_d = 0;
    always @(posedge clk48) begin
        dl_d <= cd_dl_download;
        since++;
        if (cd_dl_download && !dl_d) begin
            streams++;
            t_stream = $realtime;
            s_words = 0;
            s_bad = 0;
            s_late = 0;
            since = 0;
        end
        if (cd_dl_wr) begin
            if (since != (s_words == 0 ? 4 : WORD_CLKS)) s_late++;
            since = 0;
            if (s_words < 1176) s_word[s_words] = cd_dl_data;
            if (int'(cd_dl_addr) != s_words || cd_dl_data != want_word(exp_lba, s_words)) s_bad++;
            s_words++;
        end
    end

    task automatic tick();
        @(posedge clk48);
        #1;
    endtask

    // Ask for a sector as cdd_drive does; t is when the toggle went out
    task automatic request(input int lba, input bit audio, output realtime t);
        do tick(); while (req_valid != req_done || !(audio ? cdda_ready : data_ready));
        request_now(lba, audio);
        t = $realtime;
    endtask

    // Whatever the ring and the sink are doing
    task automatic request_now(input int lba, input bit audio);
        req_lba      = 24'(lba);
        req_file     = 7'd1;
        req_file_lba = 24'(lba);
        req_audio    = audio;
        exp_lba      = lba;
        tick();
        req_valid = ~req_valid;
    endtask

    task automatic wait_done(input real limit_ms = 50.0);
        realtime limit = $realtime + limit_ms * 1.0e6;
        while (req_done != req_valid && $realtime < limit) @(posedge clk48);
        check(req_done == req_valid, $sformatf("sector %0d: req_done did not follow in %0.0f ms", exp_lba, limit_ms));
    endtask

    // The stream just done: all 1,176 words of exp_lba, on time
    task automatic check_stream(input int s0, input string what);
        repeat (40) @(posedge clk48);
        check(streams == s0 + 1, $sformatf("%0s: %0d streams", what, streams - s0));
        check(s_words == 1176 && s_bad == 0, $sformatf("%0s: %0d words, %0d wrong", what, s_words, s_bad));
        check(s_late == 0, $sformatf("%0s: %0d words off cd_fetch's timing", what, s_late));
        check(!fetch_err, $sformatf("%0s: fetch_err set", what));
    endtask

    function automatic int reads_between(input realtime t0, input realtime t1);
        int n = 0;
        foreach (host.log_q[i]) if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].t_busy >= t0 && host.log_q[i].t_busy <= t1) n++;
        return n;
    endfunction

    function automatic int read_of(input int first, input int lba);     // log index of a read starting at lba, or -1
        for (int i = first; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].offset == lba * SECTOR && host.log_q[i].id == 3) return i;
        return -1;
    endfunction

    // No request, no host read, and none about to start
    task automatic wait_quiet();
        int calm = 0;
        while (calm < 64) begin
            @(posedge clk48);
            calm = (dut.fbusy || dut.state != dut.S_IDLE || req_valid != req_done) ? 0 : calm + 1;
        end
    endtask

    // ---- Tests ----
    task automatic test_stream_matches_fetch();
        realtime t;
        int n0 = host.log_q.size(), s0 = streams;
        test = "test_stream_matches_fetch";
        request(16, 0, t);
        wait_done();
        check_stream(s0, "sector 16");
        // test_stream_byte_order's values: header 00:02:16 mode 1, then the sector number as big-endian words
        check(s_word[6] == 16'h0200 && s_word[7] == 16'h0116, $sformatf("header words %04x %04x", s_word[6], s_word[7]));
        for (int k = 8; k < 8 + 1024; k++)
            if (s_word[k] != 16'h1000) begin
                check(0, $sformatf("data word %0d is %04x, expected 1000", k, s_word[k]));
                break;
            end
        check(reads_between(t, t_stream) == 1, $sformatf("%0d host reads between the request and the stream", reads_between(t, t_stream)));
        check(n0 < host.log_q.size() && host.log_q[n0].offset == 16 * SECTOR && host.log_q[n0].id == 3 &&
              host.log_q[n0].len == 16 * SECTOR && host.log_q[n0].addr == 32'h7400_0000,
              "the first host read was not sectors 16 to 31 of slot 3 into the ring's chunk 0");
    endtask

    task automatic test_sequential_4x_with_spikes();
        realtime t;
        int s0, w0, e0, waited = 0;
        realtime next = 0;
        test = "test_sequential_4x_with_spikes";
        wait_quiet();
        // A command per chunk: 6.4 ms, and 500 ms every 25 chunks (400 sectors)
        for (int k = 0; k < 220; k++) host.latency_seq.push_back(k > 0 && k % 25 == 0 ? SPIKE_LAT : CMD_LAT);
        host.latency_clks = CMD_LAT;
        w0 = n_wait;
        e0 = n_err;
        s0 = streams;
        for (int lba = 300; lba < 3300; lba++) begin
            realtime t0;
            // One request per sector time, or later if the last is not done: the drive never catches up
            while ($realtime < next || req_valid != req_done) @(posedge clk48);
            request_now(lba, 0);
            t0 = $realtime;
            next = t0 + PACE * PERIOD_48;
            wait_done(lba == 300 ? 50.0 : 600.0);
            repeat (40) @(posedge clk48);
            if (lba != 300 && t_stream - t0 > 1.0e4) waited++;
            if (s_words != 1176 || s_bad != 0 || s_late != 0 || streams != s0 + lba - 299)
                check(0, $sformatf("sector %0d: %0d words, %0d wrong, %0d late, %0d streams", lba, s_words, s_bad, s_late, streams - s0));
        end
        check(waited == 0, $sformatf("%0d requests after the first waited", waited));
        check(n_wait - w0 == 1, $sformatf("%0d requests waited for a read, 1 expected", n_wait - w0));
        check(n_err == e0, "a read failed");
        $display("sequential: min ahead %0d sectors, worst wait %0d x 4096 clocks", min_ahead, worst_wait);
        host.latency_seq.delete();
        host.latency_clks = 2000;
    endtask

    task automatic test_retry_step_back();
        realtime t;
        int s0 = streams, f0, h0;
        test = "test_retry_step_back";
        wait_quiet();
        f0 = n_flush;
        h0 = n_hit;
        request(3279, 0, t);
        wait_done();
        check_stream(s0, "3279 after 3299");
        check(reads_between(t, $realtime) == 0, $sformatf("%0d host reads for a step back", reads_between(t, $realtime)));
        check(n_flush == f0, "the step back flushed the ring");
        check(n_hit == h0 + 1, $sformatf("%0d hits", n_hit - h0));
    endtask

    task automatic test_seek_flushes();
        realtime t;
        int s0 = streams, f0 = n_flush;
        test = "test_seek_flushes";
        request(2279, 0, t);
        wait_done();
        check_stream(s0, "2279");
        check(n_flush == f0 + 1, $sformatf("%0d flushes", n_flush - f0));
        check(reads_between(t, t_stream) == 1, $sformatf("%0d host reads between the request and the stream", reads_between(t, t_stream)));
    endtask

    task automatic test_last_chunk_short();
        realtime t;
        int s0 = streams, n0, i;
        test = "test_last_chunk_short";
        wait_quiet();
        file_bytes = 100 * SECTOR;
        n0 = host.log_q.size();
        request(80, 0, t);
        wait_done();
        check_stream(s0, "80");
        wait_quiet();
        i = read_of(n0, 96);
        check(i >= 0 && host.log_q[i].len == 4 * SECTOR, $sformatf("the read of 96: %0s", i < 0 ? "none" : $sformatf("%0d bytes", host.log_q[i].len)));
        for (int k = n0; k < host.log_q.size(); k++)
            check(host.log_q[k].offset < 100 * SECTOR, $sformatf("a read at sector %0d, past the end", host.log_q[k].offset / SECTOR));
        file_bytes = DISC_SECTORS * SECTOR;
    endtask

    task automatic test_error_chunk();
        realtime t;
        int s0, n0, e0;
        test = "test_error_chunk";
        wait_quiet();
        host.fail_next = 1;
        s0 = streams;
        n0 = host.log_q.size();
        e0 = n_err;
        request(1500, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(fetch_err, "fetch_err not set");
        check(streams == s0, "a failed sector was streamed");
        check(host.log_q.size() > n0 && host.log_q[n0].err == 1 && host.log_q[n0].offset == 1500 * SECTOR,
              "the host did not fail the read of 1500's chunk");
        check(n_err == e0 + 1, $sformatf("%0d errors counted", n_err - e0));
        // There again: read, streamed, fetch_err cleared
        n0 = host.log_q.size();
        request(1500, 0, t);
        wait_done();
        check_stream(s0, "1500 after the error");
        check(read_of(n0, 1500) >= 0, "1500's chunk not read again");
    endtask

    task automatic test_audio_through_ring();
        realtime t, t1;
        int s0 = streams;
        test = "test_audio_through_ring";
        request(3598, 0, t);
        wait_done();
        check_stream(s0, "data 3598");
        // 3602 is in 3598's chunk: no read, and no stream until cdda.v has room
        wait_quiet();
        cdda_ready = 0;
        request_now(AUDIO_LBA, 1);
        t1 = $realtime;
        repeat (4000) @(posedge clk48);
        check(streams == s0 + 1, "the audio sector streamed with cdda_ready low");
        cdda_ready = 1;
        wait_done();
        check_stream(s0 + 1, "audio 3602");
        check(cd_dl_audio, "cd_dl_audio low for an audio sector");
        check(reads_between(t1, t_stream) == 0, "the audio sector was read again");
    endtask

    task automatic test_disc_change_and_reset();
        realtime t;
        int s0, n0;
        logic done0;
        test = "test_disc_change_and_reset";
        wait_quiet();
        check(dut.valid != 0, "the ring is empty before the change");
        @(posedge clk48) disc_present <= 0;
        repeat (4) @(posedge clk48);
        check(dut.valid == 0 && dut.pending == 0, $sformatf("chunks %b still valid with no disc", dut.valid));
        @(posedge clk48) disc_present <= 1;
        n0 = host.log_q.size();
        s0 = streams;
        request(3599, 0, t);
        wait_done();
        check_stream(s0, "3599 after the change");
        check(read_of(n0, 3599) >= 0, "3599 served from the ring of the old disc");
        // nRESET in a stream
        request(3600, 0, t);
        @(posedge cd_dl_download);
        repeat (2000) @(posedge clk48);
        done0 = req_done;
        nRESET <= 0;
        repeat (200) begin
            tick();
            req_valid = req_done;
        end
        check(!cd_dl_download, "the stream goes on through nRESET");
        check(req_done == done0, "req_done moved under nRESET");
        nRESET <= 1;
        repeat (100) @(posedge clk48);
        check(req_done == done0 && req_valid == req_done, "req_done moved after nRESET");
        // and it works after
        s0 = streams;
        request(3601, 0, t);
        wait_done();
        check_stream(s0, "3601 after nRESET");
    endtask

    // The Pocket's case: a core reset with the ring full, then the BIOS reading from the start of the disc again. Sectors the
    // ring still holds, sectors below it, and a run past what it held, each checked word by word
    task automatic test_reset_then_run();
        realtime t;
        int s0;
        test = "test_reset_then_run";
        for (int lba = 20; lba < 140; lba++) begin
            s0 = streams;
            request(lba, 0, t);
            wait_done();
            check_stream(s0, $sformatf("%0d before the reset", lba));
        end
        // The reset lands in a stream, with fills going on, and lasts as a core reset does
        request(140, 0, t);
        @(posedge cd_dl_download);
        repeat (2000) @(posedge clk48);
        nRESET <= 0;
        repeat (20000) begin
            tick();
            req_valid = req_done;
        end
        nRESET <= 1;
        repeat (100) @(posedge clk48);
        check(dut.valid != 0, "the test wants chunks still valid after the reset");
        foreach (dut.valid[c]) if (dut.valid[c]) begin
            // every sector of a chunk that is still valid, in a row, as the BIOS reads a file
            for (int k = 0; k < 16; k++) begin
                s0 = streams;
                request(int'(dut.tag_lba[c]) + k, 0, t);
                wait_done();
                check_stream(s0, $sformatf("%0d after the reset, chunk %0d", int'(dut.tag_lba[c]) + k, c));
            end
            break;
        end
        for (int lba = 16; lba < 200; lba++) begin
            s0 = streams;
            request(lba, 0, t);
            wait_done();
            check_stream(s0, $sformatf("%0d after the reset", lba));
        end
        // Resets at every point of a stream, a fill in flight or not, then three sectors in a row
        for (int n = 0; n < 400; n++) begin
            automatic int lba = 300 + 7 * n;
            automatic int at = $urandom_range(0, 24000);
            request(lba, 0, t);
            if (at < 23000) begin
                @(posedge cd_dl_download);
                repeat (at) @(posedge clk48);
            end
            else repeat (at - 23000) @(posedge clk48);     // before the stream starts: in the look-up or a host read
            nRESET <= 0;
            repeat ($urandom_range(50, 3000)) begin
                tick();
                req_valid = req_done;
            end
            nRESET <= 1;
            repeat ($urandom_range(1, 200)) @(posedge clk48);
            for (int k = 0; k < 3; k++) begin
                s0 = streams;
                request(lba + k, 0, t);
                wait_done();
                check_stream(s0, $sformatf("%0d, sector %0d after reset %0d at clock %0d", lba + k, k, n, at));
            end
        end
        // One sector a seek, each the next: what the BIOS did on the Pocket
        for (int lba = 44; lba < 60; lba++) begin
            s0 = streams;
            request(lba, 0, t);
            wait_done();
            check_stream(s0, $sformatf("%0d, one a seek", lba));
            repeat (50000) @(posedge clk48);
        end
    endtask

    task automatic run(input string name);
        tests++;
        case (name)
            "test_stream_matches_fetch":      test_stream_matches_fetch();
            "test_sequential_4x_with_spikes": test_sequential_4x_with_spikes();
            "test_retry_step_back":           test_retry_step_back();
            "test_seek_flushes":              test_seek_flushes();
            "test_last_chunk_short":          test_last_chunk_short();
            "test_error_chunk":               test_error_chunk();
            "test_audio_through_ring":        test_audio_through_ring();
            "test_disc_change_and_reset":     test_disc_change_and_reset();
            "test_reset_then_run":            test_reset_then_run();
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done at %0.1f ms, %0d failures so far", name, $realtime / 1.0e6, errors);
    endtask

    initial begin
        string files [] = '{DISC};
        int fd = $fopen(DISC.substr(1, DISC.len() - 1), "rb");
        if (fd == 0) $fatal(1, "no %s", DISC);
        if ($fread(disc, fd) != DISC_SECTORS * SECTOR) $fatal(1, "%s is not %0d sectors", DISC, DISC_SECTORS);
        $fclose(fd);
        host.slot_file[3] = DISC;
        fork host.serve_forever(files); join_none
        repeat (100) @(posedge clk48);
        nRESET <= 1;
        repeat (100) @(posedge clk48);
        begin
            automatic string only;
            if ($value$plusargs("only=%s", only)) begin     // one test, for a short run
                run(only);
                if (errors != 0) $fatal(1, "%0d failures", errors);
                $display("cd_ring: %0s passed", only);
                $finish;
            end
        end
        run("test_stream_matches_fetch");
        run("test_sequential_4x_with_spikes");
        run("test_retry_step_back");
        run("test_seek_flushes");
        run("test_last_chunk_short");
        run("test_error_chunk");
        run("test_audio_through_ring");
        run("test_disc_change_and_reset");
        run("test_reset_then_run");
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("cd_ring: %0d tests passed", tests);
        $finish;
    end

    initial begin
        #(14.0e9);
        $fatal(1, "timeout");
    end
endmodule
