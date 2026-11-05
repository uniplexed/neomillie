// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The Pocket's host on the target side of core_bridge_cmd.v, through the bridge only: bridge_bfm at its
// real rate (one word per 88 clocks of 74.25 MHz), plus serve_forever, which polls target_0 at 0xF8001000
// every POLL_CLKS and answers the commands core_bridge_cmd.v:474-520 puts there, as Analogue's docs and
// openfpga-megacd's use of them describe:
//
//   0x0140 ready to run    answered at once
//   0x0180 read            busy (0x6275), LATENCY_CLKS of host latency, the file's bytes written at
//                          bridgeaddr, a word {b0, b1, b2, b3} (bridge_endian_little = 0), then done
//                          (0x6F6B | err). A read whose end is past the file answers err 2 and writes
//                          nothing: it is never truncated (inferred, the firmware's behaviour is unseen)
//   0x0184 write           length bytes read back from bridgeaddr into wlog
//   0x0190 getfile         the slot's file path, NUL-terminated, written at the response pointer
//   0x0192 openfile        the path read from the parameter struct (path 256 bytes, flags at 0x100,
//                          size at 0x104) switches the slot's file. err 3 for a name it does not know,
//                          as Analogue's docs, and for anything outside /Assets/ngcd/
//
// The register reads are each done twice: core_bridge_cmd.v loads bridge_rd_data on the strobe, so a
// read answers with the word of the read before it (bridge_bfm.sv). fail_next answers the next command
// with err 1 and no data. A file's card path is also its path below the run
// directory, which prepare.py fills.
`timescale 1ns/1ps
package host_bfm_pkg;
    // One command as the host served it
    typedef struct {
        logic [15:0] cmd;
        logic [15:0] id;
        logic [31:0] offset, addr, len;     // offset is the struct pointer for getfile and openfile
        logic  [2:0] err;
        string       path;
        realtime     t_busy, t_done;
    } cmd_t;
endpackage

module host_bfm import host_bfm_pkg::*; #(
    parameter int POLL_CLKS    = 2000,      // 27 us between polls of target_0
    parameter int LATENCY_CLKS = 74250,     // 1 ms from busy to the first data word
    parameter bit FAIL_NEXT    = 0
) (
    input  wire        clk,
    output wire [31:0] bridge_addr,
    output wire        bridge_wr,
    output wire [31:0] bridge_wr_data,
    output wire        bridge_rd,
    input  wire [31:0] bridge_rd_data
);

    bridge_bfm bfm (.clk, .bridge_addr, .bridge_wr, .bridge_wr_data, .bridge_rd, .bridge_rd_data);

    int  latency_clks = LATENCY_CLKS;
    bit  fail_next    = FAIL_NEXT;
    bit  quiet        = 1;
    string slot_file [int];         // slot id -> card path of the file it reads
    string known [$];               // what openfile may open

    // What the host did, for the benches
    cmd_t log_q [$];
    logic [31:0] wlog [$];          // the last write's words
    int  n_read = 0;

    task automatic reg_read(input logic [7:0] a, output logic [31:0] v);
        bfm.read_twice(32'hF800_1000 | a, v);
    endtask

    task automatic answer(input logic [15:0] code);
        bfm.write32(32'hF800_1000, {16'h6F6B, code});
    endtask

    function automatic bit is_known(input string p);
        foreach (known[i]) if (known[i] == p) return 1;
        return 0;
    endfunction

    function automatic string local_path(input string card);
        return card.len() > 0 && card[0] == "/" ? card.substr(1, card.len() - 1) : card;
    endfunction

    // Size of the slot's file, -1 if it has none
    function automatic longint file_size(input string card);
        int fd;
        longint n;
        if (card == "") return -1;
        fd = $fopen(local_path(card), "rb");
        if (fd == 0) return -1;
        void'($fseek(fd, 0, 2));
        n = $ftell(fd);
        $fclose(fd);
        return n;
    endfunction

    task automatic serve_read(inout cmd_t c);
        string card = slot_file.exists(int'(c.id)) ? slot_file[int'(c.id)] : "";
        longint size = file_size(card);
        int fd;
        logic [7:0] b [4];
        c.path = card;
        if (size < 0 || longint'(c.offset) + longint'(c.len) > size) begin
            c.err = 2;
            return;
        end
        fd = $fopen(local_path(card), "rb");
        void'($fseek(fd, c.offset, 0));
        for (int i = 0; i < int'(c.len); i += 4) begin
            for (int k = 0; k < 4; k++) b[k] = i + k < int'(c.len) ? 8'($fgetc(fd)) : 8'd0;
            bfm.write32(c.addr + 32'(i), {b[0], b[1], b[2], b[3]});
        end
        $fclose(fd);
        n_read++;
    endtask

    task automatic write_string(input logic [31:0] addr, input string s);
        logic [7:0] b [4];
        for (int i = 0; i <= s.len(); i += 4) begin
            for (int k = 0; k < 4; k++) b[k] = i + k < s.len() ? 8'(s[i + k]) : 8'd0;
            bfm.write32(addr + 32'(i), {b[0], b[1], b[2], b[3]});
        end
    endtask

    task automatic read_struct_path(input logic [31:0] addr, output string s);
        logic [31:0] w [$];
        bit ended = 0;
        bfm.read_file(addr, 66, w);
        s = "";
        for (int i = 0; i < 64 && !ended; i++)
            for (int k = 3; k >= 0; k--) begin
                logic [7:0] ch = w[i][8 * k +: 8];
                if (ch == 0) begin
                    ended = 1;
                    break;
                end
                s = {s, string'(ch)};
            end
    endtask

    task automatic serve_one(input logic [15:0] code);
        cmd_t c;
        logic [31:0] v;
        c.cmd = code;
        c.err = 0;
        c.path = "";
        reg_read(8'h20, v);
        c.id = v[15:0];
        reg_read(8'h24, c.offset);
        reg_read(8'h28, c.addr);
        reg_read(8'h2C, c.len);
        bfm.write32(32'hF800_1000, 32'h6275_0000);
        c.t_busy = $realtime;
        repeat (latency_clks) @(posedge clk);
        if (fail_next) begin
            fail_next = 0;
            c.err = 1;
        end
        else case (code)
            16'h0180: serve_read(c);
            16'h0184: begin
                bfm.read_file(c.addr, int'((c.len + 3) / 4), wlog);
            end
            16'h0190: begin
                c.path = slot_file.exists(int'(c.id)) ? slot_file[int'(c.id)] : "";
                write_string(c.offset, c.path);     // target_24 holds the response pointer
            end
            16'h0192: begin
                read_struct_path(c.offset, c.path); // target_24 holds the parameter pointer
                if (!is_known(c.path) || c.path.substr(0, 12) != "/Assets/ngcd/" || file_size(c.path) < 0) c.err = 3;
                else slot_file[int'(c.id)] = c.path;
            end
            default: c.err = 7;
        endcase
        // In the log before the answer, which the core sees within a few clocks of the strobe
        c.t_done = $realtime;
        if (!quiet) $display("host: cmd %04x id %0x offset %0d addr %08x len %0d err %0d %s", c.cmd, c.id, c.offset, c.addr, c.len, c.err, c.path);
        log_q.push_back(c);
        answer({13'd0, c.err});
    endtask

    // files[0] is what slot 2 holds when the core starts; all of them may be opened
    task automatic serve_forever(input string files []);
        logic [31:0] v;
        slot_file[2] = files.size() > 0 ? files[0] : "";
        foreach (files[i]) known.push_back(files[i]);
        forever begin
            repeat (POLL_CLKS) @(posedge clk);
            reg_read(8'h00, v);
            if (v[31:16] != 16'h636D) continue;
            if (v[15:0] == 16'h0140) answer(16'h0000);
            else serve_one(v[15:0]);
        end
    endtask

endmodule
