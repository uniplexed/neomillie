// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cd_fetch between cd_host (with core_bridge_cmd.v and host_bfm serving prepare.py's disc of
// tools/make_test_disc.py --data-sectors 520) and MiSTer's real cd_sys, with the 68K idle. The glue between
// cd_fetch and cd_sys is neogeo_pocket.sv's, copied: the 16-clock ioctl_wr_x extender and the data/CDDA
// split. The bench asks for sectors as cdd_drive does: a toggle of req_valid, only when req_valid ==
// req_done and the sink is ready (CD_DATA_WR_READY, or CDDA_WR_READY for audio). The disc is opened in
// slot 3 as a CUE's BIN would be, so file 1 and fr_slot 3. Disc layout: data 0-519, INDEX 00 at 520,
// track 2 at 522 (audio, 10 sectors).
//
// test_stream_byte_order          sector 16: cd_sys's header registers hold 00:02:16 mode 1 (lba + 150) and
//                                 its cache the 2,048 bytes of the sector number as big-endian words
// test_prefetch_hits              17, 18 and 19 in turn: no host read starts between a request and its stream
// test_miss_after_seek            500: one host read for it, then reads of 501, 502 and 503 (the prefetch)
// test_audio_stream_to_cdda       the first audio sector: 1,176 CDDA_WR edges, cdda.v's buffer holds the
//                                 tone's first 588 stereo samples, the data cache untouched
// test_fetch_error_reports_position  err 1 (fail_next): req_done toggles, fetch_err set, nothing streamed, the
//                                 slot invalid; a position below the disc (file_lba[23]) reads nothing
// test_disc_change_invalidates    disc_present falling empties the bank: a sector held before is read again
// test_reset_abandons_stream      nRESET mid-stream: the stream stops and req_done does not move, as Task 5's
//                                 contract (a) needs with cdd_drive mirroring req_valid <= req_done
// test_debug_counts               NEOGEO_WAIT_COUNTER's counts, each by its own event, the worst host read as the bench saw it
`timescale 1ns/1ps
module tb_cd_fetch;
    import host_bfm_pkg::*;

    localparam real PERIOD_74 = 13.468;
    localparam real PERIOD_48 = 20.689;
    localparam int  SECTOR = 2352;
    localparam string DISC = "/Assets/ngcd/common/disc/disc.bin";
    localparam int  AUDIO_LBA = 522;

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
    wire [31:0] fr_offset, bank_rd_q;
    wire  [1:0] fr_bank_slot;
    wire [11:0] bank_rd_addr;

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
        .fr_req, .fr_slot, .fr_offset, .fr_bank_slot, .fr_done, .fr_err,
        .ws_req(1'b0), .ws_done(), .ws_err(),
        .bank_rd_addr, .bank_rd_q, .bank_rd_addr_74(12'd0), .bank_rd_q_74(),
        .path_addr(8'd0), .path_wr(1'b0), .path_wdata(32'd0), .path_q()
    );

    // ---- DUT ----
    logic        nRESET = 0, disc_present = 1;
    logic [23:0] req_lba = 0, req_file_lba = 0;
    logic        req_audio = 0, req_valid = 0;
    logic  [6:0] req_file = 0;
    wire         req_done, cd_dl_download, cd_dl_audio, cd_dl_wr, fetch_err;
    wire  [11:1] cd_dl_addr;
    wire  [15:0] cd_dl_data;
    wire         CD_DATA_WR_READY, CDDA_WR_READY;
    logic        poll = 0;
    wire [319:0] dbg_fetch;
    wire [0:9][31:0] fc = dbg_fetch;    // data, audio, hit, miss, worst, busy, late, sink at a poll, sink waited, abandoned

    cd_fetch dut (
        .CLK_48M(clk48), .nRESET, .disc_present,
        .req_lba, .req_audio, .req_file, .req_file_lba, .req_valid, .req_done,
        .fr_req, .fr_slot, .fr_offset, .fr_bank_slot, .fr_done, .fr_err,
        .bank_rd_addr, .bank_rd_q,
        .cd_dl_download, .cd_dl_audio, .cd_dl_wr, .cd_dl_addr, .cd_dl_data,
        .cd_data_ready(CD_DATA_WR_READY), .cdda_ready(CDDA_WR_READY),
        .dbg_poll(poll), .dbg_fetch,
        .fetch_err
    );

    // ---- neogeo_pocket.sv's glue, copied ----
    reg  ioctl_wr_x = 0;
    reg [3:0] wr_cnt = 0;
    always @(posedge clk48) begin
        if (cd_dl_wr) begin
            wr_cnt <= 4'd15;
            ioctl_wr_x <= 1;
        end
        else if (wr_cnt) wr_cnt <= wr_cnt - 1'd1;
        else ioctl_wr_x <= 0;
    end
    wire CD_DATA_DOWNLOAD = cd_dl_download & ~cd_dl_audio;
    wire CD_DATA_WR = ioctl_wr_x & CD_DATA_DOWNLOAD;
    wire CDDA_DOWNLOAD = cd_dl_download & cd_dl_audio;
    wire CDDA_WR = ioctl_wr_x & CDDA_DOWNLOAD;

    // ---- cd_sys, the 68K idle ----
    wire [15:0] M68K_DATA;
    logic       clk_68k_en = 0;
    always @(posedge clk48) clk_68k_en <= ~clk_68k_en;

    cd_sys #(.MCLK(48335658)) cdsystem (
        .nRESET, .clk_sys(clk48), .CLK_68KCLK_EN(clk_68k_en),
        .M68K_ADDR(23'd0), .M68K_DATA, .A22Z(1'b0), .A23Z(1'b0),
        .nLDS(1'b1), .nUDS(1'b1), .M68K_RW(1'b1), .nAS(1'b1), .nDTACK(1'b1),
        .nBR(), .nBG(1'b1), .nBGACK(),
        .SYSTEM_CDx(1'b1), .CD_REGION(2'd0), .CD_SPEED(2'd0), .CD_LID(1'b1),
        .CD_VIDEO_EN(), .CD_FIX_EN(), .CD_SPR_EN(), .CD_nRESET_Z80(),
        .CD_TR_WR_SPR(), .CD_TR_WR_PCM(), .CD_TR_WR_Z80(), .CD_TR_WR_FIX(),
        .CD_TR_RD_FIX(), .CD_TR_RD_SPR(), .CD_TR_RD_Z80(), .CD_TR_RD_PCM(),
        .CD_USE_FIX(), .CD_USE_SPR(), .CD_USE_Z80(), .CD_USE_PCM(),
        .CD_TR_AREA(), .CD_BANK_SPR(), .CD_BANK_PCM(), .CD_TR_WR_DATA(), .CD_TR_WR_ADDR(),
        .CD_UPLOAD_EN(), .CD_IRQ(), .IACK(1'b0), .CD_VBLANK_IRQ_EN(), .CD_TIMER_IRQ_EN(),
        .CDD_STATUS_IN(40'd0), .CDD_STATUS_LATCH(1'b0), .CDD_COMMAND_DATA(), .CDD_COMMAND_SEND(),
        .CD_DATA_DOWNLOAD, .CD_DATA_WR, .CD_DATA_DIN(cd_dl_data), .CD_DATA_ADDR(cd_dl_addr),
        .CD_DATA_WR_READY,
        .CDDA_RD(1'b0), .CDDA_WR, .CD_AUDIO_L(), .CD_AUDIO_R(), .CDDA_WR_READY,
        .DMA_RUNNING(), .DMA_DATA_IN(16'd0), .DMA_DATA_OUT(), .DMA_WR_OUT(), .DMA_RD_OUT(),
        .DMA_ADDR_IN(), .DMA_ADDR_OUT(), .DMA_SDRAM_BUSY(1'b0)
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

    // What the bench sees: streams begun, data and CDDA write edges
    int streams = 0, data_wrs = 0, cdda_wrs = 0;
    realtime t_stream = 0;
    logic dl_d = 0, cdwr_d = 0, cddawr_d = 0;
    always @(posedge clk48) begin
        dl_d     <= cd_dl_download;
        cdwr_d   <= CD_DATA_WR;
        cddawr_d <= CDDA_WR;
        if (cd_dl_download && !dl_d) begin
            streams++;
            t_stream = $realtime;
        end
        if (CD_DATA_WR && !cdwr_d) data_wrs++;
        if (CDDA_WR && !cddawr_d) cdda_wrs++;
    end

    function automatic logic [7:0] bcd(input int v);
        return 8'(((v / 10) << 4) | (v % 10));
    endfunction

    function automatic logic [15:0] sample(input int n);
        return 16'($rtoi($floor(16384.0 * $sin(2.0 * 3.141592653589793 * 1000.0 * n / 44100.0) + 0.5)));
    endfunction

    task automatic tick();
        @(posedge clk48);
        #1;
    endtask

    // Ask for a sector as cdd_drive does; t is when the toggle went out. Driven after the edge and blocking:
    // wait_done reads req_valid next, and a nonblocking toggle would still read as the old value there
    task automatic request(input int lba, input int file_lba, input bit audio, output realtime t);
        do tick(); while (req_valid != req_done || !(audio ? CDDA_WR_READY : CD_DATA_WR_READY));
        req_lba      = 24'(lba);
        req_file     = 7'd1;
        req_file_lba = 24'(file_lba);
        req_audio    = audio;
        tick();
        req_valid = ~req_valid;
        t = $realtime;
    endtask

    task automatic wait_done(input real limit_ms = 50.0);
        realtime limit = $realtime + limit_ms * 1.0e6;
        while (req_done != req_valid && $realtime < limit) @(posedge clk48);
        check(req_done == req_valid, $sformatf("req_done did not follow in %0.0f ms", limit_ms));
    endtask

    // Host commands that started in [t0, t1]
    function automatic int reads_between(input realtime t0, input realtime t1);
        int n = 0;
        foreach (host.log_q[i]) if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].t_busy >= t0 && host.log_q[i].t_busy <= t1) n++;
        return n;
    endfunction

    function automatic bit was_read(input int first, input int lba);
        for (int i = first; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].offset == lba * SECTOR && host.log_q[i].id == 3) return 1;
        return 0;
    endfunction

    // No host read in flight and no prefetch to come
    task automatic wait_quiet();
        do @(posedge clk48); while (dut.fbusy || dut.pf_left != 0 || dut.state != dut.S_IDLE || req_valid != req_done);
        repeat (4) @(posedge clk48);
    endtask

    // The bank cd_sys is loading into, and its header and cache
    task automatic check_sector_in_cache(input int lba);
        logic bank = cdsystem.CACHE_WR_BANK;
        int a = lba + 150, bad = 0;
        check(cdsystem.SECTOR_FILLED[bank] == 1, $sformatf("sector %0d: cache bank %0d not filled", lba, bank));
        check(cdsystem.HEAD_0[bank] == bcd(a / 4500) && cdsystem.HEAD_1[bank] == bcd(a / 75 % 60) &&
              cdsystem.HEAD_2[bank] == bcd(a % 75) && cdsystem.HEAD_3[bank] == 8'h01,
              $sformatf("sector %0d: header %02x %02x %02x %02x, expected %02x %02x %02x 01", lba,
                        cdsystem.HEAD_0[bank], cdsystem.HEAD_1[bank], cdsystem.HEAD_2[bank], cdsystem.HEAD_3[bank],
                        bcd(a / 4500), bcd(a / 75 % 60), bcd(a % 75)));
        for (int k = 0; k < 2048; k++) begin
            automatic logic [7:0] want = k[0] ? 8'(lba) : 8'(lba >> 8);
            if (cdsystem.CACHE.altsyncram_component.mem[{bank, 11'(k)}] != want) begin
                if (bad < 3) check(0, $sformatf("sector %0d: cache byte %0d is %02x, expected %02x", lba, k,
                                                cdsystem.CACHE.altsyncram_component.mem[{bank, 11'(k)}], want));
                bad++;
            end
        end
        check(bad == 0, $sformatf("sector %0d: %0d cache bytes wrong", lba, bad));
    endtask

    // ---- Tests ----
    task automatic test_stream_byte_order();
        realtime t;
        int n0 = host.log_q.size(), s0 = streams, w0 = data_wrs;
        test = "test_stream_byte_order";
        request(16, 16, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(!fetch_err, "fetch_err set");
        check(streams == s0 + 1, $sformatf("%0d streams", streams - s0));
        check(data_wrs == w0 + 1176, $sformatf("%0d CD_DATA_WR edges, 1176 expected", data_wrs - w0));
        check(n0 < host.log_q.size() && host.log_q[n0].offset == 16 * SECTOR && host.log_q[n0].id == 3 &&
              host.log_q[n0].len == SECTOR, "the first host read was not sector 16 of slot 3");
        check(reads_between(t, t_stream) == 1, $sformatf("%0d host reads between the request and the stream", reads_between(t, t_stream)));
        check_sector_in_cache(16);
    endtask

    task automatic test_prefetch_hits();
        realtime t;
        test = "test_prefetch_hits";
        for (int lba = 17; lba <= 19; lba++) begin
            int s0 = streams;
            request(lba, lba, 0, t);
            wait_done();
            repeat (40) @(posedge clk48);
            check(streams == s0 + 1, $sformatf("sector %0d: %0d streams", lba, streams - s0));
            check(reads_between(t, t_stream) == 0, $sformatf("sector %0d: %0d host reads between its request and its stream",
                                                            lba, reads_between(t, t_stream)));
            check_sector_in_cache(lba);
        end
    endtask

    task automatic test_miss_after_seek();
        realtime t;
        int n0;
        test = "test_miss_after_seek";
        n0 = host.log_q.size();
        request(500, 500, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(reads_between(t, t_stream) == 1, $sformatf("%0d host reads between the request and the stream", reads_between(t, t_stream)));
        check(was_read(n0, 500), "sector 500 not read");
        check_sector_in_cache(500);
        // The prefetch follows
        wait_quiet();
        for (int lba = 501; lba <= 503; lba++) check(was_read(n0, lba), $sformatf("sector %0d not prefetched", lba));
        check(!was_read(n0, 504), "more than three sectors prefetched");
    endtask

    task automatic test_audio_stream_to_cdda();
        realtime t;
        int c0 = cdda_wrs, w0 = data_wrs, bad = 0;
        logic [15:0] head [4];
        test = "test_audio_stream_to_cdda";
        request(AUDIO_LBA, AUDIO_LBA, 1, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(cdda_wrs == c0 + 1176, $sformatf("%0d CDDA_WR edges, 1176 expected", cdda_wrs - c0));
        check(data_wrs == w0, "the audio sector reached the data path");
        check(cdsystem.CDDA.FILLED_COUNT == 588, $sformatf("cdda.v holds %0d stereo samples", cdsystem.CDDA.FILLED_COUNT));
        for (int n = 0; n < 588; n++)
            if (cdsystem.CDDA.BUFFER[n] != {sample(n), sample(n)}) begin
                if (bad < 3) check(0, $sformatf("cdda sample %0d is %08x, expected %08x", n, cdsystem.CDDA.BUFFER[n], {sample(n), sample(n)}));
                bad++;
            end
        check(bad == 0, $sformatf("%0d samples wrong", bad));
    endtask

    task automatic test_fetch_error_reports_position();
        realtime t;
        int s0, n0;
        test = "test_fetch_error_reports_position";
        wait_quiet();           // so that err 1 goes to sector 300's read, not a prefetch
        host.fail_next = 1;
        s0 = streams;
        n0 = host.log_q.size();
        request(300, 300, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(fetch_err, "fetch_err not set");
        check(streams == s0, "a failed sector was streamed");
        check(host.log_q.size() > n0 && host.log_q[n0].err == 1 && host.log_q[n0].offset == 300 * SECTOR,
              "the host did not fail the read of sector 300");
        for (int k = 0; k < 4; k++)
            check(!(dut.valid[k] && dut.tag_lba[k] == 300), $sformatf("slot %0d holds sector 300 after err 1", k));
        // The same sector again: read, streamed, fetch_err cleared
        s0 = streams;
        n0 = host.log_q.size();
        request(300, 300, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(!fetch_err && streams == s0 + 1 && was_read(n0, 300), "sector 300 not delivered after the error");
        check_sector_in_cache(300);
        // A position below the disc: nothing read, nothing streamed
        wait_quiet();
        s0 = streams;
        n0 = host.log_q.size();
        request(-3, -3, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check(fetch_err && streams == s0, $sformatf("below the disc: fetch_err %0d, %0d streams", fetch_err, streams - s0));
        check(reads_between(t, $realtime) == 0, "a position below the disc was read");
    endtask

    task automatic test_disc_change_invalidates();
        realtime t;
        int n0;
        test = "test_disc_change_invalidates";
        // 301 was prefetched after 300
        check(dut.valid != 0, "the bank is empty before the change");
        @(posedge clk48) disc_present <= 0;
        repeat (4) @(posedge clk48);
        check(dut.valid == 0, $sformatf("slots %b still valid with no disc", dut.valid));
        @(posedge clk48) disc_present <= 1;
        n0 = host.log_q.size();
        request(301, 301, 0, t);
        wait_done();
        check(was_read(n0, 301), "sector 301 served from the bank of the old disc");
    endtask

    task automatic test_reset_abandons_stream();
        realtime t;
        logic done0;
        test = "test_reset_abandons_stream";
        request(17, 17, 0, t);
        @(posedge cd_dl_download);
        repeat (2000) @(posedge clk48);
        done0 = req_done;
        // The core's reset: cdd_drive mirrors req_valid <= req_done through it
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
        request(18, 18, 0, t);
        wait_done();
        repeat (40) @(posedge clk48);
        check_sector_in_cache(18);
    endtask

    // The longest host read and the requests that waited at the sink, as the bench sees them
    int f_run = 0, f_max = 0, sink_waits = 0;
    bit sink_d = 0;
    always @(posedge clk48) begin
        if (dut.fbusy) begin
            f_run++;
            if (f_run > f_max) f_max = f_run;
        end
        else f_run = 0;
        if (dut.state == dut.S_SINK && !(dut.cur_audio ? CDDA_WR_READY : CD_DATA_WR_READY) && !sink_d) sink_waits++;
        sink_d = dut.state == dut.S_SINK && !(dut.cur_audio ? CDDA_WR_READY : CD_DATA_WR_READY);
    end

    task automatic pulse_poll();
        tick();     // off the clock's edge, so that it is high for one edge
        poll = 1;
        tick();
        poll = 0;
    endtask

    // A request as cdd_drive's toggle, whatever the fetch is doing
    task automatic request_now(input int lba);
        req_lba      = 24'(lba);
        req_file     = 7'd1;
        req_file_lba = 24'(lba);
        req_audio    = 0;
        tick();
        req_valid = ~req_valid;
    endtask

    function automatic void counts(input logic [31:0] was [10], input int data, audio, hit, miss, busy, late, sink_poll, abandon, input string how);
        check(fc[0] - was[0] == 32'(data), $sformatf("%0s: %0d data sectors, want %0d", how, fc[0] - was[0], data));
        check(fc[1] - was[1] == 32'(audio), $sformatf("%0s: %0d audio sectors, want %0d", how, fc[1] - was[1], audio));
        check(fc[2] - was[2] == 32'(hit), $sformatf("%0s: %0d hits, want %0d", how, fc[2] - was[2], hit));
        check(fc[3] - was[3] == 32'(miss), $sformatf("%0s: %0d misses, want %0d", how, fc[3] - was[3], miss));
        check(fc[5] - was[5] == 32'(busy), $sformatf("%0s: %0d requests on a busy fetch, want %0d", how, fc[5] - was[5], busy));
        check(fc[6] - was[6] == 32'(late), $sformatf("%0s: %0d late polls, want %0d", how, fc[6] - was[6], late));
        check(fc[7] - was[7] == 32'(sink_poll), $sformatf("%0s: %0d polls at a full sink, want %0d", how, fc[7] - was[7], sink_poll));
        check(fc[9] - was[9] == 32'(abandon), $sformatf("%0s: %0d abandoned, want %0d", how, fc[9] - was[9], abandon));
    endfunction

    function automatic void snap(output logic [31:0] was [10]);
        for (int i = 0; i < 10; i++) was[i] = fc[i];
    endfunction

    task automatic test_debug_counts();
        realtime t;
        logic [31:0] was [10];
        int waits0;
        test = "test_debug_counts";
        wait_quiet();

        // A miss
        snap(was);
        request(300, 300, 0, t);
        wait_done();
        counts(was, 1, 0, 0, 1, 0, 0, 0, 0, "a miss");

        // The next, while its prefetch is at the host: on a busy fetch, and not yet in the bank
        snap(was);
        while (!dut.fbusy) tick();
        request_now(301);
        wait_done();
        counts(was, 1, 0, 0, 1, 1, 0, 0, 0, "on a prefetch");
        wait_quiet();

        // In the bank by now, whatever the sink says
        snap(was);
        request(302, 302, 0, t);
        wait_done();
        counts(was, 1, 0, 1, 0, 0, 0, 0, 0, "a hit");
        wait_quiet();

        // A poll with the last request unanswered is late; one with it answered and the sink free, nothing
        snap(was);
        while (!CD_DATA_WR_READY) tick();
        pulse_poll();
        counts(was, 0, 0, 0, 0, 0, 0, 0, 0, "a poll with nothing to say");
        request(303, 303, 0, t);
        tick();
        pulse_poll();
        check(req_valid != req_done, "the request is over before the poll");
        wait_done();
        counts(was, 1, 0, 1, 0, 0, 1, 0, 0, "a late poll");
        wait_quiet();

        // The sink full at a poll: a sector in each bank of the cache, the second waiting its sector time
        snap(was);
        request(304, 304, 0, t);
        wait_done();
        wait_quiet();
        check(!CD_DATA_WR_READY, "the sink has room: the poll below would prove nothing");
        pulse_poll();
        counts(was, 1, 0, 1, 0, 0, 0, 1, 0, "a poll at a full sink");

        // A request with the sink full, unlike the drive's: it waits at the sink, once however long
        waits0 = sink_waits;
        snap(was);
        request_now(305);
        wait_done();
        check(sink_waits - waits0 == 1, $sformatf("the bench saw %0d waits", sink_waits - waits0));
        check(fc[8] - was[8] == 32'(sink_waits - waits0), $sformatf("%0d waits at the sink, the bench saw %0d", fc[8] - was[8], sink_waits - waits0));
        wait_quiet();

        // Audio, and a position below the disc: asked for, neither a hit nor a miss
        snap(was);
        request(AUDIO_LBA + 40, AUDIO_LBA + 40, 1, t);
        wait_done();
        counts(was, 0, 1, 0, 1, 0, 0, 0, 0, "audio");
        wait_quiet();
        snap(was);
        request(-1, -1, 0, t);
        wait_done();
        check(fetch_err, "below the disc: no fetch_err");
        counts(was, 1, 0, 0, 0, 0, 0, 0, 0, "below the disc");

        // A reset in a stream
        snap(was);
        request(310, 310, 0, t);
        @(posedge cd_dl_download);
        repeat (100) @(posedge clk48);
        nRESET <= 0;
        repeat (20) begin
            tick();
            req_valid = req_done;
        end
        nRESET <= 1;
        repeat (20) @(posedge clk48);
        counts(was, 1, 0, 0, 1, 0, 0, 0, 1, "a reset in a stream");

        // The worst host read, as long as the bench saw one go
        repeat (10) @(posedge clk48);
        wait_quiet();
        check(fc[4] != 0 && int'(fc[4]) >= f_max - 1 && int'(fc[4]) <= f_max + 1, $sformatf("worst host read %0d clocks, the bench saw %0d", fc[4], f_max));
    endtask

    task automatic run(input string name);
        tests++;
        case (name)
            "test_stream_byte_order":            test_stream_byte_order();
            "test_prefetch_hits":                test_prefetch_hits();
            "test_miss_after_seek":              test_miss_after_seek();
            "test_audio_stream_to_cdda":         test_audio_stream_to_cdda();
            "test_fetch_error_reports_position": test_fetch_error_reports_position();
            "test_disc_change_invalidates":      test_disc_change_invalidates();
            "test_reset_abandons_stream":        test_reset_abandons_stream();
            "test_debug_counts":                 test_debug_counts();
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done at %0.1f ms, %0d failures so far", name, $realtime / 1.0e6, errors);
    endtask

    initial begin
        string files [] = '{DISC};
        host.slot_file[3] = DISC;
        fork host.serve_forever(files); join_none
        repeat (100) @(posedge clk48);
        nRESET <= 1;
        repeat (100) @(posedge clk48);
        run("test_stream_byte_order");
        run("test_prefetch_hits");
        run("test_miss_after_seek");
        run("test_audio_stream_to_cdda");
        run("test_fetch_error_reports_position");
        run("test_disc_change_invalidates");
        run("test_reset_abandons_stream");
        run("test_debug_counts");
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("cd_fetch: %0d tests passed", tests);
        $finish;
    end

    initial begin
        #(2.0e9);
        $fatal(1, "timeout");
    end
endmodule
