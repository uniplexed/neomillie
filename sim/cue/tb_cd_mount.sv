// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cd_mount against cd_host, core_bridge_cmd.v and host_bfm, on prepare.py's discs. Each case picks a file
// for slot 2, raises cd_mount_req with the old disc_size still there and gives the new one 300 clocks later,
// as apf_loader does a table sweep after the request, then waits for disc_loading to fall and compares
// disc_present, track_count, disc_end and every TOC RAM entry (read at CLK_48M) with the hand-written golden
// file. For a CUE that mounts, the openfile of slot 3 must have named the BIN beside the CUE and answered 0.
//
// test_raw_bin_single_track            a MODE1/2352 BIN picked directly
// test_cue_single_bin                  data and two audio tracks in one BIN, INDEX 00 pregaps
// test_cue_crlf_and_quoted_spaces      CR LF, a BIN named "Test Disc 'X', 1.bin" in "crlf 'X', 1/"
// test_cue_pregap_keyword              PREGAP, which is on the disc and not in the BIN
// test_cue_malformed_lines_skipped     other keywords, junk, INDEX 02, malformed INDEX and PREGAP lines
// test_sniff_iso2048_reports_no_disc   a 2,048-byte-sector image: no sync, not text
// test_cue_mode1_2048_reports_no_disc  TRACK 01 MODE1/2048
// test_cue_too_long_reports_no_disc    9,409 bytes; and 9,408, the bank's size, mounts
// test_cue_missing_bin_reports_no_disc the BIN is not on the card: openfile err 3, the mount completes
// test_cue_two_files_reports_no_disc   two FILE lines
// test_disc_end_from_size_probe        the last track's end from the probe of a 324-sector BIN, at most
//                                      22 reads, under a second at the real host latency; disc_bin_size unused
// test_converted_disc                  tools/cd_convert.py's output
// test_repick_during_mount             cd_mount_req on the clock a command goes out: the new disc, no hang
`include "cd_defs.svh"
`timescale 1ns/1ps
module tb_cd_mount;
    import cd_defs::*;
    import host_bfm_pkg::*;

    localparam real PERIOD_74 = 13.468;
    localparam real PERIOD_48 = 20.689;
    localparam string COMMON = "/Assets/ngcd/common/";

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

    // ---- cd_host and the DUT ----
    wire        mr_req, mr_done, path_wr;
    wire  [1:0] mr_kind, mr_bank_slot;
    wire [15:0] mr_slot;
    wire [31:0] mr_offset, mr_len, path_wdata, path_q, bank_rd_q_74;
    wire  [2:0] mr_err;
    wire  [7:0] path_addr;
    wire [11:0] bank_rd_addr_74;

    cd_host chost (
        .clk_74a(clk74), .CLK_48M(clk48), .rst(1'b0),
        .target_dataslot_read(t_read), .target_dataslot_getfile(t_getfile), .target_dataslot_openfile(t_openfile),
        .target_dataslot_write(t_write),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_addr), .target_dataslot_length(t_len),
        .target_buffer_param_struct(param_struct), .target_buffer_resp_struct(resp_struct),
        .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data(host_rd_data),
        .mr_req, .mr_kind, .mr_slot, .mr_offset, .mr_len, .mr_bank_slot, .mr_done, .mr_err,
        .fr_req(1'b0), .fr_slot(16'd0), .fr_offset(32'd0), .fr_bank_slot(2'd0), .fr_done(), .fr_err(),
        .bank_rd_addr(12'd0), .bank_rd_q(), .bank_rd_addr_74, .bank_rd_q_74,
        .path_addr, .path_wr, .path_wdata, .path_q
    );

    logic        mount_req = 0;
    logic [31:0] disc_size = 0;
    logic  [6:0] toc_rd_track = 0;
    wire         disc_loading, disc_present;
    wire   [6:0] track_count;
    wire  [23:0] disc_end;
    toc_entry_t  toc_rd_entry;

    cd_mount dut (
        .clk_74a(clk74), .rst(1'b0),
        .mount_req, .disc_size, .disc_bin_size(32'hDEAD_BEEF),     // never used for the size: stale in the loader
        .mr_req, .mr_kind, .mr_slot, .mr_offset, .mr_len, .mr_bank_slot, .mr_done, .mr_err,
        .path_addr, .path_wr, .path_wdata, .path_q,
        .bank_rd_addr_74, .bank_rd_q_74,
        .disc_loading, .disc_present, .track_count, .disc_end,
        .CLK_48M(clk48), .toc_rd_track, .toc_rd_entry
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

    function automatic longint size_of(input string card);
        int fd = $fopen(card.substr(1, card.len() - 1), "rb");
        longint n;
        if (fd == 0) $fatal(1, "%s: no file %s", test, card);
        void'($fseek(fd, 0, 2));
        n = $ftell(fd);
        $fclose(fd);
        return n;
    endfunction

    function automatic string dir_of(input string p);
        for (int i = p.len() - 1; i >= 0; i--) if (p[i] == "/") return p.substr(0, i);
        return "";
    endfunction

    // Pick a file and mount it; returns the commands the host served for it
    task automatic mount(input string card, input real limit_ms, output int first_cmd, output realtime took);
        realtime t0, limit;
        host.slot_file[2] = card;
        first_cmd = host.log_q.size();
        @(posedge clk74);
        mount_req <= 1;
        t0 = $realtime;
        @(posedge clk74);
        mount_req <= 0;
        @(posedge clk74);
        check(disc_loading && !disc_present, $sformatf("after cd_mount_req: disc_loading %0d, disc_present %0d", disc_loading, disc_present));
        repeat (300) @(posedge clk74);
        disc_size <= 32'(size_of(card));
        limit = t0 + limit_ms * 1.0e6;
        while (disc_loading && $realtime < limit) @(posedge clk74);
        took = $realtime - t0;
        check(!disc_loading, $sformatf("%0s: still loading after %0.0f ms", card, limit_ms));
    endtask

    task automatic read_toc(input int t, output toc_entry_t e);
        @(posedge clk48);
        toc_rd_track <= 7'(t);
        @(posedge clk48);
        @(posedge clk48);
        e = toc_rd_entry;
    endtask

    task automatic compare_golden(input string golden);
        int fd = $fopen({"golden/", golden}, "r");
        string line;
        int v, n = 0;
        int present = -1, tracks = -1, dend = -1;
        if (fd == 0) $fatal(1, "no golden/%s", golden);
        while ($fgets(line, fd)) begin
            int a, f, s, e, l, t;
            if (line.len() == 0 || line[0] == "#") continue;
            if ($sscanf(line, "present %d", v) == 1) present = v;
            else if ($sscanf(line, "tracks %d", v) == 1) tracks = v;
            else if ($sscanf(line, "end %d", v) == 1) dend = v;
            else if ($sscanf(line, "%d %d %d %d %d %d", t, a, f, s, e, l) == 6) begin
                toc_entry_t got;
                read_toc(t, got);
                check(got.audio == a[0] && got.file == 7'(f) && got.start == 24'(s) && got.stop == 24'(e) && got.file_lba == 24'(l),
                      $sformatf("%0s track %0d: audio %0d file %0d start %0d stop %0d file_lba %0d, golden %0d %0d %0d %0d %0d",
                                golden, t, got.audio, got.file, got.start, got.stop, got.file_lba, a, f, s, e, l));
                n++;
            end
        end
        $fclose(fd);
        check(present >= 0 && disc_present == present[0], $sformatf("disc_present %0d, golden %0d", disc_present, present));
        check(track_count == 7'(tracks), $sformatf("track_count %0d, golden %0d", track_count, tracks));
        check(disc_end == 24'(dend), $sformatf("disc_end %0d, golden %0d", disc_end, dend));
        check(n == tracks, $sformatf("%0d entries in golden/%0s for %0d tracks", n, golden, tracks));
    endtask

    // The openfile of slot 3 named the BIN beside the CUE, and answered 0
    task automatic check_openfile(input int first, input string cue_card, input string bin, input int want_err = 0);
        int found = 0;
        for (int i = first; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0192) begin
                found++;
                check(host.log_q[i].id == 3, $sformatf("openfile of slot %0d", host.log_q[i].id));
                check(host.log_q[i].path == {dir_of(cue_card), bin}, $sformatf("openfile of \"%0s\", expected \"%0s\"",
                                                                              host.log_q[i].path, {dir_of(cue_card), bin}));
                check(host.log_q[i].err == want_err, $sformatf("openfile answered err %0d", host.log_q[i].err));
            end
        check(found == 1, $sformatf("%0d openfiles", found));
    endtask

    function automatic int count_cmds(input int first, input logic [15:0] cmd);
        int n = 0;
        for (int i = first; i < host.log_q.size(); i++) if (host.log_q[i].cmd == cmd) n++;
        return n;
    endfunction

    // ---- Tests ----
    task automatic case_cue(input string name, input string card, input string bin, input string golden);
        int first;
        realtime took;
        test = name;
        mount(card, 100.0, first, took);
        compare_golden(golden);
        check_openfile(first, card, bin);
    endtask

    // reason: why cd_mount says there is no disc (its reason_t), so that a no disc for another cause fails
    task automatic case_no_disc(input string name, input string card, input int reason);
        int first;
        realtime took;
        test = name;
        mount(card, 100.0, first, took);
        compare_golden("nodisc.toc");
        check(int'(dut.reason) == reason, $sformatf("no disc for reason %0d, expected %0d", dut.reason, reason));
    endtask

    task automatic test_raw_bin_single_track();
        int first;
        realtime took;
        test = "test_raw_bin_single_track";
        mount({COMMON, "raw/disc.bin"}, 100.0, first, took);
        compare_golden("raw.toc");
        check(count_cmds(first, 16'h0192) == 0 && count_cmds(first, 16'h0190) == 0, "a raw BIN asked for getfile or openfile");
    endtask

    task automatic test_cue_too_long_reports_no_disc();
        int first;
        realtime took;
        test = "test_cue_too_long_reports_no_disc";
        mount({COMMON, "long/long.cue"}, 100.0, first, took);
        compare_golden("nodisc.toc");
        check(dut.reason == dut.R_TOO_LONG, $sformatf("no disc for reason %0d", dut.reason));
        check(count_cmds(first, 16'h0192) == 0 && count_cmds(first, 16'h0180) <= 1, "a CUE too long was read past its first piece");
        // The bank's size exactly, track 3 in the last piece
        case_cue("test_cue_too_long_reports_no_disc", {COMMON, "long/fits.cue"}, "disc.bin", "single.toc");
    endtask

    task automatic test_cue_missing_bin_reports_no_disc();
        int first;
        realtime took;
        test = "test_cue_missing_bin_reports_no_disc";
        mount({COMMON, "missing/disc.cue"}, 100.0, first, took);
        compare_golden("nodisc.toc");
        check(dut.reason == dut.R_OPEN, $sformatf("no disc for reason %0d", dut.reason));
        check_openfile(first, {COMMON, "missing/disc.cue"}, "missing.bin", 3);
    endtask

    task automatic test_disc_end_from_size_probe();
        int first, reads;
        realtime took;
        test = "test_disc_end_from_size_probe";
        host.latency_clks = 74250;      // the 1 ms the plan takes for the host
        mount({COMMON, "probe/disc.cue"}, 1000.0, first, took);
        host.latency_clks = 2000;
        compare_golden("probe.toc");
        reads = 0;
        for (int i = first; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].id == 3) reads++;
        check(reads <= 22, $sformatf("%0d probe reads of slot 3", reads));
        check(took < 1.0e9, $sformatf("the mount took %0.1f ms", took / 1.0e6));
        $display("probe: %0d reads of the BIN, mount done in %0.1f ms at 1 ms of host latency", reads, took / 1.0e6);
    endtask

    // A disc picked again on the clock cd_mount raises mr_req for a probe read of the old one: the new mount
    // must start only after that command is answered, and come out as the new disc
    task automatic test_repick_during_mount();
        realtime limit;
        test = "test_repick_during_mount";
        host.slot_file[2] = {COMMON, "probe/disc.cue"};
        @(posedge clk74) mount_req <= 1;
        @(posedge clk74) mount_req <= 0;
        repeat (300) @(posedge clk74);
        disc_size <= 32'(size_of({COMMON, "probe/disc.cue"}));
        // The clock M_ISSUE raises mr_req for a read of slot 3
        do @(negedge clk74); while (!(dut.state == dut.M_ISSUE && dut.mr_slot == 3 && dut.mr_kind == 0 && !mr_done));
        host.slot_file[2] = {COMMON, "pregap/pregap.cue"};
        mount_req = 1;
        @(negedge clk74) mount_req = 0;
        repeat (300) @(posedge clk74);
        disc_size <= 32'(size_of({COMMON, "pregap/pregap.cue"}));
        limit = $realtime + 200.0e6;
        while (disc_loading && $realtime < limit) @(posedge clk74);
        check(!disc_loading, "still loading 200 ms after the second pick");
        compare_golden("pregap.toc");
    endtask

    task automatic run(input string name);
        tests++;
        case (name)
            "test_raw_bin_single_track":            test_raw_bin_single_track();
            "test_cue_single_bin":                  case_cue(name, {COMMON, "single/disc.cue"}, "disc.bin", "single.toc");
            "test_cue_crlf_and_quoted_spaces":      case_cue(name, {COMMON, "crlf 'X', 1/disc.cue"}, "Test Disc 'X', 1.bin", "single.toc");
            "test_cue_pregap_keyword":              case_cue(name, {COMMON, "pregap/pregap.cue"}, "gapless.bin", "pregap.toc");
            "test_cue_malformed_lines_skipped":     case_cue(name, {COMMON, "malformed/malformed.cue"}, "disc.bin", "single.toc");
            "test_sniff_iso2048_reports_no_disc":   case_no_disc(name, {COMMON, "iso/disc.iso"}, dut.R_NOT_CUE);
            "test_cue_mode1_2048_reports_no_disc":  case_no_disc(name, {COMMON, "mode1_2048/m2048.cue"}, dut.R_TRACK);
            "test_cue_too_long_reports_no_disc":    test_cue_too_long_reports_no_disc();
            "test_cue_missing_bin_reports_no_disc": test_cue_missing_bin_reports_no_disc();
            "test_cue_two_files_reports_no_disc":   case_no_disc(name, {COMMON, "two_files/two.cue"}, dut.R_FILES);
            "test_disc_end_from_size_probe":        test_disc_end_from_size_probe();
            "test_converted_disc":                  case_cue(name, {COMMON, "conv/conv/conv.cue"}, "conv.bin", "converted.toc");
            "test_repick_during_mount":             test_repick_during_mount();
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done, %0d failures so far", name, errors);
    endtask

    initial begin
        string files [] = '{"",
            {COMMON, "single/disc.bin"}, {COMMON, "crlf 'X', 1/Test Disc 'X', 1.bin"}, {COMMON, "pregap/gapless.bin"},
            {COMMON, "malformed/disc.bin"}, {COMMON, "mode1_2048/disc.bin"}, {COMMON, "long/disc.bin"},
            {COMMON, "two_files/disc.bin"}, {COMMON, "two_files/gapless.bin"}, {COMMON, "probe/disc.bin"},
            {COMMON, "conv/conv/conv.bin"}};
        fork host.serve_forever(files); join_none
        repeat (100) @(posedge clk74);
        run("test_raw_bin_single_track");
        run("test_cue_single_bin");
        run("test_cue_crlf_and_quoted_spaces");
        run("test_cue_pregap_keyword");
        run("test_cue_malformed_lines_skipped");
        run("test_sniff_iso2048_reports_no_disc");
        run("test_cue_mode1_2048_reports_no_disc");
        run("test_cue_too_long_reports_no_disc");
        run("test_cue_missing_bin_reports_no_disc");
        run("test_cue_two_files_reports_no_disc");
        run("test_disc_end_from_size_probe");
        run("test_converted_disc");
        run("test_repick_during_mount");
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("cue: %0d tests passed", tests);
        $finish;
    end

    initial begin
        #(3.0e9);
        $fatal(1, "timeout");
    end
endmodule
