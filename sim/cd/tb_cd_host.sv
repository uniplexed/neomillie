// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cd_host against core_bridge_cmd.v and host_bfm, which answers through the bridge only, at its rate.
// The files are prepare.py's.
//
// test_read_lands_in_bank_slot          a mount read of 2,352 bytes into bank slot 2: every word, on both
//                                       read ports, is the file's bytes {b0, b1, b2, b3}; slots 1 and 3 untouched
// test_fetch_before_mount_read          a fetch and a mount read both pending: the fetch first
// test_openfile_not_split               a mount openfile and a fetch both pending: the openfile first, and a
//                                       fetch arriving during an openfile waits for it; err 3 for an unknown name
// test_fetch_error_leaves_slot_invalid  err 1 (fail_next) and err 2 (past the file): fr_err with fr_done, the
//                                       slot's words unchanged; the next fetch clears fr_err
// test_getfile_response_path            the slot's path, with spaces, ' and ',', read back on the path port
// test_wait_slot_write                  the wait counter's save, one write of id 0x103 per rising edge of a level
//                                       held high, after the openfile in flight, with its 4,096 bytes
`timescale 1ns/1ps
module tb_cd_host;

    localparam real PERIOD_74 = 13.468;
    localparam real PERIOD_48 = 20.689;
    localparam int  SECTOR = 2352, WORDS = 588;
    localparam string PATTERN = "/Assets/ngcd/common/t/pattern.bin";
    localparam string OTHER   = "/Assets/ngcd/common/t/other.bin";

    logic clk74 = 0, clk48 = 0;
    always #(PERIOD_74 / 2) clk74 = ~clk74;
    always #(PERIOD_48 / 2) clk48 = ~clk48;

    // ---- Bridge ----
    wire [31:0] bridge_addr, bridge_wr_data, cmd_rd_data, host_rd_data;
    wire        bridge_wr, bridge_rd;
    // What the wait counter's copy would answer at 0x8, a word that says where it is, loaded on the strobe
    // as wait_counter.sv does
    logic [31:0] wait_rd_data = 0;
    always @(posedge clk74) if (bridge_rd) wait_rd_data <= 32'h5A00_0000 | {21'd0, bridge_addr[12:2]};
    wire [31:0] bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_rd_data :
                                 bridge_addr[31:24] == 8'h71 ? host_rd_data :
                                 bridge_addr[31:28] == 4'h8  ? wait_rd_data : 32'h0;

    host_bfm #(.POLL_CLKS(200), .LATENCY_CLKS(2000)) host (
        .clk(clk74), .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data);

    // ---- core_bridge_cmd.v, as core_top.v has it ----
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

    // ---- DUT ----
    logic        mr_req = 0, fr_req = 0, ws_req = 0, path_wr = 0;
    logic  [1:0] mr_kind = 0, mr_bank_slot = 0, fr_bank_slot = 0;
    logic [15:0] mr_slot = 0, fr_slot = 0;
    logic [31:0] mr_offset = 0, mr_len = 0, fr_offset = 0, path_wdata = 0;
    logic [11:0] bank_rd_addr = 0, bank_rd_addr_74 = 0;
    logic  [7:0] path_addr = 0;
    wire         mr_done, fr_done, fr_err, ws_done;
    wire   [2:0] mr_err, ws_err;
    wire  [31:0] bank_rd_q, bank_rd_q_74, path_q;

    cd_host dut (
        .clk_74a(clk74), .CLK_48M(clk48), .rst(1'b0),
        .target_dataslot_read(t_read), .target_dataslot_getfile(t_getfile), .target_dataslot_openfile(t_openfile),
        .target_dataslot_write(t_write),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_addr), .target_dataslot_length(t_len),
        .target_buffer_param_struct(param_struct), .target_buffer_resp_struct(resp_struct),
        .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data(host_rd_data),
        .mr_req, .mr_kind, .mr_slot, .mr_offset, .mr_len, .mr_bank_slot, .mr_done, .mr_err,
        .fr_req, .fr_slot, .fr_offset, .fr_bank_slot, .fr_done, .fr_err,
        .ws_req, .ws_done, .ws_err,
        .bank_rd_addr, .bank_rd_q, .bank_rd_addr_74, .bank_rd_q_74,
        .path_addr, .path_wr, .path_wdata, .path_q
    );

    // ---- Checks ----
    int errors = 0, tests = 0;
    string test = "";
    function automatic void check(input bit ok, input string msg);
        if (!ok) begin
            errors++;
            if (errors <= 30) $display("%0s: %0s", test, msg);
        end
    endfunction

    function automatic logic [7:0] pattern(input int i);
        return 8'(i * 13 + (i >> 8) * 7 + (i >> 16) * 3 + 1);
    endfunction

    function automatic logic [31:0] file_word(input string f, input int offset, input int w);
        logic [7:0] b [4];
        for (int k = 0; k < 4; k++) b[k] = pattern(offset + 4 * w + k) ^ (f == OTHER ? 8'hA5 : 8'h00);
        return {b[0], b[1], b[2], b[3]};
    endfunction

    // ---- Clients ----
    task automatic mount_start(input logic [1:0] kind, input logic [15:0] slot, input int offset, input int len,
                               input logic [1:0] bank);
        @(posedge clk74);
        mr_kind <= kind;
        mr_slot <= slot;
        mr_offset <= offset;
        mr_len <= len;
        mr_bank_slot <= bank;
        mr_req <= 1;
    endtask

    task automatic mount_wait(output logic [2:0] err);
        do @(posedge clk74); while (!mr_done);
        err = mr_err;
        mr_req <= 0;
        do @(posedge clk74); while (mr_done);
    endtask

    task automatic mount_cmd(input logic [1:0] kind, input logic [15:0] slot, input int offset, input int len,
                             input logic [1:0] bank, output logic [2:0] err);
        mount_start(kind, slot, offset, len, bank);
        mount_wait(err);
    endtask

    task automatic fetch_start(input logic [15:0] slot, input int offset, input logic [1:0] bank);
        @(posedge clk48);
        fr_slot <= slot;
        fr_offset <= offset;
        fr_bank_slot <= bank;
        @(posedge clk48);
        fr_req <= ~fr_req;
    endtask

    task automatic fetch_wait(output logic err);
        do @(posedge clk48); while (fr_done != fr_req);
        err = fr_err;
    endtask

    // A host command is in flight: busy written, done not yet
    task automatic wait_host_busy();
        do @(posedge clk74); while (icb.target_0[31:16] != 16'h6275);
    endtask

    // The words of a bank slot through port B (CLK_48M) and port A (clk_74a)
    task automatic read_slot(input int slot, output logic [31:0] q [WORDS], output logic [31:0] q74 [WORDS]);
        for (int w = 0; w < WORDS; w++) begin
            @(posedge clk48);
            bank_rd_addr <= 12'(slot * WORDS + w);
            @(posedge clk48);
            @(posedge clk48);
            q[w] = bank_rd_q;
            @(posedge clk74);
            bank_rd_addr_74 <= 12'(slot * WORDS + w);
            @(posedge clk74);
            @(posedge clk74);
            q74[w] = bank_rd_q_74;
        end
    endtask

    task automatic check_slot(input int slot, input string f, input int offset, input string what);
        logic [31:0] q [WORDS], q74 [WORDS];
        int bad = 0;
        read_slot(slot, q, q74);
        for (int w = 0; w < WORDS; w++) begin
            automatic logic [31:0] want = file_word(f, offset, w);
            if (q[w] !== want || q74[w] !== want) begin
                if (bad < 3) check(0, $sformatf("%0s: slot %0d word %0d is %08x / %08x on ports B / A, expected %08x",
                                                what, slot, w, q[w], q74[w], want));
                bad++;
            end
        end
        check(bad == 0, $sformatf("%0s: %0d words of slot %0d wrong", what, bad, slot));
    endtask

    // The parameter struct as cd_mount writes it: the path NUL-padded, flags 0 and size 0, 66 words
    task automatic write_param_path(input string p);
        for (int w = 0; w < 66; w++) begin
            logic [7:0] b [4];
            for (int k = 0; k < 4; k++) b[k] = w < 64 && 4 * w + k < p.len() ? 8'(p[4 * w + k]) : 8'd0;
            @(posedge clk74);
            path_addr <= 8'(w);
            path_wdata <= {b[0], b[1], b[2], b[3]};
            path_wr <= 1;
            @(posedge clk74);
            path_wr <= 0;
        end
    endtask

    int ws_dones = 0;
    always @(posedge clk74) if (ws_done) ws_dones++;

    // The wait counter's write, the third client, as the command in flight
    task automatic slot_write_in_flight();
        @(posedge clk74) ws_req <= 1;
        wait_host_busy();
        @(posedge clk74) ws_req <= 0;
    endtask

    function automatic int host_cmds();
        return host.log_q.size();
    endfunction

    // ---- Tests ----
    task automatic test_read_lands_in_bank_slot();
        logic [2:0] err;
        logic [31:0] q [WORDS], q74 [WORDS], q1 [WORDS], q3 [WORDS], d [WORDS];
        int n0;
        test = "test_read_lands_in_bank_slot";
        host.slot_file[2] = PATTERN;
        read_slot(1, q1, d);
        read_slot(3, q3, d);
        n0 = host_cmds();
        mount_cmd(0, 2, 3 * SECTOR, SECTOR, 2, err);
        check(err == 0, $sformatf("mount read answered err %0d", err));
        check(host_cmds() == n0 + 1, $sformatf("%0d host commands for one read", host_cmds() - n0));
        begin
            automatic host_bfm_pkg::cmd_t c = host.log_q[$];
            check(c.cmd == 16'h0180 && c.id == 2 && c.offset == 3 * SECTOR && c.addr == 32'h7000_2000 && c.len == SECTOR,
                  $sformatf("host saw cmd %04x id %0x offset %0d addr %08x len %0d", c.cmd, c.id, c.offset, c.addr, c.len));
        end
        check_slot(2, PATTERN, 3 * SECTOR, "the read");
        read_slot(2, q, q74);
        check(q[0] == {pattern(3 * SECTOR), pattern(3 * SECTOR + 1), pattern(3 * SECTOR + 2), pattern(3 * SECTOR + 3)},
              $sformatf("word 0 is %08x, not the file's bytes 0..3 in bridge order", q[0]));
        check(q[WORDS - 1] == file_word(PATTERN, 3 * SECTOR, WORDS - 1), $sformatf("word 587 is %08x", q[WORDS - 1]));
        read_slot(1, q, d);
        check(q == q1, "slot 1 changed");
        read_slot(3, q, d);
        check(q == q3, "slot 3 changed");
    endtask

    task automatic test_fetch_before_mount_read();
        logic [2:0] err;
        logic ferr;
        int n0;
        test = "test_fetch_before_mount_read";
        host.slot_file[2] = PATTERN;
        n0 = host_cmds();
        // A client has one request outstanding: both are pending while the slot write is in flight
        slot_write_in_flight();
        mount_start(0, 2, SECTOR, SECTOR, 1);
        fetch_start(2, 2 * SECTOR, 3);
        fetch_wait(ferr);
        check(!ferr, "the fetch failed");
        mount_wait(err);
        check(err == 0, $sformatf("mount read err %0d", err));
        check(host_cmds() == n0 + 3, $sformatf("%0d host commands, 3 expected", host_cmds() - n0));
        if (host_cmds() == n0 + 3) begin
            check(host.log_q[n0].cmd == 16'h0184 && host.log_q[n0 + 1].offset == 2 * SECTOR && host.log_q[n0 + 2].offset == SECTOR,
                  $sformatf("order: %04x, then offsets %0d, %0d: expected the write, the fetch (%0d), then the mount (%0d)",
                            host.log_q[n0].cmd, host.log_q[n0 + 1].offset, host.log_q[n0 + 2].offset, 2 * SECTOR, SECTOR));
            check(host.log_q[n0 + 1].addr == 32'h7000_3000 && host.log_q[n0 + 2].addr == 32'h7000_1000,
                  $sformatf("bridge addresses %08x, %08x", host.log_q[n0 + 1].addr, host.log_q[n0 + 2].addr));
        end
        check_slot(3, PATTERN, 2 * SECTOR, "the fetch");
        check_slot(1, PATTERN, SECTOR, "the mount read");
    endtask

    task automatic test_openfile_not_split();
        logic [2:0] err;
        logic ferr;
        int n0;
        test = "test_openfile_not_split";
        host.slot_file[2] = PATTERN;
        host.slot_file[3] = PATTERN;
        // Both pending behind a fetch in flight: the openfile goes first, so the fetch of slot 3 reads the new file
        write_param_path(OTHER);
        n0 = host_cmds();
        slot_write_in_flight();
        mount_start(2, 3, 0, 0, 0);
        fetch_start(3, SECTOR, 1);
        fetch_wait(ferr);
        check(!ferr, "fetch of slot 3 failed");
        mount_wait(err);
        check(err == 0, $sformatf("openfile err %0d", err));
        check(host_cmds() == n0 + 3, $sformatf("%0d host commands, 3 expected", host_cmds() - n0));
        if (host_cmds() == n0 + 3)
            check(host.log_q[n0 + 1].cmd == 16'h0192 && host.log_q[n0 + 1].path == OTHER && host.log_q[n0 + 2].cmd == 16'h0180,
                  $sformatf("second command %04x (%0s), third %04x: the openfile must come before the pending fetch",
                            host.log_q[n0 + 1].cmd, host.log_q[n0 + 1].path, host.log_q[n0 + 2].cmd));
        check(host.slot_file[3] == OTHER, $sformatf("slot 3 holds %0s", host.slot_file[3]));
        check_slot(1, OTHER, SECTOR, "fetch after the openfile");

        // A fetch arriving while an openfile is in flight waits for it
        write_param_path(PATTERN);
        n0 = host_cmds();
        mount_start(2, 3, 0, 0, 0);
        wait_host_busy();
        fetch_start(3, 2 * SECTOR, 2);
        fetch_wait(ferr);
        mount_wait(err);
        check(err == 0 && !ferr, $sformatf("openfile err %0d, fetch err %0d", err, ferr));
        if (host_cmds() == n0 + 2)
            check(host.log_q[n0].cmd == 16'h0192 && host.log_q[n0 + 1].cmd == 16'h0180 &&
                  host.log_q[n0 + 1].t_busy > host.log_q[n0].t_done,
                  "the fetch's read did not wait for the openfile to finish");
        else check(0, $sformatf("%0d host commands, 2 expected", host_cmds() - n0));
        check_slot(2, PATTERN, 2 * SECTOR, "fetch after the second openfile");

        // A name the host does not know
        write_param_path("/Assets/ngcd/common/t/missing.bin");
        mount_cmd(2, 3, 0, 0, 0, err);
        check(err == 3, $sformatf("openfile of an unknown name answered err %0d", err));
        check(host.slot_file[3] == PATTERN, $sformatf("slot 3 switched to %0s", host.slot_file[3]));
    endtask

    task automatic test_fetch_error_leaves_slot_invalid();
        logic ferr;
        logic [31:0] q [WORDS], d [WORDS], after [WORDS];
        int n0;
        test = "test_fetch_error_leaves_slot_invalid";
        host.slot_file[2] = PATTERN;
        fetch_start(2, 0, 1);
        fetch_wait(ferr);
        check(!ferr, "the known fill failed");
        read_slot(1, q, d);
        // err 1, no data
        host.fail_next = 1;
        n0 = host.n_read;
        fetch_start(2, 5 * SECTOR, 1);
        fetch_wait(ferr);
        check(ferr == 1, "fr_err not set with fr_done after err 1");
        check(host.log_q[$].err == 1, $sformatf("host answered err %0d", host.log_q[$].err));
        read_slot(1, after, d);
        check(after == q, "slot 1's words changed after err 1");
        // err 2: a read past the file's end, which the host refuses whole
        fetch_start(2, 7 * SECTOR + 4, 1);
        fetch_wait(ferr);
        check(ferr == 1, "fr_err not set after err 2");
        check(host.log_q[$].err == 2, $sformatf("host answered err %0d to a read past the end", host.log_q[$].err));
        check(host.n_read == n0, "the host wrote data for a failed read");
        read_slot(1, after, d);
        check(after == q, "slot 1's words changed after err 2");
        // The next fetch clears it
        fetch_start(2, 6 * SECTOR, 1);
        fetch_wait(ferr);
        check(!ferr, "fr_err still set after a good fetch");
        check_slot(1, PATTERN, 6 * SECTOR, "good fetch after the errors");
    endtask

    task automatic test_getfile_response_path();
        localparam string P = "/Assets/ngcd/common/Metal Slug 'X', 2/Metal Slug 'X' (Disc 1).cue";
        logic [2:0] err;
        string s = "";
        bit ended = 0;
        test = "test_getfile_response_path";
        host.slot_file[2] = P;
        mount_cmd(1, 2, 0, 0, 0, err);
        check(err == 0, $sformatf("getfile err %0d", err));
        check(host.log_q[$].cmd == 16'h0190 && host.log_q[$].offset == 32'h7100_0400,
              $sformatf("host saw cmd %04x with response pointer %08x", host.log_q[$].cmd, host.log_q[$].offset));
        for (int w = 0; w < 128 && !ended; w++) begin
            @(posedge clk74);
            path_addr <= 8'(128 + w);
            @(posedge clk74);
            @(posedge clk74);
            for (int k = 3; k >= 0; k--) begin
                if (path_q[8 * k +: 8] == 0) begin
                    ended = 1;
                    break;
                end
                s = {s, string'(path_q[8 * k +: 8])};
            end
        end
        check(ended && s == P, $sformatf("path read back \"%0s\"", s));
    endtask

    task automatic test_wait_slot_write();
        logic [2:0] err;
        int n0, d0;
        test = "test_wait_slot_write";
        write_param_path(PATTERN);
        n0 = host_cmds();
        d0 = ws_dones;
        mount_start(2, 3, 0, 0, 0);
        wait_host_busy();
        @(posedge clk74) ws_req <= 1;           // save_now rises, and stays high
        mount_wait(err);
        check(err == 0, $sformatf("openfile err %0d", err));
        repeat (2 * (2000 + 200 + 2048 * 2 * 88 + 12 * 88)) @(posedge clk74);
        check(host_cmds() == n0 + 2, $sformatf("%0d host commands, 2 expected: the openfile, then one write", host_cmds() - n0));
        if (host_cmds() == n0 + 2) begin
            automatic host_bfm_pkg::cmd_t c = host.log_q[n0 + 1];
            check(host.log_q[n0].cmd == 16'h0192, "the openfile was not first");
            check(c.cmd == 16'h0184 && c.id == 16'h0103 && c.offset == 0 && c.addr == 32'h8000_0000 && c.len == 8192,
                  $sformatf("write cmd %04x id %0x offset %0d addr %08x len %0d", c.cmd, c.id, c.offset, c.addr, c.len));
            check(c.t_busy > host.log_q[n0].t_done, "the write started inside the openfile");
        end
        check(ws_dones - d0 == 1 && ws_err == 0, $sformatf("ws_done pulsed %0d times, ws_err %0d", ws_dones - d0, ws_err));
        check(host.wlog.size() == 2048, $sformatf("%0d words written", host.wlog.size()));
        foreach (host.wlog[i])
            if (host.wlog[i] != (32'h5A00_0000 | i)) begin
                check(0, $sformatf("written word %0d is %08x", i, host.wlog[i]));
                break;
            end
        // Low, then high again: a second write
        @(posedge clk74) ws_req <= 0;
        repeat (100) @(posedge clk74);
        @(posedge clk74) ws_req <= 1;
        repeat (2 * (2000 + 200 + 2048 * 2 * 88 + 12 * 88)) @(posedge clk74);
        check(host_cmds() == n0 + 3 && host.log_q[$].cmd == 16'h0184, "no second write for the second rising edge");
        check(ws_dones - d0 == 2, $sformatf("ws_done pulsed %0d times after two edges", ws_dones - d0));
        ws_req <= 0;
    endtask

    task automatic run(input string name);
        tests++;
        case (name)
            "test_read_lands_in_bank_slot":         test_read_lands_in_bank_slot();
            "test_fetch_before_mount_read":         test_fetch_before_mount_read();
            "test_openfile_not_split":              test_openfile_not_split();
            "test_fetch_error_leaves_slot_invalid": test_fetch_error_leaves_slot_invalid();
            "test_getfile_response_path":           test_getfile_response_path();
            "test_wait_slot_write":                 test_wait_slot_write();
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done, %0d failures so far", name, errors);
    endtask

    initial begin
        string files [] = '{PATTERN, OTHER};
        fork host.serve_forever(files); join_none
        repeat (100) @(posedge clk74);
        run("test_read_lands_in_bank_slot");
        run("test_fetch_before_mount_read");
        run("test_openfile_not_split");
        run("test_fetch_error_leaves_slot_invalid");
        run("test_getfile_response_path");
        run("test_wait_slot_write");
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("cd_host: %0d tests passed", tests);
        $finish;
    end

    initial begin
        #(200.0e6);
        $fatal(1, "timeout");
    end
endmodule
