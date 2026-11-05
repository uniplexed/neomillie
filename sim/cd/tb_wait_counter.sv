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
    logic [33:0]  cd2 = 0;
    logic [0:9][31:0]  fetch = 0;
    logic [0:11][31:0] dma = 0;
    wire  [31:0]  rd3, rd1;

    wait_counter #(.LAYOUT(3)) dut (
        .clk_48m(clk48), .nRESET, .nAS, .rom_zone(1'b0), .at_req(2'd1), .vblank, .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr, .bridge_rd, .bridge_rd_data(rd3), .run(1'b0), .save_now(),
        .save_done(1'b0), .save_err(3'd0),
        .cdd, .disc_bin_size(32'd1234), .disc_reason(4'd1), .cd2, .fetch, .dma
    );

    wait_counter #(.LAYOUT(1)) cart (
        .clk_48m(clk48), .nRESET, .nAS, .rom_zone(1'b0), .at_req(2'd1), .vblank, .c1_wait(3'd0),
        .clk_74a(clk74), .bridge_addr, .bridge_rd, .bridge_rd_data(rd1), .run(1'b0), .save_now(),
        .save_done(1'b0), .save_err(3'd0),
        .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0), .cd2(34'd0), .fetch(320'd0), .dma(384'd0)
    );

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
    task automatic frame();
        vblank = 1;
        tick(120);      // the copy, with its 105 words
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
            #1 bridge_addr = 32'h8000_0000 + 32'(i * 4);
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
        frame();
        tick(4);

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
        check(w[46] == {1'b1, 31'(frames_seen - 2)}, $sformatf("first failed %08x, %0d frames seen", w[46], frames_seen));
        check(w[47] == {1'b1, 31'(frames_seen - 1)}, $sformatf("first late %08x, %0d frames seen", w[47], frames_seen));
        check(w[64] == 32'hF008 && w[65] == 32'hF009, $sformatf("fetch words 64, 65: %08x %08x", w[64], w[65]));
        for (int i = 0; i < 12; i++) check(w[66 + i] == 32'hD000 + 32'(i), $sformatf("DMA word %0d is %08x", 66 + i, w[66 + i]));
        check(w[78] == 32'd2 && w[79] == 32'd2, $sformatf("nowhere %0d, swaps %0d", w[78], w[79]));

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

        // ---- Reset held: the bit, and the samples stop ----
        nRESET = 0;
        tick(3);
        frame();
        read_file(0, w);
        check(w[32][7] == 1'b1, "the in-reset bit is low in a reset");
        check(w[34][22:0] == 23'h200004, $sformatf("a frame in reset took a sample: %06x", w[34][22:0]));
        nRESET = 1;
        tick(3);

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
