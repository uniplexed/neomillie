// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cdd_drive against MiSTer's megacdd.cpp: prepare.py runs the C++ on commands.txt into golden.txt, and this
// runs the RTL on the same lines.
//
// test_golden_trace   every line's status word, latency, isData, status and sector requests, line by line.
//                     The RTL has no length: a golden audio send of 4,704 bytes, MiSTer's first after a seek,
//                     is one request here, on purpose (Task 14)
// test_status_crc     100 random stat arrays, the check nibble against the formula
// test_no_lock        a request never answered and a sink never ready stop the position, not the commands
// test_tray           disc_loading reported as TRAY, lid_open as OPEN, and what follows them
`include "cd_defs.svh"
`timescale 1ns/1ps
module tb_cdd_drive;
    import cd_defs::*;

    localparam int SETTLE = 1100;       // CLK_48M per line, more than the farthest seek here takes
    localparam int REQ_CLKS = 10;

    logic clk = 0;
    always #10 clk = ~clk;

    logic        nRESET = 0, tick = 0, cmd_send = 0, lid_open = 0, disc_present = 0, disc_loading = 0, sink_ready = 1;
    logic [39:0] cmd_data = 0;
    logic  [6:0] track_count = 0;
    logic [23:0] disc_end = 0;
    wire  [39:0] status_word;
    wire         status_latch, status_play, is_data, req_audio, req_valid;
    wire   [6:0] toc_rd_track, req_file;
    wire  [23:0] req_lba, req_file_lba, cur_lba;
    wire   [3:0] cur_status;
    logic        req_done = 0;

    // The TOC RAM, with junk past the last track: what a TOC holds there is the drive's to answer
    toc_entry_t toc [128];
    toc_entry_t toc_q;
    always @(posedge clk) toc_q <= toc[toc_rd_track];

    cdd_drive dut (
        .clk, .nRESET, .tick,
        .CDD_COMMAND_DATA(cmd_data), .CDD_COMMAND_SEND(cmd_send),
        .CDD_STATUS(status_word), .CDD_STATUS_LATCH(status_latch),
        .CD_SPEED(2'd0), .lid_open, .disc_present, .disc_loading, .track_count, .disc_end,
        .toc_rd_track, .toc_rd_entry(toc_q),
        .req_lba, .req_audio, .req_file, .req_file_lba, .req_valid, .req_done, .sink_ready,
        .status_play, .is_data, .cur_lba, .cur_status
    );

    int errors = 0, tests = 0;
    string test = "";
    function automatic void fail(input string msg);
        errors++;
        if (errors <= 20) $display("%0s: %0s", test, msg);
    endfunction

    // req_done answers REQ_CLKS after each request, unless the test holds it. Every request goes in a queue
    bit answer = 1;
    typedef struct { int index; int lba; logic [6:0] file; logic [23:0] file_lba; } send_t;
    send_t sends [$];
    bit req_valid_d = 0;
    int req_cnt = 0;
    int latches = 0;
    always @(posedge clk) begin
        req_valid_d <= req_valid;
        if (req_valid != req_valid_d) begin
            sends.push_back(send_t'{req_audio ? 4 : 2, int'($signed(req_lba)), req_file, req_file_lba});
            req_cnt <= REQ_CLKS;
        end
        else if (req_cnt != 0) begin
            req_cnt <= req_cnt - 1;
            if (req_cnt == 1 && answer) req_done <= ~req_done;
        end
        if (status_latch) latches <= latches + 1;
    end

    task automatic wait_clks(input int n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    task automatic pulse_tick();
        tick = 1;
        wait_clks(1);
        tick = 0;
        wait_clks(SETTLE);
    endtask

    task automatic send_cmd(input logic [39:0] word);
        int had = latches;
        cmd_data = word;
        cmd_send = 1;
        wait_clks(1);
        cmd_send = 0;
        wait_clks(SETTLE);
        if (latches != had + 1) fail($sformatf("cmd %010x: %0d status latches", word, latches - had));
    endtask

    task automatic core_reset();
        int had = latches;
        nRESET = 0;
        wait_clks(4);
        nRESET = 1;
        wait_clks(SETTLE);
        if (latches != had + 1) fail($sformatf("core reset: %0d status latches", latches - had));
    endtask

    // As cd_mount: tray busy, the TOC written, disc_present, then not busy
    task automatic set_disc(input int n);
        disc_loading = 1;
        disc_present = 0;
        wait_clks(4);
        for (int i = 0; i < 128; i++) toc[i] = toc_entry_t'({$urandom, $urandom, $urandom});
        track_count = 0;
        disc_end = 0;
        if (n == 1) begin
            toc[0] = toc_entry_t'{1'b0, 7'd0, 24'd0, 24'd1000, 24'd0};
            toc[1] = toc_entry_t'{1'b1, 7'd1, 24'd1000, 24'd2000, 24'd7};
            toc[2] = toc_entry_t'{1'b1, 7'd2, 24'd2000, 24'd3000, 24'd300};
            track_count = 3;
            disc_end = 3000;
        end
        else if (n == 2) begin
            toc[0] = toc_entry_t'{1'b0, 7'd0, 24'd0, 24'd500, 24'd0};
            track_count = 1;
            disc_end = 500;
        end
        else if (n == 3) begin
            toc[0] = toc_entry_t'{1'b0, 7'd0, 24'd0, 24'd1000, 24'd0};
            toc[1] = toc_entry_t'{1'b1, 7'd1, 24'd1150, 24'd2000, 24'd7};
            track_count = 2;
            disc_end = 2000;
        end
        else if (n == 4) begin
            toc[0] = toc_entry_t'{1'b0, 7'd0, 24'd0, 24'd1000, 24'd0};
            for (int i = 1; i < 12; i++) toc[i] = toc_entry_t'{1'b1, 7'(i), 24'(1000 + (i - 1) * 40), 24'(1000 + i * 40), 24'(i * 3)};
            track_count = 12;
            disc_end = 1440;
        end
        disc_present = n != 0;
        wait_clks(4);
        disc_loading = 0;
        wait_clks(4);
    endtask

    task automatic test_golden_trace();
        int cf, gf, line = 0, gline = 0, lines = 0, n_send = 0, n_long = 0;
        string s, g;
        test = "test_golden_trace";
        cf = $fopen("commands.txt", "r");
        gf = $fopen("golden.txt", "r");
        if (cf == 0 || gf == 0) $fatal(1, "commands.txt or golden.txt is not in the run directory");
        while ($fgets(s, cf) != 0) begin
            logic [39:0] word;
            logic [39:0] g_word;
            int disc, g_lat, g_data, g_stat, g_index, g_len, g_lba;
            line++;
            if (s.len() == 0 || s[0] == "#" || s[0] == "\n" || s[0] == "\r") continue;
            if ($sscanf(s, "disc %d", disc) == 1) begin
                set_disc(disc);
                continue;
            end
            sends.delete();
            if ($sscanf(s, "cmd %h", word) == 1) send_cmd(word);
            else if (s.substr(0, 3) == "tick") pulse_tick();
            else if (s.substr(0, 4) == "reset") core_reset();
            else $fatal(1, "commands.txt line %0d: %0s", line, s);
            lines++;
            // This line's sends, then its state
            forever begin
                if ($fgets(g, gf) == 0) $fatal(1, "golden.txt ends at commands.txt line %0d", line);
                gline++;
                if ($sscanf(g, "send %d %d %d", g_index, g_len, g_lba) != 3) break;
                n_send++;
                if (g_len == 4704) n_long++;
                if (g_len != 2352 && !(g_index == 4 && g_len == 4704)) fail($sformatf("golden line %0d: send of %0d bytes", gline, g_len));
                if (sends.size() == 0)
                    fail($sformatf("commands.txt line %0d: golden sends %0d at %0d, the RTL requests nothing", line, g_index, g_lba));
                else begin
                    send_t r = sends.pop_front();
                    // cdd_t has one file here. The file and its LBA are this bench's TOC against the formula
                    int t = 0;
                    while (t < int'(track_count) - 1 && g_lba >= int'(toc[t].stop)) t++;
                    if (r.index != g_index || r.lba != g_lba || r.file != 7'(t) || r.file_lba != toc[t].file_lba + 24'(g_lba) - toc[t].start)
                        fail($sformatf("commands.txt line %0d: golden sends %0d at %0d, the RTL %0d at %0d, file %0d lba %0d", line, g_index, g_lba,
                                       r.index, r.lba, r.file, r.file_lba));
                end
            end
            if (sends.size() != 0)
                fail($sformatf("commands.txt line %0d: %0d requests the golden trace does not send, the first at %0d", line, sends.size(), sends[0].lba));
            if ($sscanf(g, "%h %d %d %h", g_word, g_lat, g_data, g_stat) != 4) $fatal(1, "golden line %0d: %0s", gline, g);
            if (status_word != g_word || int'(dut.latency) != g_lat || int'(is_data) != g_data || int'(cur_status) != g_stat)
                fail($sformatf("commands.txt line %0d (%0s), golden line %0d: golden %010x latency %0d isData %0d status %0x, RTL %010x latency %0d isData %0d status %0x",
                               line, s.substr(0, s.len() - 2), gline, g_word, g_lat, g_data, g_stat, status_word, dut.latency, is_data, cur_status));
        end
        if ($fgets(g, gf) != 0) fail("golden.txt goes on after commands.txt");
        $fclose(cf);
        $fclose(gf);
        $display("golden trace: %0d lines, %0d sends (%0d of them MiSTer's 4,704 bytes), %0d diverging", lines, n_send, n_long, errors);
    endtask

    task automatic test_status_crc();
        test = "test_status_crc";
        repeat (100) begin
            logic [35:0] st = {$urandom, $urandom};
            logic [ 3:0] s0 = $urandom;
            logic [39:0] w;
            int sum;
            @(negedge clk);
            dut.stat = st;
            dut.status = s0;
            send_cmd(40'h000000000E);   // no such command: stat[0] = status, the rest as they are
            st[3:0] = s0;
            sum = int'(CRC_START);
            for (int i = 0; i < 9; i++) sum += int'(st[4 * i +: 4]);
            w = {4'(~sum), st};
            if (status_word != w) fail($sformatf("stat %09x: %010x, expected %010x", st, status_word, w));
        end
    endtask

    task automatic test_no_lock();
        test = "test_no_lock";
        core_reset();
        set_disc(1);
        send_cmd(40'h0000000000);
        send_cmd(40'h0061200003);   // PLAY 00:02:16, the check nibble is not looked at
        repeat (40) pulse_tick();
        if (cur_status != CD_STAT_PLAY || !status_play) fail("no PLAY with no latency left");

        // One request sent and never answered
        answer = 0;
        wait_clks(REQ_CLKS * 2);
        pulse_tick();
        begin
            logic [23:0] held = cur_lba;
            repeat (5) pulse_tick();
            if (cur_lba != held) fail($sformatf("lba moved from %0d to %0d with a request in flight", held, cur_lba));
            send_cmd(40'h0000002002);   // TOC 2 answers
            if (status_word[3:0] != CD_STAT_PLAY || status_word[7:4] != 2) fail($sformatf("no answer in flight: %010x", status_word));
            send_cmd(40'h0000000001);   // STOP answers
            if (cur_status != CD_STAT_STOP) fail("STOP not taken with a request in flight");
        end
        answer = 1;
        req_done = req_valid;
        wait_clks(4);

        // The sink not ready: no request, no move, as CanSendData
        send_cmd(40'h0000000007);       // RESUME
        sink_ready = 0;
        begin
            logic [23:0] held = cur_lba;
            sends.delete();
            repeat (5) pulse_tick();
            if (cur_lba != held || sends.size() != 0) fail("the position moved with the sink not ready");
            send_cmd(40'h0000000006);   // PAUSE answers
            if (cur_status != CD_STAT_PAUSE) fail("PAUSE not taken with the sink not ready");
        end
        sink_ready = 1;
    endtask

    task automatic test_tray();
        test = "test_tray";
        core_reset();
        set_disc(1);
        send_cmd(40'h0000000000);
        repeat (12) pulse_tick();
        disc_loading = 1;
        wait_clks(4);
        if (cur_status != CD_STAT_TRAY) fail($sformatf("disc_loading: status %0x", cur_status));
        send_cmd(40'h0000000000);
        if (status_word[3:0] != CD_STAT_TRAY) fail($sformatf("disc_loading: answer %010x", status_word));
        disc_loading = 0;
        wait_clks(4);
        if (cur_status != CD_STAT_STOP || dut.latency != 10) fail($sformatf("after the load: status %0x, latency %0d", cur_status, dut.latency));

        lid_open = 1;
        wait_clks(4);
        if (cur_status != CD_STAT_OPEN) fail($sformatf("lid_open: status %0x", cur_status));
        send_cmd(40'h000000000C);       // TRAY_CLOSE does not close a forced lid
        if (cur_status != CD_STAT_OPEN) fail($sformatf("lid_open, TRAY_CLOSE: status %0x", cur_status));
        lid_open = 0;
        wait_clks(4);
        if (cur_status != CD_STAT_STOP) fail($sformatf("lid closed with a disc: status %0x", cur_status));
    endtask

    task automatic run(input string name);
        tests++;
        case (name)
            "test_golden_trace": test_golden_trace();
            "test_status_crc":   test_status_crc();
            "test_no_lock":      test_no_lock();
            "test_tray":         test_tray();
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done, %0d failures so far", name, errors);
    endtask

    initial begin
        wait_clks(4);
        run("test_golden_trace");
        run("test_status_crc");
        run("test_no_lock");
        run("test_tray");
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("cdd: %0d tests passed", tests);
        $finish;
    end

    initial begin
        #(1.0e9);
        $fatal(1, "timeout");
    end
endmodule
