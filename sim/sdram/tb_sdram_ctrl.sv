// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// sdram_ctrl against the checking SDRAM model. The master behaves like the MiSTer
// sdram_mux: it holds rd/wr until 'ready' falls, then waits for 'ready' to rise; on a read
// dout is word 0 in the first cycle ready is seen high and words 1..3 follow.
`timescale 1ns/1ps
module tb_sdram_ctrl;
    localparam real PERIOD = 10.34;     // shortest period of the design (AES 96.67 MHz): strictest ns limits

    logic        clk = 0;
    logic        init = 1;
    logic [25:1] addr = 0;
    logic [15:0] din = 0;
    logic  [1:0] bs = 0;
    logic        wr = 0, rd = 0, refresh = 0;
    wire  [15:0] dout;
    wire         ready;

    tri   [15:0] dram_dq;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

    always #(PERIOD / 2) clk = ~clk;

    sdram_ctrl dut (
        .init(init), .clk(clk),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba),
        .dram_we_n(dram_we_n), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_cke(dram_cke), .dram_clk(dram_clk),
        .addr(addr), .dout(dout), .din(din), .bs(bs), .wr(wr), .rd(rd),
        .refresh(refresh), .ready(ready)
    );

    sdram_model #(.CLK_NS(PERIOD)) mem (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n),
        .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n), .dram_a(dram_a),
        .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );

    // Watchdog: the whole bench takes about 1.4 ms of simulated time
    initial begin
        #5_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;

    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    task automatic do_write(input logic [25:1] a, input logic [15:0] d, input logic [1:0] b);
        @(posedge clk);
        addr <= a; din <= d; bs <= b; wr <= 1;
        do @(posedge clk); while (ready);   // accepted: ready fell
        wr <= 0;
        while (!ready) @(posedge clk);
    endtask

    task automatic do_read(input logic [25:1] a, output logic [15:0] w [4]);
        @(posedge clk);
        addr <= a; rd <= 1;
        do @(posedge clk); while (ready);
        rd <= 0;
        while (!ready) @(posedge clk);
        w[0] = dout;
        for (int i = 1; i < 4; i++) begin
            @(posedge clk);
            check(ready, "ready dropped during the burst");
            w[i] = dout;
        end
    endtask

    task automatic test_write_then_burst_read();
        localparam logic [25:1] A0 = 25'h100000;
        localparam logic [25:1] A1 = 25'h1A55A50;   // other bank, row and column
        logic [15:0] w [4];
        for (int i = 0; i < 4; i++) do_write(A0 + i, 16'hA000 + 16'(i) * 16'h111, 2'b11);
        for (int i = 0; i < 4; i++) do_write(A1 + i, 16'h5000 + 16'(i) * 16'h222, 2'b11);
        do_read(A0, w);
        for (int i = 0; i < 4; i++)
            check(w[i] === 16'hA000 + 16'(i) * 16'h111, $sformatf("burst A0 word %0d = %h", i, w[i]));
        do_read(A1, w);
        for (int i = 0; i < 4; i++)
            check(w[i] === 16'h5000 + 16'(i) * 16'h222, $sformatf("burst A1 word %0d = %h", i, w[i]));
        $display("test_write_then_burst_read done");
    endtask

    task automatic test_byte_mask_write();
        localparam logic [25:1] A = 25'h0200010;
        logic [15:0] w [4];
        do_write(A + 0, 16'hABCD, 2'b11);
        do_write(A + 0, 16'h0012, 2'b01);   // low byte only: high byte stays
        do_write(A + 1, 16'h1234, 2'b11);
        do_write(A + 1, 16'h9900, 2'b10);   // high byte only: low byte stays
        do_write(A + 2, 16'hFFFF, 2'b11);
        do_write(A + 2, 16'h0000, 2'b00);   // no byte at all
        do_read(A, w);
        check(w[0] === 16'hAB12, $sformatf("bs=01 word = %h, expected AB12", w[0]));
        check(w[1] === 16'h9934, $sformatf("bs=10 word = %h, expected 9934", w[1]));
        check(w[2] === 16'hFFFF, $sformatf("bs=00 word = %h, expected FFFF", w[2]));
        $display("test_byte_mask_write done");
    endtask

    // Back-to-back requests, each one with a refresh toggle issued together with the next
    // request. early=0: the next request comes in the first cycle 'ready' is seen high after
    // the previous one (what a master reacting to 'ready' can do at best). early=1: the next
    // request is already pending when the previous one is accepted, so the controller itself
    // has to enforce the minimum READ/WRITE -> ACTIVE/REFRESH gap and tRFC; the model fails
    // any command that lands before the auto precharge or the refresh has finished.
    task automatic issue_next(input logic nxt_wr, input logic [25:1] nxt_a,
                              input logic [15:0] nxt_d, input bit tog);
        addr <= nxt_a; din <= nxt_d; bs <= 2'b11; wr <= nxt_wr; rd <= !nxt_wr;
        if (tog) refresh <= ~refresh;
    endtask

    task automatic chained_read(input logic [25:1] a, output logic [15:0] w [4],
                                input logic nxt_wr, input logic [25:1] nxt_a,
                                input logic [15:0] nxt_d, input bit tog, input bit early);
        @(posedge clk);
        addr <= a; rd <= 1;
        do @(posedge clk); while (ready);   // accepted
        if (early) issue_next(nxt_wr, nxt_a, nxt_d, tog); else rd <= 0;
        while (!ready) @(posedge clk);
        w[0] = dout;
        if (!early) issue_next(nxt_wr, nxt_a, nxt_d, tog);
        for (int i = 1; i < 4; i++) begin
            @(posedge clk);
            w[i] = dout;     // the controller may already have accepted the next request
        end
        while (ready) @(posedge clk);       // next request accepted
        wr <= 0; rd <= 0;
        while (!ready) @(posedge clk);
    endtask

    task automatic chained_write(input logic [25:1] a, input logic [15:0] d,
                                 input logic nxt_wr, input logic [25:1] nxt_a,
                                 input logic [15:0] nxt_d, input bit tog, input bit early);
        @(posedge clk);
        addr <= a; din <= d; bs <= 2'b11; wr <= 1;
        do @(posedge clk); while (ready);   // accepted
        if (early) issue_next(nxt_wr, nxt_a, nxt_d, tog); else wr <= 0;
        while (!ready) @(posedge clk);
        if (!early) issue_next(nxt_wr, nxt_a, nxt_d, tog);
        while (ready) @(posedge clk);       // next request accepted
        wr <= 0; rd <= 0;
        while (!ready) @(posedge clk);
    endtask

    task automatic test_back_to_back();
        localparam logic [25:1] A = 25'h0300000;
        logic [15:0] w [4];
        int base = mem.refresh_count;
        for (int e = 0; e < 2; e++) begin
            for (int i = 0; i < 6; i++) begin
                logic [25:1] b = A + 25'(e * 64 + i * 8);
                // write -> write + refresh, write -> read + refresh
                chained_write(b + 0, 16'h1000 + 16'(i), 1'b1, b + 1, 16'h2000 + 16'(i), 1'b1, e[0]);
                chained_write(b + 2, 16'h3000 + 16'(i), 1'b0, b + 0, 16'h0,             1'b1, e[0]);
                // read -> write + refresh, read -> read + refresh
                chained_read(b + 0, w, 1'b1, b + 3, 16'h4000 + 16'(i), 1'b1, e[0]);
                check(w[0] === 16'h1000 + 16'(i) && w[1] === 16'h2000 + 16'(i) && w[2] === 16'h3000 + 16'(i),
                      $sformatf("chained read e=%0d i=%0d = %h %h %h", e, i, w[0], w[1], w[2]));
                chained_read(b + 0, w, 1'b0, b + 0, 16'h0, 1'b1, e[0]);
                check(w[3] === 16'h4000 + 16'(i), $sformatf("chained read e=%0d i=%0d word 3 = %h", e, i, w[3]));
            end
        end
        check(mem.refresh_count - base == 48, $sformatf("expected 48 refreshes, model saw %0d", mem.refresh_count - base));
        $display("test_back_to_back done");
    endtask

    task automatic test_refresh_rate();
        realtime t0;
        logic [15:0] w [4];
        int base = mem.refresh_count;
        t0 = $realtime;
        while ($realtime - t0 < 1000000.0) begin    // 1 ms
            #7800;
            refresh = ~refresh;
        end
        #1000;
        check(mem.refresh_count - base >= 128,
              $sformatf("only %0d refreshes in 1 ms", mem.refresh_count - base));
        // Still alive and data intact after the refreshes
        do_read(25'h100000, w);
        check(w[3] === 16'hA333, $sformatf("read after refresh = %h", w[3]));
        $display("test_refresh_rate done: %0d refreshes", mem.refresh_count - base);
    endtask

    initial begin
        repeat (4) @(posedge clk);
        init <= 0;
        wait (ready);
        repeat (4) @(posedge clk);
        check(mem.init_done, "SDRAM model init sequence incomplete when the controller became ready");
        test_write_then_burst_read();
        test_byte_mask_write();
        test_back_to_back();
        test_refresh_rate();
        check(mem.error_count == 0, "SDRAM model reported protocol or timing errors");
        if (failures != 0) $fatal(1, "%0d check(s) failed", failures);
        $display("PASS tb_sdram_ctrl");
        $finish;
    end
endmodule
