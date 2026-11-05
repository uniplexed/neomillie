// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// cram_ctrl against the checking PSRAM model. The master is registered: it holds req until it
// sees ack and changes or drops req on that edge. A second controller with RD_WAIT=3 runs
// against a quiet model, for the checks that must fire.
`timescale 1ns/1ps
module tb_cram_ctrl;
    localparam real PERIOD = 10.34;     // shortest period of the design (AES 96.67 MHz): strictest ns limits
    localparam logic [23:1] DIE1 = 23'h400000;
    localparam logic [23:1] TOP  = 23'h3FFFFF;

    logic        clk = 0, rst = 1;
    logic        req = 0, we = 0, use_short = 0;
    logic [23:1] addr = 0;
    logic [15:0] wdata = 0;
    logic  [1:0] be = 0;

    wire  [15:0] rdata_m, rdata_s;
    wire         ack_m, ack_s;
    wire  [15:0] rdata = use_short ? rdata_s : rdata_m;
    wire         ack   = use_short ? ack_s : ack_m;

    tri   [15:0] dq_m, dq_s;
    wire [21:16] a_m, a_s;
    wire         clk_m, cre_m, adv_m, ce0_m, ce1_m, oe_m, we_m, ub_m, lb_m;
    wire         clk_s, cre_s, adv_s, ce0_s, ce1_s, oe_s, we_s, ub_s, lb_s;

    always #(PERIOD / 2) clk = ~clk;

    cram_ctrl dut (
        .clk(clk), .rst(rst),
        .cram_a(a_m), .cram_dq(dq_m), .cram_wait(1'b0), .cram_clk(clk_m), .cram_adv_n(adv_m),
        .cram_cre(cre_m), .cram_ce0_n(ce0_m), .cram_ce1_n(ce1_m), .cram_oe_n(oe_m), .cram_we_n(we_m),
        .cram_ub_n(ub_m), .cram_lb_n(lb_m),
        .req(req && !use_short), .we(we), .addr(addr), .wdata(wdata), .be(be),
        .rdata(rdata_m), .ack(ack_m)
    );

    psram_model mem (
        .a(a_m), .dq(dq_m), .clk(clk_m), .cre(cre_m), .adv_n(adv_m), .ce0_n(ce0_m), .ce1_n(ce1_m),
        .oe_n(oe_m), .we_n(we_m), .ub_n(ub_m), .lb_n(lb_m), .fpga_dq_oe(dut.dq_oe)
    );

    cram_ctrl #(.RD_WAIT(3)) dut_short (
        .clk(clk), .rst(rst),
        .cram_a(a_s), .cram_dq(dq_s), .cram_wait(1'b0), .cram_clk(clk_s), .cram_adv_n(adv_s),
        .cram_cre(cre_s), .cram_ce0_n(ce0_s), .cram_ce1_n(ce1_s), .cram_oe_n(oe_s), .cram_we_n(we_s),
        .cram_ub_n(ub_s), .cram_lb_n(lb_s),
        .req(req && use_short), .we(we), .addr(addr), .wdata(wdata), .be(be),
        .rdata(rdata_s), .ack(ack_s)
    );

    psram_model #(.QUIET(1)) mem_short (
        .a(a_s), .dq(dq_s), .clk(clk_s), .cre(cre_s), .adv_n(adv_s), .ce0_n(ce0_s), .ce1_n(ce1_s),
        .oe_n(oe_s), .we_n(we_s), .ub_n(ub_s), .lb_n(lb_s), .fpga_dq_oe(dut_short.dq_oe)
    );

    // Watchdog: the whole bench takes about 40 us of simulated time
    initial begin
        #1_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;

    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    // One request, driven 1 ns after the clock edge like a registered master. A following call
    // in the same time step keeps req high for the clock (back to back).
    task automatic access(input logic w, input logic [23:1] a, input logic [15:0] d,
                          input logic [1:0] b, output logic [15:0] q);
        addr = a; we = w; wdata = d; be = b; req = 1;
        do @(posedge clk); while (!ack);
        q = rdata;
        #1 req = 0;
    endtask

    task automatic write_word(input logic [23:1] a, input logic [15:0] d, input logic [1:0] b = 2'b11);
        logic [15:0] unused;
        access(1'b1, a, d, b, unused);
    endtask

    task automatic read_expect(input logic [23:1] a, input logic [15:0] expected);
        logic [15:0] q;
        access(1'b0, a, 16'hxxxx, 2'b00, q);
        check(q === expected, $sformatf("read %h = %h, expected %h", a, q, expected));
    endtask

    task automatic test_word_write_read();
        int base = mem.access_count;
        // Same low address on both dies, and an address with A[21:16] and DQ bits all different
        write_word(23'h000000, 16'h1111);
        write_word(DIE1 | 23'h000000, 16'h2222);
        write_word(23'h2A5555, 16'hA55A);
        write_word(DIE1 | 23'h15AAAA, 16'h5AA5);
        read_expect(23'h000000, 16'h1111);
        read_expect(DIE1 | 23'h000000, 16'h2222);
        read_expect(23'h2A5555, 16'hA55A);
        read_expect(DIE1 | 23'h15AAAA, 16'h5AA5);
        repeat (20) @(posedge clk);     // no access may start on a stale req
        check(mem.access_count - base == 8, $sformatf("8 requests, model saw %0d accesses", mem.access_count - base));
        $display("test_word_write_read done");
    endtask

    task automatic test_byte_enable();
        localparam logic [23:1] A = 23'h012340;
        write_word(A + 0, 16'hABCD);
        write_word(A + 0, 16'h0012, 2'b01);     // low byte only
        write_word(A + 1, 16'h1234);
        write_word(A + 1, 16'h9900, 2'b10);     // high byte only
        write_word(A + 2, 16'hFFFF);
        write_word(A + 2, 16'h0000, 2'b00);     // no byte at all
        read_expect(A + 0, 16'hAB12);
        read_expect(A + 1, 16'h9934);
        read_expect(A + 2, 16'hFFFF);
        $display("test_byte_enable done");
    endtask

    function automatic logic [15:0] pattern(input logic [23:1] a);
        return 16'(a) ^ 16'(a >> 7) ^ 16'hC3A5;
    endfunction

    function automatic logic [23:1] random_addr();
        logic [23:1] a = 23'($urandom);
        return {a[23], 16'h7654, a[6:1]};   // 64 words on each die
    endfunction

    task automatic test_back_to_back_reads();
        realtime t0;
        int clocks;
        for (int d = 0; d < 2; d++)
            for (int i = 0; i < 64; i++) begin
                logic [23:1] w = {1'(d), 16'h7654, 6'(i)};
                write_word(w, pattern(w));
            end
        t0 = $realtime;
        for (int i = 0; i < 100; i++) begin
            logic [23:1] r = random_addr();
            read_expect(r, pattern(r));
        end
        clocks = int'(($realtime - t0) / PERIOD);
        check(clocks == 100 * (dut.RD_WAIT + 2), $sformatf("100 reads took %0d clocks", clocks));
        $display("test_back_to_back_reads done: %0d clocks per read", clocks / 100);
    endtask

    // M1 sits at the top of die 1 of CRAM0: READs of the top word, alone, are ordinary reads
    task automatic test_top_word_reads();
        write_word(TOP, 16'h7E57);
        write_word(DIE1 | TOP, 16'h1E57);
        repeat (5) begin
            read_expect(TOP, 16'h7E57);
            read_expect(DIE1 | TOP, 16'h1E57);
        end
        check(mem.sw_seq_count == 0, "software access sequence from reads");
        $display("test_top_word_reads done");
    endtask

    // Inverted expectation: the model must reject a read this short
    task automatic test_rd_wait_too_small();
        logic [15:0] q;
        use_short = 1;
        write_word(23'h001000, 16'h3C3C);
        check(mem_short.error_count == 0, "writes of the short controller are legal");
        access(1'b0, 23'h001000, 16'h0000, 2'b00, q);
        check(mem_short.error_count != 0, "model accepted a read with RD_WAIT=3");
        check(q !== 16'h3C3C, "RD_WAIT=3 read returned the data");
        use_short = 0;
        $display("test_rd_wait_too_small done: model reported %0d error(s)", mem_short.error_count);
    endtask

    // Inverted expectation: READ, READ, WRITE on a die's top word must be flagged, and only that
    task automatic test_software_sequence_flagged();
        logic [15:0] q;
        use_short = 1;
        access(1'b0, TOP, 16'h0000, 2'b00, q);
        access(1'b1, TOP, 16'h0000, 2'b11, q);      // READ, WRITE: too few reads
        access(1'b0, TOP, 16'h0000, 2'b00, q);
        access(1'b0, 23'h000010, 16'h0000, 2'b00, q);   // same die, other word: breaks it
        access(1'b0, TOP, 16'h0000, 2'b00, q);
        access(1'b1, TOP, 16'h0000, 2'b11, q);          // READ, WRITE again
        check(mem_short.sw_seq_count == 0, "sequence flagged without two consecutive reads");
        access(1'b0, TOP, 16'h0000, 2'b00, q);
        access(1'b0, DIE1 | 23'h000010, 16'h0000, 2'b00, q);    // the other die does not see this
        access(1'b0, TOP, 16'h0000, 2'b00, q);
        access(1'b1, TOP, 16'h0001, 2'b11, q);
        check(mem_short.sw_seq_count == 1, "READ, READ, WRITE on the top word not flagged");
        use_short = 0;
        $display("test_software_sequence_flagged done");
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        repeat (2) @(posedge clk);
        test_word_write_read();
        test_byte_enable();
        test_back_to_back_reads();
        test_top_word_reads();
        test_rd_wait_too_small();
        test_software_sequence_flagged();
        @(posedge clk);
        check(mem.error_count == 0, "PSRAM model reported protocol or timing errors");
        if (failures != 0) $fatal(1, "%0d check(s) failed", failures);
        $display("PASS tb_cram_ctrl");
        $finish;
    end
endmodule
