// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// memtest against the three checking memory models, through the real pocket_mem_mux: every test
// passes on good memory and fails on an injected fault. Sweeps are shortened with SPAN_BITS (low
// and high words of each die, so the top words are in) and the fault windows are found from the
// DUT's step counter. Bridge traffic runs at the real worst rate and reads follow
// io_bridge_peripheral.v (data sampled 4 clocks after the address, then the strobe).
`timescale 1ns/1ps
module tb_memtest;

    localparam real PERIOD_96 = 10.34;
    localparam real PERIOD_74 = 13.468;
    localparam int  FILE_BITS = 6;
    localparam int  FILL_BITS = 7;
    localparam int  FILE_WORDS = 1 << FILE_BITS;
    localparam logic [31:0] FILE_SEED = 32'h4E47_4D54;

    // Row numbers, as on screen minus one
    localparam int R_CRAM = 0, R_SDRAM = 1, R_MIX = 2, R_SEQ = 3, R_FILE = 4;

    logic clk = 0, clk74 = 0, mem_init = 1, start = 0;
    always #(PERIOD_96 / 2) clk = ~clk;
    always #(PERIOD_74 / 2) clk74 = ~clk74;

    // Bridge side
    logic [31:0] bridge_addr = 0, bridge_wr_data = 0;
    logic        bridge_wr = 0, bridge_rd = 0;
    wire  [31:0] bridge_rd_data;
    wire         bw_tog;
    wire  [31:0] bw_addr, bw_data;

    tri   [15:0] dram_dq, c0_dq, c1_dq;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire         c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;

    wire [4:0][31:0] res_err, res_addr;
    wire [4:0][15:0] res_pass, res_got, res_exp;
    wire [31:0]      lat, seconds;
    wire [15:0]      loops;
    wire  [2:0]      running;
    wire             dl_overflow;
    wire  [31:0]     rfsh_count;
    wire  [15:0]     rfsh_max;
    wire  [1:0]      seq_answer;
    wire  [3:0]      seq_mask;
    wire             diag_we;
    wire  [2:0]      diag_ptr;
    wire  [255:0]    diag_data;
    wire  [31:0]     last_addr;
    wire  [15:0]     last_got, last_exp, last_sec;

    memtest #(.SPAN_BITS(6), .RET_BITS(13), .RET_REGION_BITS(8), .MIX_BITS(15),
              .FILE_BITS(FILE_BITS), .FILL_BITS(FILL_BITS), .TICKS_PER_SECOND(1000)) dut (
        .clk(clk), .mem_init(mem_init), .start(start),
        .bw_tog(bw_tog), .bw_addr(bw_addr), .bw_data(bw_data),
        .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
        .lat(lat), .loops(loops), .seconds(seconds), .running(running), .dl_overflow(dl_overflow),
        .rfsh_count(rfsh_count), .rfsh_max(rfsh_max), .seq_answer(seq_answer), .seq_mask(seq_mask),
        .diag_we(diag_we), .diag_ptr(diag_ptr), .diag_data(diag_data),
        .last_addr(last_addr), .last_got(last_got), .last_exp(last_exp), .last_sec(last_sec),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_wait(1'b0), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv),
        .cram1_cre(c1_cre), .cram1_ce0_n(c1_ce0), .cram1_ce1_n(c1_ce1), .cram1_oe_n(c1_oe), .cram1_we_n(c1_we),
        .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb)
    );

    memtest_bridge #(.RD_WAIT(8)) bridge (
        .clk(clk74), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .bw_tog(bw_tog), .bw_addr(bw_addr), .bw_data(bw_data),
        .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
        .lat(lat), .loops(loops), .seconds(seconds), .dl_overflow(dl_overflow),
        .rfsh_count(rfsh_count), .rfsh_max(rfsh_max), .seq_answer(seq_answer), .seq_mask(seq_mask),
        .diag_clk(clk), .diag_we(diag_we), .diag_ptr(diag_ptr), .diag_data(diag_data)
    );

    sdram_model mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    // IO_NS as the window of synth/memtest/memtest.sdc
    psram_model #(.IO_NS(11.47)) mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_mux.u_cram0.dq_oe)
    );
    psram_model #(.IO_NS(11.47)) mem_c1 (
        .a(c1_a), .dq(c1_dq), .clk(c1_clk), .cre(c1_cre), .adv_n(c1_adv), .ce0_n(c1_ce0), .ce1_n(c1_ce1),
        .oe_n(c1_oe), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb), .fpga_dq_oe(dut.u_mux.u_cram1.dq_oe)
    );

    initial begin
        #400_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;
    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    // ---- Generators, as in tools/make_memtest_file.py ----
    function automatic logic [31:0] xs32(logic [31:0] x);
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        return x;
    endfunction

    function automatic logic [15:0] file_word(int i);
        logic [31:0] x = FILE_SEED;
        repeat (i) x = xs32(x);
        return x[15:0];
    endfunction

    // ---- Bridge BFM ----
    // One 32-bit write every 88 clocks of 74.25 MHz, the documented worst case
    task automatic bridge_write(input logic [31:0] a, input logic [31:0] d);
        @(posedge clk74);
        #1 bridge_addr = a; bridge_wr_data = d; bridge_wr = 1;
        @(posedge clk74);
        #1 bridge_wr = 0;
        repeat (86) @(posedge clk74);
    endtask

    // As io_bridge_peripheral.v:209-236: the host gets what is on the bus 4 clocks after the
    // address, then strobes, so the data for an address is what the previous strobe latched.
    task automatic bridge_read(input logic [31:0] a, output logic [31:0] d);
        @(posedge clk74);
        #1 bridge_addr = a;
        repeat (4) @(posedge clk74);
        d = bridge_rd_data;
        #1 bridge_rd = 1;
        @(posedge clk74);
        #1 bridge_rd = 0;
        repeat (82) @(posedge clk74);
    endtask

    // The file in one slot. bad_word/xor corrupt one word, swap breaks the byte order
    task automatic load_slot(input logic [31:0] base, input bit swap, input int bad_word, input logic [15:0] bad_xor);
        for (int i = 0; i < FILE_WORDS; i += 2) begin
            logic [15:0] w0 = file_word(i)     ^ (i     == bad_word ? bad_xor : 16'h0);
            logic [15:0] w1 = file_word(i + 1) ^ (i + 1 == bad_word ? bad_xor : 16'h0);
            // Bytes on the wire are the file order, first byte in [31:24]
            bridge_write(base + 32'(i * 2), swap ? {w0, w1} : {w0[7:0], w0[15:8], w1[7:0], w1[15:8]});
        end
    endtask

    task automatic restart();
        // The controller's startup has no refresh: the model's rate check restarts after it
        mem_sd.rate_error = 1;
        // Between sweeps: cutting an access short is not what is under test
        if (dut.st != dut.S_WAIT) wait (dut.st == dut.S_NEXT);
        mem_init = 1;
        start = 0;
        repeat (20) @(posedge clk);
        #1 mem_init = 0;
        // The SDRAM leaves its startup after 125 us
        #130_000;
        mem_sd.t_init_done = $realtime;
        mem_sd.refresh_count = 0;
        mem_sd.rate_error = 0;
    endtask

    task automatic wait_pass(input int row);
        int p = int'(res_pass[row]);
        wait (int'(res_pass[row]) != p);
        repeat (3) @(posedge clk);  // the last word's failure reaches res_err two clocks later
    endtask

    task automatic wait_step(input int s);
        wait (dut.st != dut.S_STEP && int'(dut.step) == s);
    endtask

    // ---- Backdoors ----
    function automatic bit [24:0] sd_key(logic [25:1] w);
        return {w[24:23], w[22:10], w[25], w[9:1]};
    endfunction

    // ---- Scenarios ----

    task automatic test_python_vectors();
        // Output of: python tools/make_memtest_file.py --print 4
        check(file_word(0) == 16'h4D54 && file_word(1) == 16'h4AE2 && file_word(2) == 16'h2F03 && file_word(3) == 16'h9E96,
              "file words differ from the Python generator");
    endtask

    task automatic test_file_bad_bytes();
        restart();
        load_slot(32'h1000_0000, 1, -1, 0);
        load_slot(32'h2000_0000, 0, -1, 0);
        load_slot(32'h4000_0000, 0, -1, 0);
        start = 1;
        wait_pass(R_FILE);
        check(res_err[R_FILE] >= FILE_WORDS - 2, "swapped bytes in CRAM0 not seen by the file test");
        check(res_addr[R_FILE][31:28] == 0, "file test: first failure not in CRAM0");
        check(res_addr[R_FILE][27:0] == 0, "file test: first failure not at offset 0");
        $display("test_file_bad_bytes done: %0d errors", res_err[R_FILE]);
    endtask

    task automatic test_file_bad_word();
        restart();
        load_slot(32'h1000_0000, 0, -1, 0);
        load_slot(32'h2000_0000, 0, 9, 16'h0100);
        load_slot(32'h4000_0000, 0, -1, 0);
        start = 1;
        wait_pass(R_FILE);
        check(res_err[R_FILE] == 1, "one bad word in CRAM1: expected one error");
        check(res_addr[R_FILE] == {4'd1, 28'd18}, "file test: wrong failing address");
        check(res_exp[R_FILE] == file_word(9), "file test: wrong expected word");
        check(res_got[R_FILE] == (file_word(9) ^ 16'h0100), "file test: wrong read word");
        $display("test_file_bad_word done");
    endtask

    task automatic load_good();
        restart();
        load_slot(32'h1000_0000, 0, -1, 0);
        load_slot(32'h2000_0000, 0, -1, 0);
        load_slot(32'h4000_0000, 0, -1, 0);
        start = 1;
    endtask

    // Every row in both kinds of chip, from start-up and across loop boundaries. A sequence on a
    // chip outside the SEQ step would be a false red on row 1: the survive model takes it silently
    // and returns a register, the abort model flags it as an error.
    task automatic test_mode(input bit survive);
        int n0, n1;
        mem_c0.seq_survives = survive;
        mem_c1.seq_survives = survive;
        n0 = mem_c0.sw_seq_count;
        n1 = mem_c1.sw_seq_count;
        load_good();
        wait (int'(loops) == 3);
        repeat (3) @(posedge clk);
        for (int r = 0; r < 5; r++)
            check(res_err[r] == 0, $sformatf("survive %0d: row %0d has %0d errors at %08x got %04x exp %04x",
                                             survive, r, res_err[r], res_addr[r], res_got[r], res_exp[r]));
        check(seq_answer == (survive ? 2 : 1), $sformatf("survive %0d: answer %0d", survive, seq_answer));
        check(seq_mask == (survive ? 4'hF : 4'h0), $sformatf("survive %0d: dies %b", survive, seq_mask));
        // Two dies per chip, in each of the three SEQ steps, and nothing else
        check(mem_c0.sw_seq_count - n0 == (survive ? 6 : 0), $sformatf("CRAM0 sequences %0d", mem_c0.sw_seq_count - n0));
        check(mem_c1.sw_seq_count - n1 == (survive ? 6 : 0), $sformatf("CRAM1 sequences %0d", mem_c1.sw_seq_count - n1));
        if (survive) begin
            check(res_got[R_SEQ] == 16'h00AD, $sformatf("answer value %04x", res_got[R_SEQ]));
            check(res_addr[R_SEQ] == {4'd3, 28'hFFFFFE}, $sformatf("answer die %08x", res_addr[R_SEQ]));
        end
        $display("test_mode survive %0d done: 3 loops, fix %0d sprite %0d, refresh %0d max gap %0d",
                 survive, lat[31:24], lat[23:16], rfsh_count, rfsh_max);
    endtask

    // One chip of each kind: the row must go red, and the others stay clean
    task automatic test_sequence_disagree();
        mem_c0.seq_survives = 0;
        mem_c1.seq_survives = 1;
        load_good();
        wait (int'(loops) == 1);
        repeat (3) @(posedge clk);
        check(res_err[R_SEQ] == 1, $sformatf("dies disagree: %0d errors", res_err[R_SEQ]));
        check(res_addr[R_SEQ][31:28] == 4, $sformatf("dies disagree: first %08x", res_addr[R_SEQ]));
        check(seq_answer == 3, "dies disagree: answer");
        check(seq_mask == 4'b1100, "dies disagree: mask");
        for (int r = 0; r < 3; r++) check(res_err[r] == 0, $sformatf("dies disagree: row %0d", r));
        mem_c1.seq_survives = 0;
        $display("test_sequence_disagree done");
    endtask

    // The answer changes between loops
    task automatic test_sequence_changes();
        int e = int'(res_err[R_SEQ]);
        mem_c0.seq_survives = 0;
        mem_c1.seq_survives = 0;
        load_good();
        wait (int'(loops) == 1);
        check(seq_answer == 1 && res_err[R_SEQ] == 0, "answer before the change");
        mem_c0.seq_survives = 1;
        mem_c1.seq_survives = 1;
        wait (int'(loops) == 2);
        repeat (3) @(posedge clk);
        check(res_err[R_SEQ] == 1 && seq_answer == 3, "an answer changing between loops not flagged");
        mem_c0.seq_survives = 0;
        mem_c1.seq_survives = 0;
        $display("test_sequence_changes done");
    endtask

    // The chip's word stops working after the sequence: real, so red
    task automatic test_sequence_bad_readback();
        int e = int'(res_err[R_SEQ]);
        wait (dut.st != dut.S_STEP && int'(dut.step) == dut.STEP_SEQ && int'(dut.sq_step) == 7);
        force dut.rd_data = 16'h0000;
        wait (int'(dut.sq_step) != 7);
        release dut.rd_data;
        wait_pass(R_SEQ);
        check(int'(res_err[R_SEQ]) > e, "3FFFFFh: a bad read-back after the sequence not seen");
    endtask

    // The command count is the chip's: compare with the model, which only sees the pins
    task automatic test_refresh_counted();
        int c0 = int'(rfsh_count), m0 = mem_sd.refresh_count, c1, m1;
        repeat (20000) @(posedge clk);
        c1 = int'(rfsh_count);
        m1 = mem_sd.refresh_count;
        check(c1 - c0 > 20 && c1 - c0 - (m1 - m0) <= 1 && (m1 - m0) - (c1 - c0) <= 1,
              $sformatf("refresh: counted %0d, the chip saw %0d", c1 - c0, m1 - m0));
        check(rfsh_max > 700 && rfsh_max <= 754, $sformatf("refresh: largest gap %0d", rfsh_max));
        $display("test_refresh_counted done: largest gap %0d clocks", rfsh_max);
    endtask

    // Mutation: refresh stops reaching the controller, row 2 must go red
    task automatic test_refresh_dead();
        int e = int'(res_err[R_SDRAM]), c;
        logic held = dut.u_mux.sd_refresh;
        mem_sd.rate_error = 1;      // the model would stop the bench on this, and it is what we want
        force dut.u_mux.u_sdram.refresh = held;
        repeat (2000) @(posedge clk);
        c = int'(rfsh_count);
        repeat (2000) @(posedge clk);
        check(int'(rfsh_count) == c, "refresh dead: commands still counted");
        release dut.u_mux.u_sdram.refresh;
        repeat (1000) @(posedge clk);
        check(int'(res_err[R_SDRAM]) == e + 1, $sformatf("refresh dead: row 2 errors %0d, was %0d", res_err[R_SDRAM], e));
        check(rfsh_max > 754, "refresh dead: largest gap not recorded");
        mem_sd.t_init_done = $realtime;
        mem_sd.refresh_count = 0;
        mem_sd.rate_error = 0;
        $display("test_refresh_dead done: largest gap %0d clocks", rfsh_max);
    endtask

    task automatic test_all_pass_on_good_memory();
        mem_c0.seq_survives = 0;
        mem_c1.seq_survives = 0;
        load_good();
        wait (int'(loops) == 1);
        for (int r = 0; r < 5; r++) begin
            check(res_err[r] == 0, $sformatf("row %0d has errors on good memory: %0d at %08x got %04x exp %04x",
                                             r, res_err[r], res_addr[r], res_got[r], res_exp[r]));
            check(res_pass[r] != 0, $sformatf("row %0d has no pass", r));
        end
        check(!dl_overflow, "loader overflow in contract");
        check(lat[31:24] <= 23, "fix latency over the deadline");
        check(lat[23:16] <= 27, "sprite latency over the deadline");
        check(lat[31:24] != 0 && lat[23:16] != 0 && lat[15:8] != 0 && lat[7:0] != 0, "a mixed client did not run");
        check(mem_c0.sw_seq_count == 0 && mem_c1.sw_seq_count == 0, "a software access sequence reached a chip");
        $display("test_all_pass_on_good_memory done: worst clocks fix %0d sprite %0d 68K %0d Z80 %0d",
                 lat[31:24], lat[23:16], lat[15:8], lat[7:0]);
    endtask

    // Flip a word between the write sweep and the read sweep that checks it
    task automatic test_cram_fault(input bit chip, input int rd_step, input bit [22:0] key, input int sub);
        int e = int'(res_err[R_CRAM]);
        bit first = res_err[R_CRAM] == 0;
        wait_step(rd_step);
        if (chip) mem_c1.mem[key] ^= 16'h8000;
        else      mem_c0.mem[key] ^= 16'h8000;
        wait_pass(R_CRAM);
        check(int'(res_err[R_CRAM]) == e + 1, $sformatf("CRAM%0d: fault at %06x not counted once", chip, key));
        if (first) begin
            check(res_addr[R_CRAM] == {4'(sub), 4'd0, key, 1'b0}, $sformatf("CRAM first address %08x", res_addr[R_CRAM]));
            check((res_got[R_CRAM] ^ res_exp[R_CRAM]) == 16'h8000, "CRAM got/exp do not show the flipped bit");
        end
    endtask

    task automatic test_sdram_fault();
        int e = int'(res_err[R_SDRAM]);
        bit [24:0] k = sd_key(25'h1FF_FFFF);    // the top word
        wait_step(dut.STEP_SD_RD);
        mem_sd.mem[k] ^= 16'h0001;
        wait_pass(R_SDRAM);
        check(int'(res_err[R_SDRAM]) == e + 1, "SDRAM: flipped top word not counted once");
        check(res_addr[R_SDRAM] == {4'd0, 2'd0, 25'h1FF_FFFF, 1'b0}, $sformatf("SDRAM first address %08x", res_addr[R_SDRAM]));
    endtask

    // Two words swapped in a burst line: what a wrong capture order looks like to the client
    task automatic test_sdram_word_order();
        int e = int'(res_err[R_SDRAM]);
        bit [24:0] k0 = sd_key(25'h000_0004), k1 = sd_key(25'h000_0005);
        logic [15:0] t;
        wait_step(dut.STEP_SD_RD);
        t = mem_sd.mem[k0]; mem_sd.mem[k0] = mem_sd.mem[k1]; mem_sd.mem[k1] = t;
        wait_pass(R_SDRAM);
        check(int'(res_err[R_SDRAM]) == e + 2, "SDRAM: swapped burst words not counted");
    endtask

    task automatic test_sdram_retention();
        int e = int'(res_err[R_SDRAM]);
        bit [24:0] k = sd_key(25'h000_0031);
        wait_step(dut.STEP_RET_WAIT);
        mem_sd.mem[k] ^= 16'h0100;
        wait_pass(R_SDRAM);
        check(int'(res_err[R_SDRAM]) == e + 1, "SDRAM: decay during the retention wait not seen");
    endtask

    task automatic test_mix_data();
        int e = int'(res_err[R_MIX]);
        wait_step(dut.STEP_MIX);
        for (int i = 0; i < (1 << FILL_BITS); i++) mem_c0.mem[23'h600000 + 23'(i)] ^= 16'h0004;
        wait_pass(R_MIX);
        check(int'(res_err[R_MIX]) > e, "mixed: wrong fix data not seen");
        check(res_addr[R_MIX][31:28] == 0, "mixed: first failure is not the fix client");
        // The address reported is the word fetched: it holds what was expected
        begin
            logic [22:0] w = res_addr[R_MIX][23:1];
            check(res_exp[R_MIX] == (w[15:0] ^ {w[6:0], w[15:7]} ^ {w[22:16], 9'h155}), "mixed: address and expected word do not match");
        end
    endtask

    // Correct data, too late: hold the client off, the deadline check must still count it
    task automatic test_mix_deadline(input bit sprite);
        int e = int'(res_err[R_MIX]);
        wait_step(dut.STEP_MIX);
        repeat (200) @(posedge clk);
        if (sprite) begin
            @(negedge dut.PCK1);
            force dut.u_mux.sd_ready = 1'b0;
            repeat (40) @(posedge clk);
            release dut.u_mux.sd_ready;
        end else begin
            @(negedge dut.PCK2);
            force dut.u_mux.want_fix = 1'b0;
            repeat (30) @(posedge clk);
            release dut.u_mux.want_fix;
        end
        wait_pass(R_MIX);
        check(int'(res_err[R_MIX]) > e, $sformatf("mixed: late %s not seen", sprite ? "sprite" : "fix"));
    endtask

    // The save block through the read protocol of the bridge: one word lag, then the host's view
    task automatic test_save_read();
        logic [31:0] d, seen [0:1023];
        int fd;
        // The host starts at the slot base; the word for address N comes with the access to N+1
        bridge_read(32'h6000_0000, d);
        for (int i = 0; i < 1024; i++) begin
            bridge_read(32'h6000_0000 + 32'((i + 1) * 4), d);
            seen[i] = d;
        end
        // The file the host would write, for tools/check_memtest_save.py
        fd = $fopen("build/memtest_save.sav", "wb");
        for (int i = 0; i < 1024; i++)
            $fwrite(fd, "%c%c%c%c", seen[i][31:24], seen[i][23:16], seen[i][15:8], seen[i][7:0]);
        $fclose(fd);
        check(seen[0] == 32'h4E47_4D54, $sformatf("save word 0: %08x", seen[0]));
        check(seen[24] != 0, "save word 24: refresh count");
        check(seen[25] == 32'(rfsh_max), "save word 25: refresh gap");
        check(seen[26] == {14'd0, seq_answer, 12'd0, seq_mask}, "save word 26: answer");
        check(seen[1][31:24] == 8, "save word 1: RD_WAIT");
        // The newest failure record of row 3, as on screen
        begin
            int e = 32 + 8 * ((int'(diag_ptr) + 7) & 7);
            check(seen[e] == last_addr, $sformatf("record address %08x, last %08x", seen[e], last_addr));
            check(seen[e + 1] == {last_got, last_exp}, "record data");
            check(seen[e + 7][31:16] != 0, "record loop");
            check(seen[27] == 32'(diag_ptr), "record pointer");
        end
        for (int i = 128; i < 1024; i++)
            check(seen[i] == (32'h5A00_0000 | 32'(i)), $sformatf("save pattern word %0d: %08x", i, seen[i]));
        for (int r = 0; r < 5; r++)
            check(seen[4 + r * 4 + 1] == res_err[r], $sformatf("save row %0d errors", r));
        // Non-slot writes and the host's load of an old save file must not reach the loader
        begin
            logic tog = bw_tog;
            bridge_write(32'h6000_0000, 32'hFFFF_FFFF);
            check(bw_tog == tog, "a write to the save slot reached the loader");
            bridge_write(32'hF800_0000, 32'h0);
            check(bw_tog == tog, "a host command reached the loader");
        end
        $display("test_save_read done");
    endtask

    initial begin
        test_python_vectors();
        test_file_bad_bytes();
        test_file_bad_word();
        test_all_pass_on_good_memory();
        test_refresh_counted();
        // Each fault heals on the next write sweep. First fault of a row checks first-failure latching.
        test_cram_fault(0, dut.STEP_C0_WALK_RD, 23'h3FFFFF, 0);   // top word of CRAM0 die 0
        test_cram_fault(1, dut.STEP_C1_RND_RD,  23'h7FFFFF, 3);   // top word of CRAM1 die 1
        test_cram_fault(0, dut.STEP_C0_RND_RD,  23'h400000, 1);   // first word of CRAM0 die 1
        $display("test_cram_fault done: %0d errors", res_err[R_CRAM]);
        test_sdram_fault();
        test_sdram_word_order();
        test_sdram_retention();
        $display("test_sdram done: %0d errors", res_err[R_SDRAM]);
        test_mix_data();
        test_mix_deadline(0);
        test_mix_deadline(1);
        $display("test_mix done: %0d errors, worst clocks fix %0d sprite %0d", res_err[R_MIX], lat[31:24], lat[23:16]);
        test_refresh_dead();
        test_sequence_bad_readback();
        test_save_read();
        test_mode(0);
        test_mode(1);
        test_sequence_disagree();
        test_sequence_changes();
        check(mem_sd.error_count == 0, "SDRAM model errors");
        check(mem_c0.error_count == 0, "CRAM0 model errors");
        check(mem_c1.error_count == 0, "CRAM1 model errors");
        check(!dl_overflow, "loader overflow");
        if (failures != 0) $fatal(1, "%0d failures", failures);
        $display("PASS tb_memtest");
        $finish;
    end
endmodule
