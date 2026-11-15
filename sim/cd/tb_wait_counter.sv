// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// rtl/test/wait_counter.sv's layout 3 on its own, with made-up feeds, in seconds: sim/topcd holds the same words against
// the real core, in an hour. Every word of the file by its number, the rings' order past their depth.
// Writes wait_l3.sav for tools/check_wait_save.py.
`timescale 1ns/1ps
module tb_wait_counter;
    localparam int FILE_WORDS = 128;

    logic clk48 = 0, clk74 = 0;
    always #10.345 clk48 = ~clk48;
    always #6.734 clk74 = ~clk74;

    logic         nRESET = 0, nAS = 1, vblank = 0, bridge_rd = 0;
    logic [31:0]  bridge_addr = 32'h8000_0000;
    logic [113:0] cdd = 0;
    logic [53:0]  cd2 = 0;
    logic [36:0]  sect = 0;
    logic [0:9][31:0]  fetch = 0;
    logic [0:11][31:0] dma = 0;
    wire  [31:0]  rd3;

    wait_counter dut (
        .clk_48m(clk48), .nRESET, .nAS, .rom_zone(1'b0), .at_req(2'd1), .vblank, .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr, .bridge_rd, .bridge_rd_data(rd3), .bridge_wr(1'b0), .bridge_wr_data(32'd0), .run(1'b0), .save_now(),
        .save_done(1'b0), .save_err(3'd0),
        .cdd, .disc_bin_size(32'd1234), .disc_reason(4'd1), .open_log(384'd0), .cd2, .fetch, .dma, .sect, .dmab(49'd0), .bus68(18'd0), .dreq(26'd0),
        .rcnt({32'hCD00_0000, 32'hCD00_0001, 32'hCD00_0002, 32'hCD00_0003}), .ovc({2'd2, 24'd0}), .vid(5'b11000)
    );

    // A second one, for the runs: a file the host loads, a record per run, a save as a reset starts
    logic         r_nRESET = 0, r_vblank = 0, r_wr = 0, r_rd = 0, r_run = 0;
    logic [31:0]  r_addr = 32'h8000_0000, r_wdata = 0;
    logic [25:0]  r_dreq = 0;
    wire  [31:0]  r_q;
    wire          r_save;
    int           r_saves = 0;
    always @(posedge clk74) if (r_save) r_saves++;

    wait_counter runs (
        .clk_48m(clk48), .nRESET(r_nRESET), .nAS(1'b1), .rom_zone(1'b0), .at_req(2'd1), .vblank(r_vblank), .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr(r_addr), .bridge_rd(r_rd), .bridge_rd_data(r_q),
        .bridge_wr(r_wr), .bridge_wr_data(r_wdata), .run(r_run), .save_now(r_save),
        .save_done(1'b0), .save_err(3'd0),
        .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0), .open_log(384'd0), .cd2(54'd0), .fetch(320'd0), .dma(384'd0), .sect(37'd0), .dmab(49'd0), .bus68(18'd0), .dreq(r_dreq), .rcnt(128'd0), .ovc(26'd0), .vid(5'b11000)
    );

    // Early reads on their own: a run of its own reset, its 68K bus and its DMA
    logic         e_nRESET = 0, e_nAS = 1, e_vblank = 0;
    logic [53:0]  e_cd2 = 0;
    logic [48:0]  e_dmab = 0;
    logic [17:0]  e_bus68 = 18'h3FFFF;
    logic         e_sect33 = 0;
    logic   [2:0] e_fate = 0;
    logic  [32:0] e_info = 0;
    logic  [25:0] e_dreq = 0;
    logic [113:0] e_cdd = 0;
    logic [127:0] e_rcnt = 0;
    logic [0:9][31:0] e_fetch = 0;
    logic  [25:0] e_ovc = 0;
    logic   [4:0] e_vid = 5'b11000;
    wait_counter ear (
        .clk_48m(clk48), .nRESET(e_nRESET), .nAS(e_nAS), .rom_zone(1'b0), .at_req(2'd1), .vblank(e_vblank), .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr(32'h8000_0000), .bridge_rd(1'b0), .bridge_rd_data(), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
        .run(1'b0), .save_now(), .save_done(1'b0), .save_err(3'd0),
        .cdd(e_cdd), .disc_bin_size(32'd0), .disc_reason(4'd0), .open_log(384'd0), .cd2(e_cd2), .fetch(e_fetch), .dma(384'd0), .sect({e_fate, e_sect33, e_info}), .dmab(e_dmab), .bus68(e_bus68), .dreq(e_dreq), .rcnt(e_rcnt), .ovc(e_ovc), .vid(e_vid)
    );

    // The overclock counters on a cart instance: no CD feed, the 68K's address and clock setting
    logic         o_nRESET = 0, o_nAS = 1, o_vblank = 0;
    logic  [25:0] o_ovc = 0, o_dreq = 0;
    logic   [4:0] o_vid = 5'b11000;
    wait_counter #(.CD(0)) ovk (
        .clk_48m(clk48), .nRESET(o_nRESET), .nAS(o_nAS), .rom_zone(1'b0), .at_req(2'd1), .vblank(o_vblank), .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr(32'h8000_0000), .bridge_rd(1'b0), .bridge_rd_data(), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
        .run(1'b0), .save_now(), .save_done(1'b0), .save_err(3'd0),
        .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0), .open_log(384'd0), .cd2(54'd0), .fetch(320'd0), .dma(384'd0),
        .sect(37'd0), .dmab(49'd0), .bus68(18'd0), .dreq(o_dreq), .rcnt(128'd0), .ovc(o_ovc), .vid(o_vid)
    );

    task automatic o_bus(input logic [22:0] a);
        o_ovc[22:0] = a;
        o_nAS = 0;
        tick(3);
        o_nAS = 1;
        tick(1);
    endtask

    task automatic o_frame();
        o_vblank = 1;
        tick(130);
        o_vblank = 0;
        tick(4);
    endtask

    // A frame with this many lit pixels, the layers in off being off at a visible pixel, and all of them off in blanking
    task automatic o_vframe(input int lit, input logic [2:0] off);
        o_vid = {1'b0, 1'b0, 3'b111};
        tick(4);
        o_vid = {1'b0, 1'b1, off};
        tick(4);
        o_vid[4] = 1;
        tick(lit);
        o_vid[4] = 0;
        tick(4);
        o_vid = {1'b0, 1'b0, 3'b111};
        o_frame();
    endtask

    task automatic e_bus(input logic [23:0] byte_addr, input bit write);
        e_cd2[30:8] = byte_addr[23:1];
        e_cd2[31] = ~write;
        e_nAS = 0;
        tick(16);
        e_nAS = 1;
        tick(4);
    endtask

    // A 68K write as the bus has it: the address and R/W with /AS, the data and the strobes a few clocks later
    task automatic e_write(input logic [23:0] byte_addr, input logic [15:0] data, input logic [1:0] strobes);
        e_cd2[30:8] = byte_addr[23:1];
        e_cd2[31] = 0;
        e_nAS = 0;
        tick(3);
        e_bus68 = {~strobes, data};
        tick(8);
        e_nAS = 1;
        e_bus68[17:16] = 2'b11;
        tick(2);
        e_bus68[15:0] = 16'hDEAD;               // the next cycle's: not the one taken
        e_cd2[31] = 1;
        tick(4);
    endtask

    // A frame of ear's: it opens with these layers off and no lit pixel, or lit all through with none off, and closes at VBlank
    task automatic e_vopen(input logic [2:0] off);
        e_vid = {off == 0, 1'b1, off};
        tick(off == 0 ? 9000 : 4);
    endtask

    task automatic e_vclose();
        e_vid = 5'b00111;
        e_vblank = 1;
        tick(130);
        e_vblank = 0;
        tick(4);
    endtask

    // A bus cycle seen by its address alone, and a write strobe of the transfer area: 109 FIX, 110 SPR, 111 PCM, 112 Z80
    task automatic e_addr(input logic [22:0] a);
        e_ovc[22:0] = a;
        e_nAS = 0;
        tick(3);
        e_nAS = 1;
        tick(2);
    endtask

    task automatic e_strobe(input int bit_no);
        e_cdd[bit_no] = 1;
        tick(2);
        e_cdd[bit_no] = 0;
        tick(2);
    endtask

    // drive.v sends a command to the drive; a sector request toggles dreq[25]
    task automatic e_cmd(input logic [39:0] c);
        e_cdd[39:0] = c;
        e_cd2[7] = 1; tick; e_cd2[7] = 0; tick(4);
    endtask

    task automatic e_req(input bit audio);
        e_dreq = {~e_dreq[25], audio, e_dreq[23:0] + 24'd1};
        tick(20);
    endtask

    // An entry of the load log, its 4 words
    task automatic e_entry(input int n, output logic [31:0] e [4]);
        for (int k = 0; k < 4; k++) e[k] = ear.tl[10'(4 * n + k)];
    endtask

    task automatic e_dma(input logic [23:0] byte_addr, input bit write);
        e_dmab[48] = 1;
        if (write) e_dmab[45:23] = byte_addr[23:1];
        else       e_dmab[22:0]  = byte_addr[23:1];
        e_dmab[write ? 47 : 46] = 1;
        tick(5);
        e_dmab[47:46] = 0;
        tick(5);
        e_dmab[48] = 0;
        tick(2);
    endtask

    // The UniBIOS's SYSTEM setting replaced by the model CD/CDZ asks for
    logic         y_nRESET = 0, y_nAS = 1, y_nUDS = 1, y_nLDS = 1, y_rw = 1;
    logic  [7:0]  y_model = 8'd2;
    logic [23:1]  y_addr = 0;
    logic [15:0]  y_data = 0;
    wire  [15:0]  y_out;
    wire          y_unibios;
    wire  [15:0]  y_requested;
    bios_model model (.clk(clk48), .nRESET(y_nRESET), .nAS(y_nAS), .nUDS(y_nUDS), .nLDS(y_nLDS), .M68K_RW(y_rw),
                      .M68K_ADDR(y_addr), .data_in(y_data), .model(y_model), .data_out(y_out),
                      .unibios(y_unibios), .requested(y_requested));

    // A write cycle as the 68K makes it: the address first, then the strobes. Returns what the bus carried under the strobes.
    task automatic y_write(input logic [23:0] byte_addr, input logic [15:0] data, input bit upper, input bit lower,
                           output logic [15:0] seen);
        y_addr = byte_addr[23:1];
        y_rw   = 0;
        y_nAS  = 0;
        tick(4);
        y_data = data;
        y_nUDS = !upper;
        y_nLDS = !lower;
        tick(4);
        seen   = y_out;
        y_nAS  = 1;
        y_nUDS = 1;
        y_nLDS = 1;
        y_rw   = 1;
        tick(2);
    endtask

    task automatic test_bios_model();
        logic [15:0] seen;
        y_model = 8'd2;
        y_nRESET = 1;
        tick(2);
        y_write(24'h10FE32, 16'h0002, 1, 1, seen);
        check(seen == 16'h0002 && !y_unibios, "a BIOS with no magic had its write changed");
        y_write(24'h10FE30, 16'h1234, 1, 1, seen);
        check(seen == 16'h1234 && !y_unibios, "another value at $10FE30 counted as the magic");
        y_write(24'h10FE30, 16'h5632, 1, 1, seen);
        check(seen == 16'h5632 && y_unibios, "the magic did not mark a UniBIOS");
        y_write(24'h10FE32, 16'h0002, 1, 1, seen);
        check(seen == 16'h0202, "CD/CDZ on, TOPLOAD written: not stored as CDZ, or the region byte moved");
        check(y_requested[15:8] == 8'd0 && y_requested[7:0] == 8'd2, "the value the BIOS wrote was not kept for the debug file");
        y_write(24'h10FE32, 16'h0100, 1, 0, seen);
        check(seen[15:8] == 8'd2 && y_requested[15:8] == 8'd1, "a byte write of FRONTLOADER: not stored as CDZ");
        y_write(24'h10FE34, 16'h0104, 1, 1, seen);
        check(seen == 16'h0104, "the word after the setting was changed");
        y_model = 8'd0;
        y_write(24'h10FE32, 16'h0203, 1, 1, seen);
        check(seen == 16'h0003, "CD/CDZ off, CDZ written: not stored as TOPLOAD");
        // The cartridge BIOS: $80 is arcade, MVS
        y_model = 8'h80;
        y_write(24'h10FE32, 16'h0002, 1, 1, seen);
        check(seen == 16'h8002, "MVS, console written: not stored as arcade, or the region byte moved");
        y_model = 8'h00;
        y_write(24'h10FE32, 16'h8002, 1, 1, seen);
        check(seen == 16'h0002, "AES, arcade written: not stored as console");
        y_nRESET = 0; tick(2);
        y_nRESET = 1; tick;
        check(!y_unibios, "a reset did not forget the BIOS");
        y_write(24'h10FE32, 16'h0203, 1, 1, seen);
        check(seen == 16'h0203, "after a reset, a write before the magic was changed");
    endtask

    task automatic r_write(input int rec, input int word, input logic [31:0] data);
        @(posedge clk74);
        #1 r_addr = 32'h8000_0000 + 32'(rec * 512 + word * 4);
        r_wdata = data;
        r_wr = 1;
        @(posedge clk74);
        #1 r_wr = 0;
    endtask

    task automatic r_read(input int rec, input int word, output logic [31:0] data);
        @(posedge clk74);
        #1 r_addr = 32'h8000_0000 + 32'(rec * 512 + word * 4);
        repeat (3) @(posedge clk74);
        #1 r_rd = 1;
        @(posedge clk74);
        #1 r_rd = 0;
        @(posedge clk74);
        #1 data = r_q;
    endtask

    task automatic r_frame();
        r_vblank = 1;
        tick(130);
        r_vblank = 0;
        tick(4);
    endtask

    task automatic r_expect(input int rec, input int word, input logic [31:0] want, input string what);
        logic [31:0] got;
        r_read(rec, word, got);
        check(got == want, $sformatf("%0s: record %0d word %0d is %08x, want %08x", what, rec, word, got, want));
    endtask

    int errors = 0;
    function automatic void check(input bit ok, input string msg);
        if (!ok) begin
            errors++;
            if (errors <= 40) $display("%0s", msg);
        end
    endfunction

    task automatic tick(input int n = 1);
        repeat (n) @(posedge clk48);
        #1;
    endtask

    int frames_seen = 0;
    logic [31:0] lost_frame [10];
    task automatic frame();
        vblank = 1;
        tick(130);      // the copy, with its 127 words
        vblank = 0;
        tick(4);
        if (nRESET) frames_seen++;
    endtask

    // A 68K bus cycle, with the address and the direction it leaves on the bus
    task automatic bus(input logic [23:1] a, input bit write);
        cd2[30:8] = a;
        cd2[31] = ~write;
        nAS = 0;
        tick(3);
        nAS = 1;
        tick(1);
    endtask

    // drive.v sends a command; the drive answers a little later, as cdd_drive
    task automatic send(input logic [39:0] c);
        cdd[39:0] = c;
        cd2[7] = 1;
        tick;
        cd2[7] = 0;
    endtask

    task automatic answer(input logic [39:0] s);
        tick(3);
        cdd[79:40] = s;
        cdd[108] = 1;
        tick;
        cdd[108] = 0;
        tick(3);
    endtask

    task automatic read_file(output logic [31:0] w [FILE_WORDS]);
        for (int i = 0; i < FILE_WORDS; i++) begin
            @(posedge clk74);
            #1 bridge_addr = 32'h8000_0000 + 32'(dut.run_no[2:0] * 512 + i * 4);
            repeat (3) @(posedge clk74);
            #1 bridge_rd = 1;
            @(posedge clk74);
            #1 bridge_rd = 0;
            @(posedge clk74);
            #1 w[i] = rd3;
        end
    endtask

    function automatic logic [39:0] cmd_word(input int i);
        logic [3:0] code = 4'(i % 15 + 1);      // never IDLE
        return {4'(~(5 + code)), 28'(i), 4'd0, code};
    endfunction

    function automatic logic [39:0] ans_word(input int i);
        return {4'h9, 32'(i * 3 + 1), 4'h4};
    endfunction

    logic [31:0] w [FILE_WORDS];

    initial begin
        tick(20);
        frame();                                // in reset: no frame, no sample
        check(dut.frames == 0, "a frame counted in reset");
        nRESET = 1;
        tick(2);
        frame();

        // ---- Second reset, at a known frame ----
        repeat (3) frame();
        nRESET = 0;
        tick(5);
        nRESET = 1;
        tick(5);

        // ---- The commands: IDLE stays out, the last 8 of 10 stay, an answer goes with its command ----
        for (int i = 0; i < 10; i++) begin
            send(cmd_word(i));
            answer(ans_word(i));
            send(40'hA0_0000_0000);             // the IDLE between them, and its answer
            answer(40'h70_0000_0009);
            frame();
        end
        // A command nobody has answered yet, then a reset's answer, to no command: it stays out
        send(cmd_word(10));
        tick(3);
        nRESET = 0;
        tick(4);
        nRESET = 1;
        answer(40'h11_2233_4455);
        frame();

        // ---- The 68K at 5 VBlanks: only the last 4 stay ----
        for (int f = 0; f < 5; f++) begin
            repeat (300 * (f + 1)) bus(23'h100000 + 23'(f), f == 2);
            frame();
        end

        // ---- The rest of the feeds ----
        cd2[6:0] = 7'b1_01_11_0_1;              // lid debug, EU, 4x, bit 12 low, CDZ
        for (int i = 0; i < 10; i++) fetch[i] = 32'hF000 + 32'(i);
        fetch[6] = 0;
        for (int i = 0; i < 12; i++) dma[i] = 32'hD000 + 32'(i);
        frame();
        cdd[113] = 1;                           // a failed sector
        tick;
        cdd[113] = 0;
        tick(3);
        frame();
        fetch[6] = 32'hF006;                    // a late poll, two frames on
        tick(3);
        repeat (2) begin
            cd2[32] = 1;                        // a DMA write to nowhere: a level for the word's strobe
            tick(5);
            cd2[32] = 0;
            cd2[33] = 1;                        // a bank change in a DMA: a pulse
            tick;
            cd2[33] = 0;
            tick(2);
        end

        // The 2x hold: two holds, the first one ran out (the toggle)
        @(negedge clk48);
        cd2[35] = 1;
        repeat (200) @(negedge clk48);
        cd2[35] = 0;
        cd2[36] = 1;
        repeat (4) @(negedge clk48);
        cd2[35] = 1;
        repeat (50) @(negedge clk48);
        cd2[35] = 0;
        repeat (4) @(negedge clk48);

        // The sectors: 3 DMA'd, 2 skipped, and 10 lost over two frames, each with its header and its interrupt's fate. The
        // last 8 lost stay, the newest first
        for (int i = 0; i < 3; i++) begin sect[36] = ~sect[36]; repeat (3) @(negedge clk48); end
        for (int i = 0; i < 2; i++) begin sect[35] = ~sect[35]; repeat (3) @(negedge clk48); end
        for (int i = 0; i < 10; i++) begin
            sect[32:0] = {i[0], 32'h0100_0000 | 32'(i)};    // sect[33] is the late STAT3 toggle: left alone
            sect[34] = ~sect[34];
            lost_frame[i] = dut.frames;
            repeat (3) @(negedge clk48);
            if (i == 4) frame();
        end
        frame();
        tick(4);

        test_bios_model();

        // ---- The load log, on its own instance: CD/CDZ on, 2x, Turbo on (a ring count not 0) ----
        e_cd2[0] = 1;
        e_cd2[3:2] = 2'b01;
        e_rcnt[95:80] = 16'd5;                  // the ring's waits
        e_rcnt[63:48] = 16'hFFFF;               // min_ahead as it resets
        e_fetch[6] = 32'd100;                   // cd_fetch's late polls
        tick(2);
        e_nRESET = 1;
        tick(4);
        begin
            automatic logic [39:0] PLAY = 40'hD071200003, PAUSE = 40'h4000000006, STOP = 40'h9000000001;
            automatic logic [63:0] t_start, t_end;
            automatic logic [31:0] e [4];
            automatic int got, want;
            automatic logic [15:0] lba0;
            tick(600);                              // the trace's words are cleared as the core opens
            check(ear.tr_clr == 0 && ear.tr_wp == 0 && ear.tl[512] == 0 && ear.tl[1023] == 0, "the trace is not clear after the first release");
            lba0 = e_dreq[15:0];
            // A PLAY, 5 data sectors, a PAUSE: one entry
            e_cmd(PLAY);
            t_start = ear.total;
            repeat (5) e_req(0);
            e_rcnt[95:80] = 16'd8;
            e_fetch[6] = 32'd103;
            tick(100);
            e_info[31:0] = 32'h01_17_02_00;         // a sector DMA'd: mode 1, frame 17, second 02, minute 00
            e_fate = e_fate ^ 3'b100;
            tick(20000);
            e_cmd(PAUSE);
            t_end = ear.total;
            tick(12);
            e_entry(1, e);
            got = int'(e[1][27:0] - e[0][27:0]);
            want = int'(t_end[37:10] - t_start[37:10]);
            check(e[0][31:28] == 4'b1_01_1, $sformatf("load 1: flags %b, want Turbo, 2x, CDZ", e[0][31:28]));
            check(e[1][31:28] == 4'd1, $sformatf("load 1: reason %0d, want 1 (PAUSE)", e[1][31:28]));
            check(got >= want - 1 && got <= want + 1 && want > 15, $sformatf("load 1: %0d units, the bench drove %0d", got, want));
            check(e[2] == {16'd1, 16'd5}, $sformatf("load 1: %0d PLAYs, %0d sectors, want 1 and 5", e[2][31:16], e[2][15:0]));
            check(e[3] == {ear.run_no[7:0], 12'd3, 12'd3}, $sformatf("load 1: word 3 %08x, want run %0d, 3 ring waits, 3 late polls", e[3], ear.run_no));
            check(ear.tl[0] == {16'h4C44, 7'd0, 1'b0, 8'd2}, $sformatf("load log header %08x after one load", ear.tl[0]));
            check(ear.tl[1] == 0 && ear.tl[2] == 0 && ear.tl[3] == 0, "entry 0's words 1 to 3 are not 0");
            // The trace of that load: the PLAY's target, the five requests, the ring's wait, the sector DMA'd, the PAUSE, in order
            begin
                automatic logic [3:0]  k [9] = '{4'd1, 4'd3, 4'd3, 4'd3, 4'd3, 4'd3, 4'd8, 4'd5, 4'd2};
                automatic logic [15:0] v [9] = '{16'h0217, lba0 + 16'd1, lba0 + 16'd2, lba0 + 16'd3, lba0 + 16'd4, lba0 + 16'd5, 16'd8, 16'h0217, 16'h0006};
                check(ear.tr_wp == 9'd9, $sformatf("%0d trace events, want 9", ear.tr_wp));
                foreach (k[i]) check(ear.tl[512 + i][31:28] == k[i] && ear.tl[512 + i][15:0] == v[i],
                                     $sformatf("trace event %0d is %08x, want kind %0d value %04x", i, ear.tl[512 + i], k[i], v[i]));
                check(ear.tl[512 + 8][27:16] != ear.tl[512][27:16], "the trace's time did not move in 20,000 clocks");
                check(ear.words[126][11:3] == ear.tr_wp, "word 126 does not carry the trace's next word");
                // Out of a load a sector at the decoder is no event
                e_fate = e_fate ^ 3'b010;
                tick(8);
                check(ear.tr_wp == 9'd9 && ear.tl[512 + 9] == 0, "a sector out of a load made a trace event");
            end
            // The music: a PLAY to an audio track, audio sectors only. No entry
            e_cmd(PLAY);
            repeat (3) e_req(1);
            tick(12);
            check(ear.tl[0][7:0] == 8'd2, $sformatf("a load of audio sectors only wrote an entry: head %0d", ear.tl[0][7:0]));
            // Data sectors ended by an audio one: reason 3; Turbo off now
            e_rcnt = 0;
            e_cd2[3:2] = 2'b11;
            repeat (2) e_req(0);
            e_req(1);
            tick(12);
            e_entry(2, e);
            check(e[0][31:28] == 4'b0_11_1 && e[1][31:28] == 4'd3 && e[2] == {16'd0, 16'd2},
                  $sformatf("load 2: flags %b, reason %0d, word 2 %08x; want 0111, 3, 2 sectors", e[0][31:28], e[1][31:28], e[2]));
            // A STOP: reason 2
            e_req(0);
            e_cmd(STOP);
            tick(12);
            e_entry(3, e);
            check(e[1][31:28] == 4'd2 && e[2] == {16'd0, 16'd1}, $sformatf("load 3: reason %0d, word 2 %08x", e[1][31:28], e[2]));
            // A reset cuts a load: reason 4, the run that was cut
            e_req(0);
            e_req(0);
            e_nRESET = 0;
            tick(12);
            e_entry(4, e);
            check(e[1][31:28] == 4'd4 && e[2] == {16'd0, 16'd2} && e[3][31:24] == ear.run_no[7:0],
                  $sformatf("load 4: reason %0d, word 2 %08x, run %0d", e[1][31:28], e[2], e[3][31:24]));
            check(ear.tl[0] == {16'h4C44, 7'd0, 1'b0, 8'd5}, $sformatf("load log header %08x after four loads", ear.tl[0]));
            e_nRESET = 1;
            tick(4);
            // Entry 127 wraps the head to 1: the words past it are the trace's
            ear.tl_head = 8'd127;
            e_req(0);
            e_cmd(PAUSE);
            tick(12);
            e_entry(127, e);
            check(e[1][31:28] == 4'd1 && e[2] == {16'd0, 16'd1}, $sformatf("load 127: reason %0d, word 2 %08x", e[1][31:28], e[2]));
            check(ear.tl[0] == {16'h4C44, 7'd0, 1'b1, 8'd1}, $sformatf("load log header %08x after entry 127", ear.tl[0]));
        end
        // The file's second 4 KB goes to the load log: no run number from there, and it reads back through the bridge. A
        // header the host loads says where the next entry goes
        begin
            automatic logic [31:0] was = runs.loaded_run;
            r_write(8, 105, 32'd99);
            r_write(8, 0, 32'h4C44_0007);
            repeat (4) @(posedge clk74);
            check(runs.loaded_run == was, $sformatf("a word of the load log changed the loaded run to %0d", runs.loaded_run));
            r_expect(8, 105, 32'd99, "a load log word through the bridge");
        end
        // ---- The overclock counters, on a cart instance (CD = 0): 16 MHz ----
        o_ovc[25:24] = 2'd1;
        o_nRESET = 1;
        tick(4);
        repeat (20) begin o_bus(23'h60_0100); o_bus(23'h60_0101); o_bus(23'h60_0102); end
        // A period-3 loop of 60 cycles: from the 4th each matches 3 back, idle from the 9th (6 in a row)
        check(ovk.n_idle == 40'd52, $sformatf("a period-3 loop: %0d idle cycles, want 52", ovk.n_idle));
        o_frame();                              // a frame with idle cycles: not busy
        for (int i = 0; i < 20; i++) begin o_bus(23'h60_0200); o_bus(23'h10_0000 + 23'(i)); end
        check(ovk.n_idle == 40'd52, $sformatf("a copy loop counted idle: %0d", ovk.n_idle));
        o_frame();                              // busy: the copy loop
        o_frame();                              // busy: no cycle at all
        repeat (5) begin o_bus(23'h60_0100); o_bus(23'h60_0101); o_bus(23'h60_0102); end
        o_frame();                              // idle again: the streak ends at 2
        o_frame();                              // busy, a streak of 1
        check(ovk.n_busy == 32'd3 && ovk.longest == 16'd2, $sformatf("%0d busy frames, longest %0d; want 3 and 2", ovk.n_busy, ovk.longest));
        check(ovk.n_cyc == 40'd115, $sformatf("%0d bus cycles, want 115", ovk.n_cyc));
        begin
            automatic logic [9:0] at = {ovk.run_no[2:0], 7'd0};
            check(ovk.copy[at + 48] == {2'd1, 1'b0, 29'd0}, $sformatf("cart word 48: %08x", ovk.copy[at + 48]));
            check(ovk.copy[at + 50] == 32'd3 && ovk.copy[at + 51] == {16'd2, 16'd0}, $sformatf("cart words 50, 51: %08x %08x", ovk.copy[at + 50], ovk.copy[at + 51]));
            check(ovk.copy[at + 49] == 32'(ovk.n_idle >> 8) && ovk.copy[at + 52] == 32'(ovk.n_cyc >> 8), "cart words 49, 52 not the counts / 256");
        end
        // Dark frames and layers off, words 53-56 and 60-63: a run of frames in one state is one entry, newest first
        begin
            automatic logic [19:0] f0;
            automatic logic [31:0] prev;
            automatic logic [9:0] at = {ovk.run_no[2:0], 7'd0};
            o_vframe(9000, 3'b000);             // closes the frame the bench was in, whatever it held
            prev = ovk.v_ring[0];
            o_vframe(9000, 3'b000);
            check(ovk.v_ring[0] == prev, "a lit frame with every layer on, off only in blanking, made an entry");
            f0 = ovk.frames[19:0];
            o_vframe(0, 3'b000);                // black
            o_vframe(0, 3'b000);                // black again: the same entry
            o_vframe(9000, 3'b100);             // lit, video off at a visible pixel
            o_vframe(3000, 3'b000);             // under 8192 lit
            o_vframe(100, 3'b011);              // under 2048 lit, FIX and SPR off
            o_vframe(9000, 3'b000);             // normal: no entry, and the next black frame is a new one
            o_vframe(0, 3'b000);
            check(ovk.v_ring[4] == {5'b11_000, 7'd2, f0}, $sformatf("two black frames: %08x, from frame %0d", ovk.v_ring[4], f0));
            check(ovk.v_ring[3] == {5'b00_100, 7'd1, f0 + 20'd2}, $sformatf("video off: %08x", ovk.v_ring[3]));
            check(ovk.v_ring[2] == {5'b01_000, 7'd1, f0 + 20'd3}, $sformatf("a dim frame: %08x", ovk.v_ring[2]));
            check(ovk.v_ring[1] == {5'b10_011, 7'd1, f0 + 20'd4}, $sformatf("a darker frame, two layers off: %08x", ovk.v_ring[1]));
            check(ovk.v_ring[0] == {5'b11_000, 7'd1, f0 + 20'd6}, $sformatf("black after a normal frame: %08x", ovk.v_ring[0]));
            repeat (140) o_vframe(0, 3'b000);
            check(ovk.v_ring[0][26:20] == 7'd127, $sformatf("a long run counts %0d frames, want 127", ovk.v_ring[0][26:20]));
            o_vframe(9000, 3'b000);
            tick(200);
            check(ovk.copy[at + 53] == ovk.v_ring[0] && ovk.copy[at + 56] == ovk.v_ring[3] && ovk.copy[at + 60] == ovk.v_ring[4]
                  && ovk.copy[at + 63] == ovk.v_ring[7], "words 53-56 and 60-63 are not the entries, newest first");
        end
        // The cart has no load log: a data sector and an audio one write nothing
        o_dreq = {1'b1, 1'b0, 24'd3}; tick(20);
        o_dreq = {1'b0, 1'b1, 24'd4}; tick(20);
        check(ovk.tl[0][31:16] != 16'h4C44, $sformatf("the cart wrote a load log header: %08x", ovk.tl[0]));
        // Layers off in detail, words 110-121: what the program did in the last two runs of frames with a layer off
        begin
            automatic logic [19:0] f0;
            automatic logic [9:0] at;
            automatic logic [191:0] first_run;
            e_vopen(3'b000); e_vclose();        // closes the frame the bench was in
            e_vopen(3'b000); e_vclose();
            f0 = ear.frames[19:0];
            e_vopen(3'b101);                    // video and SPR off, three frames
            e_strobe(109); e_strobe(109); e_addr(23'h123456);
            e_vclose();
            check(ear.d_ent == {5'b11_101, 7'd1, f0} && ear.d_first == {1'b0, 8'd0, 23'h123456} && ear.d_fz == {16'd2, 16'd0},
                  $sformatf("a run's first frame: %08x %08x %08x", ear.d_ent, ear.d_first, ear.d_fz));
            e_vopen(3'b101);
            e_strobe(110); e_strobe(110); e_strobe(110);
            e_dmab[48] = 1; tick(2); e_dmab[48] = 0;
            ear.f_cyc = 18'd40000;              // a frame's worth of bus cycles, without driving them
            e_vclose();
            e_vopen(3'b101);
            e_strobe(111); e_strobe(112); e_addr(23'h606DA1);
            e_vclose();
            check(ear.d_ent == {5'b11_101, 7'd3, f0}, $sformatf("three frames with layers off: %08x, from frame %0d", ear.d_ent, f0));
            check(ear.d_first == {1'b1, 8'd2, 23'h123456}, $sformatf("DMA, cycles / 16384 and the first address: %08x", ear.d_first));
            check(ear.d_last == {9'd0, 23'h606DA1}, $sformatf("the last address: %08x", ear.d_last));
            check(ear.d_fz == {16'd2, 16'd1} && ear.d_spr == 32'd3 && ear.d_pcm == 32'd1,
                  $sformatf("writes: FIX and Z80 %08x, SPR %0d, PCM %0d", ear.d_fz, ear.d_spr, ear.d_pcm));
            first_run = {ear.d_ent, ear.d_first, ear.d_last, ear.d_fz, ear.d_spr, ear.d_pcm};
            e_vopen(3'b000); e_strobe(110); e_vclose();     // a frame with every layer on: its write is no run's
            check({ear.d_ent, ear.d_spr} == {first_run[191:160], 32'd3}, "a frame with every layer on changed the run before it");
            e_vopen(3'b010); e_strobe(110); e_vclose();     // FIX off, one frame: a new run, and the one before moves down
            check(ear.d_ent == {5'b11_010, 7'd1, f0 + 20'd4} && ear.d_spr == 32'd1 && ear.d_fz == 0 && !ear.d_first[31],
                  $sformatf("the second run: %08x, SPR %0d", ear.d_ent, ear.d_spr));
            check(ear.d_old == first_run, "the run before is not kept whole");
            e_vopen(3'b000); e_vclose();
            tick(200);
            at = {ear.run_no[2:0], 7'd0};
            check(ear.copy[at + 110] == ear.d_ent && ear.copy[at + 115] == ear.d_pcm && ear.copy[at + 116] == first_run[191:160]
                  && ear.copy[at + 121] == first_run[31:0], "words 110-121 are not the two runs, the newer first");
        end
        // Late STAT3 reads: sect[33] toggles
        repeat (3) begin e_sect33 = ~e_sect33; tick(3); end
        check(ear.n_late == 16'd3, $sformatf("%0d late STAT3 reads, want 3", ear.n_late));
        read_file(w);
        check(w[0] == 32'h4E47_5754, $sformatf("magic %08x", w[0]));
        check(w[1][15:0] == 16'd3, $sformatf("layout %0d", w[1][15:0]));
        check(w[2] == 32'(frames_seen) && w[22] == w[2], $sformatf("frames %0d %0d, the bench %0d", w[2], w[22], frames_seen));
        check(w[30] == 32'd1234 && w[27][31:28] == 4'd1, "disc words");
        for (int i = 57; i < 60; i++) check(w[i] == (32'h5A00_0000 | 32'(i)), $sformatf("word %0d is %08x, not the pattern", i, w[i]));
        check(w[48] == {2'd2, 1'b1, 29'd0}, $sformatf("word 48 %08x, want 24 MHz and the CD build", w[48]));
        check(w[127] == 32'h5A00_007F, $sformatf("word 127 is %08x", w[127]));

        // Settings, and the resets: the start, the one at frame 4, the one of the unanswered command
        check(w[32] == 32'b0_1_01_11_0_1, $sformatf("settings %08x", w[32]));
        check(w[33][31:24] == 8'd3, $sformatf("%0d resets", w[33][31:24]));
        check(w[33][23:0] == 24'd14, $sformatf("last reset released at frame %0d", w[33][23:0]));

        // The feeds, each by its word
        for (int i = 0; i < 8; i++) check(w[38 + i] == (i == 6 ? 32'hF006 : 32'hF000 + 32'(i)), $sformatf("fetch word %0d is %08x", 38 + i, w[38 + i]));
        check(w[46] == {1'b1, 31'(frames_seen - 3)}, $sformatf("first failed %08x, %0d frames seen", w[46], frames_seen));
        check(w[47] == {1'b1, 31'(frames_seen - 2)}, $sformatf("first late %08x, %0d frames seen", w[47], frames_seen));
        check(w[64] == 32'hF008 && w[65] == 32'hF009, $sformatf("fetch words 64, 65: %08x %08x", w[64], w[65]));
        for (int i = 0; i < 12; i++) check(w[66 + i] == 32'hD000 + 32'(i), $sformatf("DMA word %0d is %08x", 66 + i, w[66 + i]));
        check(w[78] == 32'd2 && w[79] == 32'd2, $sformatf("nowhere %0d, swaps %0d", w[78], w[79]));
        check(w[1][23:19] == 5'd12, $sformatf("revision %0d", w[1][23:19]));
        check(w[106] == {16'd2, 16'd1}, $sformatf("hold: %08x, want 2 holds, 1 ran out", w[106]));
        check(w[108] == 32'd3, $sformatf("sectors: %0d taken", w[108]));
        check(lost_frame[9] == lost_frame[0] + 1, "the lost sectors span a frame");
        for (int i = 0; i < 4; i++) check(w[122 + i] == 32'hCD00_0000 + 32'(i), $sformatf("ring word %0d is %08x", 122 + i, w[122 + i]));
        check(w[109] == 32'h0100_0009 && (w[126] & ~32'h0000_0FF8) == 32'd1,      // bits 11:3 are the trace's next word
              $sformatf("the last sector offered: %08x %08x", w[109], w[126]));
        for (int i = 107; i < 126; i++) if (i != 108 && i != 109 && (i < 122 || i > 125)) check(w[i] == 0, $sformatf("word %0d is %08x with no BIOS write", i, w[i]));

        // The ring: entry 0 the unanswered 11th, then 10, 9 ... with their answers. Frames: each command's own
        check(w[80] == 32'd10, $sformatf("%0d commands", w[80]));    // of 11 sent: cmd_word(1) is a TOC, which the ring leaves out
        for (int e = 0; e < 8; e++) begin
            automatic int i = 10 - e;
            automatic logic [39:0] c = cmd_word(i), s = i == 10 ? 40'd0 : ans_word(i);
            automatic logic [31:0] a = w[81 + 3 * e];
            check(a[15:8] == c[39:32] && w[82 + 3 * e] == c[31:0], $sformatf("ring %0d: command %02x%08x, want %010x", e, a[15:8], w[82 + 3 * e], c));
            check(a[7:0] == s[39:32] && w[83 + 3 * e] == s[31:0], $sformatf("ring %0d: answer %02x%08x, want %010x", e, a[7:0], w[83 + 3 * e], s));
            check(a[31:16] == 16'(4 + i), $sformatf("ring %0d: frame %0d, want %0d", e, a[31:16], 4 + i));
        end
        begin
            automatic int fd = $fopen("wait_l3.sav", "wb");
            foreach (w[i]) $fwrite(fd, "%c%c%c%c", w[i][31:24], w[i][23:16], w[i][15:8], w[i][7:0]);
            $fclose(fd);
        end

        // ---- The samples, read while they are the last 4 ----
        for (int f = 0; f < 5; f++) begin
            repeat (300 * (f + 1)) bus(23'h200000 + 23'(f), f == 2);
            frame();
        end
        tick(4);
        read_file(w);
        for (int k = 0; k < 4; k++) begin
            automatic int f = 4 - k;
            automatic logic [31:0] want = {f == 2, 8'((300 * (f + 1)) >> 8), 23'h200000 + 23'(f)};
            check(w[34 + k][22:0] == want[22:0], $sformatf("sample %0d: address %06x, want %06x", k, w[34 + k][22:0], want[22:0]));
            check(w[34 + k][31] == want[31], $sformatf("sample %0d: writes %b", k, w[34 + k][31]));
            check(w[34 + k][30:23] == want[30:23], $sformatf("sample %0d: cycles %0d x 256, want %0d", k, w[34 + k][30:23], want[30:23]));
        end

        // ---- Reset held: the record stays as the last frame before it left it ----
        nRESET = 0;
        tick(3);
        frame();
        read_file(w);
        check(w[32][7] == 1'b0, "a frame in reset reached the record");
        check(w[34][22:0] == 23'h200004, $sformatf("a frame in reset took a sample: %06x", w[34][22:0]));
        nRESET = 1;
        tick(3);

        // ---- Runs: what the host loads survives, and the numbering goes on from it ----
        r_write(4, 0, 32'h4E47_5754);
        r_write(4, 2, 32'd1111);
        r_write(4, 105, 32'd12);
        r_write(1, 2, 32'd2222);
        r_write(1, 105, 32'd9);
        r_write(7, 0, 32'hFFFF_FFFF);           // what the host gives a new file: all ones, and no run number
        r_write(7, 105, 32'hFFFF_FFFF);
        r_frame();                              // in reset: nothing touches the file
        r_expect(0, 0, 32'd0, "a frame before the first start");
        r_run = 1;
        r_nRESET = 1;
        tick(3);
        r_frame();
        // A load in the run after the loaded file: its entry goes where the loaded header said
        r_dreq = {1'b1, 1'b0, 24'd5};
        tick(20);
        r_dreq = {1'b0, 1'b1, 24'd6};
        tick(20);
        check(runs.tl[29][31:28] == 4'd3 && runs.tl[30] == {16'd0, 16'd1}, $sformatf("the load after a loaded header: %08x %08x", runs.tl[29], runs.tl[30]));
        r_expect(8, 0, 32'h4C44_0008, "the load log header after a loaded one");
        r_expect(5, 105, 32'd13, "the first run after a loaded file");
        r_expect(5, 0, 32'h4E47_5754, "the run's own record");
        r_expect(4, 2, 32'd1111, "a loaded record");
        r_expect(4, 105, 32'd12, "a loaded record");
        r_expect(1, 2, 32'd2222, "a loaded record");
        r_expect(5, 57, 32'h5A00_0039, "the pattern in a run's record");
        r_expect(3, 57, 32'h5A00_0039, "the pattern in an empty record");

        // ---- A reset asks for a save at once, keeps the last frame, and the next run has its own record ----
        check(r_saves == 0, $sformatf("%0d saves before any reset", r_saves));
        r_frame();
        begin
            automatic logic [31:0] frames_before;
            r_read(5, 2, frames_before);
            r_nRESET = 0;
            repeat (8) @(posedge clk74);
            check(r_saves == 1, $sformatf("%0d saves as a reset starts, want 1", r_saves));
            r_frame();
            r_expect(5, 2, frames_before, "a frame in reset");
            check(frames_before != 0, "no frames in the run's record");
            r_nRESET = 1;
            tick(3);
            r_frame();
            r_expect(6, 105, 32'd14, "the run after a reset");
            r_expect(5, 105, 32'd13, "the run before it");
            r_expect(5, 2, frames_before, "the run before it");
        end
        check(r_saves == 1, $sformatf("%0d saves, the release of a reset asks for none", r_saves));

        // ---- The periodic save: one request where timer[28] rises ----
        runs.timer = 29'h0FFF_FFF0;
        repeat (40) @(posedge clk74);
        check(r_saves == 2, $sformatf("%0d saves after the timer, want 2", r_saves));
        runs.timer = 29'h1FFF_FFF0;
        repeat (40) @(posedge clk74);
        check(r_saves == 2, $sformatf("%0d saves as timer[28] falls, want 2", r_saves));

        // ---- Eight more runs: the ring overwrites the oldest ----
        repeat (8) begin
            r_nRESET = 0;
            tick(4);
            r_nRESET = 1;
            tick(4);
            r_frame();
        end
        r_expect(6, 105, 32'd22, "a record reused");
        r_expect(5, 105, 32'd21, "the run before");

        // ---- Quit: no save asked as the host stops the core ----
        begin
            automatic int saves_before = r_saves;
            r_run = 0;
            r_nRESET = 0;
            repeat (8) @(posedge clk74);
            check(r_saves == saves_before, "a save asked with the core stopped");
        end

        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("tb_wait_counter: passed");
        $finish;
    end

    initial begin
        #(100.0e6);
        $fatal(1, "timeout");
    end
endmodule
