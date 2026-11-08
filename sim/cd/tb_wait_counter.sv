// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// rtl/test/wait_counter.sv's layout 3 on its own, with made-up feeds, in seconds: sim/topcd holds the same words against
// the real core, in an hour. Every word of the file by its number, the rings' order past their depth, and layout 1,
// the cartridge's, as it was. Writes wait_l3.sav for tools/check_wait_save.py.
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
    wire  [31:0]  rd3, rd1;

    wait_counter #(.LAYOUT(3)) dut (
        .clk_48m(clk48), .nRESET, .nAS, .rom_zone(1'b0), .at_req(2'd1), .vblank, .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr, .bridge_rd, .bridge_rd_data(rd3), .bridge_wr(1'b0), .bridge_wr_data(32'd0), .run(1'b0), .save_now(),
        .save_done(1'b0), .save_err(3'd0),
        .cdd, .disc_bin_size(32'd1234), .disc_reason(4'd1), .cd2, .fetch, .dma, .sect, .dmab(49'd0), .bus68(18'd0), .dreq(26'd0)
    );

    wait_counter #(.LAYOUT(1)) cart (
        .clk_48m(clk48), .nRESET, .nAS, .rom_zone(1'b0), .at_req(2'd1), .vblank, .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr, .bridge_rd, .bridge_rd_data(rd1), .bridge_wr(1'b0), .bridge_wr_data(32'd0), .run(1'b0), .save_now(),
        .save_done(1'b0), .save_err(3'd0),
        .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0), .cd2(54'd0), .fetch(320'd0), .dma(384'd0), .sect(37'd0), .dmab(49'd0), .bus68(18'd0), .dreq(26'd0)
    );

    // The same layout on its own, for the runs: a file the host loads, a record per run, a save as a reset starts
    logic         r_nRESET = 0, r_vblank = 0, r_wr = 0, r_rd = 0, r_run = 0;
    logic [31:0]  r_addr = 32'h8000_0000, r_wdata = 0;
    wire  [31:0]  r_q;
    wire          r_save;
    int           r_saves = 0;
    always @(posedge clk74) if (r_save) r_saves++;

    wait_counter #(.LAYOUT(3)) runs (
        .clk_48m(clk48), .nRESET(r_nRESET), .nAS(1'b1), .rom_zone(1'b0), .at_req(2'd1), .vblank(r_vblank), .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr(r_addr), .bridge_rd(r_rd), .bridge_rd_data(r_q),
        .bridge_wr(r_wr), .bridge_wr_data(r_wdata), .run(r_run), .save_now(r_save),
        .save_done(1'b0), .save_err(3'd0),
        .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0), .cd2(54'd0), .fetch(320'd0), .dma(384'd0), .sect(37'd0), .dmab(49'd0), .bus68(18'd0), .dreq(26'd0)
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
    wait_counter #(.LAYOUT(3)) ear (
        .clk_48m(clk48), .nRESET(e_nRESET), .nAS(e_nAS), .rom_zone(1'b0), .at_req(2'd1), .vblank(e_vblank), .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr(32'h8000_0000), .bridge_rd(1'b0), .bridge_rd_data(), .bridge_wr(1'b0), .bridge_wr_data(32'd0),
        .run(1'b0), .save_now(), .save_done(1'b0), .save_err(3'd0),
        .cdd(e_cdd), .disc_bin_size(32'd0), .disc_reason(4'd0), .cd2(e_cd2), .fetch(320'd0), .dma(384'd0), .sect({e_fate, e_sect33, e_info}), .dmab(e_dmab), .bus68(e_bus68), .dreq(e_dreq)
    );

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
    logic         y_nRESET = 0, y_nAS = 1, y_nUDS = 1, y_nLDS = 1, y_rw = 1, y_cdz = 1;
    logic [23:1]  y_addr = 0;
    logic [15:0]  y_data = 0;
    wire  [15:0]  y_out;
    wire          y_unibios;
    wire  [15:0]  y_requested;
    cd_bios_model model (.clk(clk48), .nRESET(y_nRESET), .nAS(y_nAS), .nUDS(y_nUDS), .nLDS(y_nLDS), .M68K_RW(y_rw),
                         .M68K_ADDR(y_addr), .data_in(y_data), .system_cdz(y_cdz), .data_out(y_out),
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
        y_cdz = 1;
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
        y_cdz = 0;
        y_write(24'h10FE32, 16'h0203, 1, 1, seen);
        check(seen == 16'h0003, "CD/CDZ off, CDZ written: not stored as TOPLOAD");
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

    task automatic read_file(input bit is_cart, output logic [31:0] w [FILE_WORDS]);
        for (int i = 0; i < (is_cart ? 64 : FILE_WORDS); i++) begin
            @(posedge clk74);
            #1 bridge_addr = 32'h8000_0000 + 32'((is_cart ? 0 : dut.run_no[2:0] * 512) + i * 4);
            repeat (3) @(posedge clk74);
            #1 bridge_rd = 1;
            @(posedge clk74);
            #1 bridge_rd = 0;
            @(posedge clk74);
            #1 w[i] = is_cart ? rd1 : rd3;
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

        // ---- The timeline, on its own instance, CD/CDZ on: tl_sel 1 ----
        e_cd2[0] = 1;
        tick(2);
        e_nRESET = 1;
        tick(4);
        check(ear.g_cd.tl_on && ear.g_cd.tl_sel, $sformatf("timeline on %0d, setting %0d", ear.g_cd.tl_on, ear.g_cd.tl_sel));
        e_cdd[39:0] = 40'hD071200003;           // PLAY to 00:02:17: entry 1
        e_cd2[7] = 1; tick; e_cd2[7] = 0; tick(4);
        e_cdd[39:0] = 40'hA000000000;           // IDLE: left out
        e_cd2[7] = 1; tick; e_cd2[7] = 0; tick(4);
        e_write(24'h10F650, 16'h0200, 2'b10);   // the queue's head: left out
        e_write(24'h10F650, 16'h0001, 2'b01);   // its tail: entry 2
        e_write(24'h10F688, 16'h0058, 2'b11);   // the count: entry 3
        e_write(24'h10F688, 16'h0058, 2'b11);   // the same again: left out
        e_write(24'hFF0002, 16'h0550, 2'b11);   // not watched
        e_bus(24'h10F688, 0);                   // a read
        e_dreq = {1'b1, 1'b0, 24'd17}; tick(4); // a data sector asked for: entry 4
        e_info = {1'b1, 32'h0100_1702};         // and offered, DMA'd: entry 5
        e_fate[2] = 1; tick(4);
        e_cdd[83:80] = 4'h1; e_cdd[107:84] = 24'd17; tick(4);   // the status: entry 6
        e_dreq = {1'b0, 1'b1, 24'd1000}; tick(4);       // the first audio one: entry 7
        e_dreq = {1'b1, 1'b1, 24'd1001}; tick(4);       // the next: left out
        e_cdd[39:0] = 40'h7012850603;           // the music: entry 8, the trigger
        e_cd2[7] = 1; tick; e_cd2[7] = 0; tick(4);
        begin
            automatic bit [3:0] want_ty [1:8] = '{4'd0, 4'd5, 4'd5, 4'd1, 4'd2, 4'd6, 4'd1, 4'd0};
            automatic logic [31:0] want_pay [1:8] = '{32'h0712_0003, {11'd0, 3'd0, 2'b01, 16'h0001}, {11'd0, 3'd2, 2'b11, 16'h0058},
                32'd17, 32'h0100_1702, {4'h1, 4'd0, 24'd17}, {1'b1, 7'd0, 24'd1000}, 32'h0128_5063};
            for (int k = 1; k <= 8; k++) begin
                automatic logic [31:0] a = ear.tl[{1'b1, 8'(k), 1'b0}], d = ear.tl[{1'b1, 8'(k), 1'b1}];
                check(a[31:28] == want_ty[k] && d == want_pay[k], $sformatf("timeline entry %0d: type %0d payload %08x, want %0d %08x", k, a[31:28], d, want_ty[k], want_pay[k]));
            end
            check(ear.tl[{1'b1, 8'd1, 1'b0}][27:0] <= ear.tl[{1'b1, 8'd8, 1'b0}][27:0], "the timeline's time went back");
            check(ear.tl[{1'b1, 9'd0}] == 0, "entry 0 written before the timeline stopped");
        end
        // 96 entries from the music, which is the first: 95 more stop it, and one after that is left out
        begin
            automatic logic t = e_dreq[25];
            for (int k = 0; k < 96; k++) begin
                t = ~t;
                e_dreq = {t, 1'b0, 24'(2000 + k)};
                tick(5);
            end
        end
        tick(6);
        check(ear.g_cd.tl_done == 2'b10 && !ear.g_cd.tl_on, $sformatf("done %b, on %0d", ear.g_cd.tl_done, ear.g_cd.tl_on));
        check(ear.tl[{1'b1, 9'd0}] == {16'h544C, 7'd0, 1'b0, 8'd104}, $sformatf("entry 0: %08x", ear.tl[{1'b1, 9'd0}]));
        check(ear.tl[{1'b1, 9'd1}] == ear.run_no, $sformatf("the run in entry 0: %0d", ear.tl[{1'b1, 9'd1}]));
        check(ear.tl[{1'b1, 8'd103, 1'b1}] == 32'(2000 + 94), $sformatf("the last entry: %0d", ear.tl[{1'b1, 8'd103, 1'b1}]));
        // A reset with the same setting keeps it; with the other it records in the other half
        e_nRESET = 0; tick(4); e_nRESET = 1; tick(4);
        check(!ear.g_cd.tl_on && ear.tl[{1'b1, 9'd0}] != 0, "a Reset Core overwrote the stopped timeline");
        e_nRESET = 0; e_cd2[0] = 0; tick(4); e_nRESET = 1; tick(4);
        check(ear.g_cd.tl_on && !ear.g_cd.tl_sel, "no timeline for the other setting");
        e_cdd[39:0] = 40'hD071200003;
        e_cd2[7] = 1; tick; e_cd2[7] = 0; tick(4);
        check(ear.tl[{1'b0, 8'd1, 1'b1}] == 32'h0712_0003, $sformatf("the other half's first entry: %08x", ear.tl[{1'b0, 8'd1, 1'b1}]));
        // The file's second 4 KB goes to the timelines: no run number from there, and it reads back through the bridge
        begin
            automatic logic [31:0] was = runs.loaded_run;
            r_write(8, 105, 32'd99);
            repeat (4) @(posedge clk74);
            check(runs.loaded_run == was, $sformatf("a word of the timeline changed the loaded run to %0d", runs.loaded_run));
            r_expect(8, 105, 32'd99, "a timeline word through the bridge");
        end
        // Late STAT3 reads: sect[33] toggles
        repeat (3) begin e_sect33 = ~e_sect33; tick(3); end
        check(ear.g_cd.n_late == 16'd3, $sformatf("%0d late STAT3 reads, want 3", ear.g_cd.n_late));
        read_file(0, w);
        check(w[0] == 32'h4E47_5754, $sformatf("magic %08x", w[0]));
        check(w[1][15:0] == 16'd3, $sformatf("layout %0d", w[1][15:0]));
        check(w[2] == 32'(frames_seen) && w[22] == w[2], $sformatf("frames %0d %0d, the bench %0d", w[2], w[22], frames_seen));
        check(w[30] == 32'd1234 && w[27][31:28] == 4'd1, "disc words");
        for (int i = 48; i < 64; i++) check(w[i] == (32'h5A00_0000 | 32'(i)), $sformatf("word %0d is %08x, not the pattern", i, w[i]));
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
        check(w[1][23:19] == 5'd6, $sformatf("revision %0d", w[1][23:19]));
        check(w[106] == {16'd2, 16'd1}, $sformatf("hold: %08x, want 2 holds, 1 ran out", w[106]));
        check(w[108] == 32'd3, $sformatf("sectors: %0d taken", w[108]));
        check(lost_frame[9] == lost_frame[0] + 1, "the lost sectors span a frame");
        check(w[109] == 32'h0100_0009 && w[126] == 32'd1, $sformatf("the last sector offered: %08x %08x", w[109], w[126]));
        for (int i = 107; i < 126; i++) if (i != 108 && i != 109) check(w[i] == 0, $sformatf("word %0d is %08x with no BIOS write", i, w[i]));

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
        read_file(0, w);
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
        read_file(0, w);
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
        r_expect(5, 105, 32'd13, "the first run after a loaded file");
        r_expect(5, 0, 32'h4E47_5754, "the run's own record");
        r_expect(4, 2, 32'd1111, "a loaded record");
        r_expect(4, 105, 32'd12, "a loaded record");
        r_expect(1, 2, 32'd2222, "a loaded record");
        r_expect(5, 48, 32'h5A00_0030, "the pattern in a run's record");
        r_expect(3, 48, 32'h5A00_0030, "the pattern in an empty record");

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

        // ---- Layout 1, the cartridge's file as it was: the pattern at 32-63 ----
        frame();
        read_file(1, w);
        check(w[1][15:0] == 16'd1, $sformatf("cart: layout %0d", w[1][15:0]));
        for (int i = 32; i < 64; i++) check(w[i] == (32'h5A00_0000 | 32'(i)), $sformatf("cart: word %0d is %08x", i, w[i]));
        check(w[2] == w[22] && w[2] != 0, "cart: frames");

        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("tb_wait_counter: passed");
        $finish;
    end

    initial begin
        #(100.0e6);
        $fatal(1, "timeout");
    end
endmodule
