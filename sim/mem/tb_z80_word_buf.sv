// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// pocket_mem_mux with Z80_WORD_BUF on: the other byte of the last M1 word read takes no CRAM0
// access, and the buffer never answers with data older than the chip's.
`timescale 1ns/1ps
module tb_z80_word_buf;
`include "mem_map.svh"

    logic clk = 0;
    always #5.17 clk = ~clk;

    logic        mem_init = 1, nRESET = 0;
    logic [20:1] M68K_ADDR = 0;
    logic        nAS = 1, nROMOE = 1;
    logic [26:0] DL_ADDR = 0;
    logic [15:0] DL_DATA = 0;
    logic        DL_EN = 0, DL_WR = 0;
    logic  [7:0] DL_INDEX = 0;
    logic [18:0] m1_addr = 0;
    logic        m1_req = 0;

    wire  [15:0] PROM_DATA;
    wire         PROM_DATA_READY, m1_ack;
    wire   [7:0] m1_dout;
    tri   [15:0] c0_dq, c1_dq, dram_dq;
    wire [21:16] c0_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;

    pocket_mem_mux #(.Z80_WORD_BUF(1), .READY_COMB(1)) dut (
        .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(1'b1), .SYSTEM_CDx(1'b0),
        .M68K_ADDR(M68K_ADDR), .M68K_DATA(16'h0), .nAS(nAS), .nLDS(1'b1), .nUDS(1'b1),
        .nROMOE(nROMOE), .nPORTOE(1'b1), .nSROMOE(1'b1), .P2ROM_ADDR(27'h0),
        .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
        .PCK2(1'b1), .S_LATCH(16'h0), .FIX_BANK(2'b0), .FIX_EN(1'b0),
        .PCK1(1'b1), .CROM_ADDR(27'h0), .SPR_EN(1'b0), .REFRESH_EN(1'b0),
        .DL_EN(DL_EN), .DL_DATA(DL_DATA), .DL_ADDR(DL_ADDR), .DL_WR(DL_WR), .DL_INDEX(DL_INDEX),
        .CD_TR_AREA(3'b0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
        .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'b0),
        .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
        .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
        .fx_req(), .fx_we(), .fx_word(), .fx_be(), .fx_wdata(), .fx_ack(1'b0), .fx_rdata(16'h0),
        .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0),
        .adpcma_addr(25'h0), .adpcma_req(1'b0), .adpcmb_addr(25'h0), .adpcmb_req(1'b0), .v2_offset(24'h0),
        .m1_addr(m1_addr), .m1_dout(m1_dout), .m1_req(m1_req), .m1_ack(m1_ack),
        .dram_dq(dram_dq),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_dq(c1_dq), .cram1_wait(1'b0)
    );

    psram_model mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_cram0.dq_oe)
    );

    initial begin
        #50_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;

    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    task automatic tick(int n = 1);
        repeat (n) @(posedge clk);
        #1;
    endtask

    function automatic logic [15:0] m1_data(int word);
        logic [31:0] x = (32'(word) + 32'd1) * 32'h9E37_79B1;
        return x[31:16] ^ x[15:0];
    endfunction

    function automatic bit [22:0] m1_key(int byte_addr);
        return 23'(int'(MAP_M1 >> 1) + (byte_addr >> 1));
    endfunction

    task automatic m1_read(input int a, output logic [7:0] q, output int lat);
        lat = 0;
        m1_addr = 19'(a); m1_req = ~m1_req;
        while (m1_ack != m1_req && lat < 400) begin tick; lat++; end
        check(m1_ack == m1_req, "M1 read not acknowledged");
        q = m1_dout;
    endtask

    // Reads a through the mux and expects this many CRAM0 accesses, and the chip's byte
    task automatic expect_m1(input int a, input int accesses, input string what);
        logic [7:0] q;
        int lat;
        int n0 = mem_c0.access_count;
        logic [15:0] w = mem_c0.mem[m1_key(a)];
        m1_read(a, q, lat);
        check(q == (a[0] ? w[15:8] : w[7:0]), $sformatf("%s: got %h from word %h", what, q, w));
        check(mem_c0.access_count - n0 == accesses, $sformatf("%s: %0d accesses", what, mem_c0.access_count - n0));
        if (accesses == 0) check(lat <= 2, $sformatf("%s: a buffered byte took %0d clocks", what, lat));
    endtask

    task automatic test_other_byte_takes_no_access();
        expect_m1('h100, 1, "first read");
        expect_m1('h101, 0, "odd byte of the same word");
        expect_m1('h100, 0, "even byte again");
        expect_m1('h103, 1, "the next word, odd byte first");
        expect_m1('h102, 0, "its even byte");
        expect_m1('h100, 1, "one word only: the first word is gone");
    endtask

    // A buffered byte does not wait for the chip, and does not disturb who is using it
    task automatic test_hit_while_the_68k_reads();
        logic [15:0] d = 16'h6801;
        logic [7:0] q;
        int lat, n0;
        mem_c0.mem[23'h000100] = d;
        expect_m1('h200, 1, "fills the buffer");
        n0 = mem_c0.access_count;
        M68K_ADDR = 20'h00100; nAS = 0; nROMOE = 0;
        tick;
        check(dut.c0_req === 1'b1 || dut.want_68k === 1'b1, "the 68K read did not start");
        m1_read('h201, q, lat);
        check(lat <= 2, $sformatf("a buffered byte waited for the 68K: %0d clocks", lat));
        check(q == mem_c0.mem[m1_key('h201)][15:8], "buffered byte during a 68K read");
        while (!PROM_DATA_READY) tick;
        check(PROM_DATA == d, "68K data during a buffered byte");
        tick(2);
        nAS = 1; nROMOE = 1;
        tick(12);
        check(mem_c0.access_count - n0 == 1, "a buffered byte reached the chip");
    endtask

    task automatic test_never_older_than_the_chip();
        logic [15:0] d = 16'hC0DE;
        expect_m1('h300, 1, "fills the buffer");
        // The loader writes the buffered word
        DL_EN = 1;
        DL_INDEX = 8'd9; DL_ADDR = 27'h300; DL_DATA = d; DL_WR = 1;
        tick;
        DL_WR = 0;
        tick(20);
        DL_EN = 0;
        check(mem_c0.mem[m1_key('h300)] == d, "loader word not in the chip");
        expect_m1('h300, 1, "after the loader wrote the word");
        expect_m1('h301, 0, "the new word is buffered");
        // A reset forgets it: the chip changes behind the mux here, as a new load would
        mem_c0.mem[m1_key('h300)] = 16'hBEEF;
        nRESET = 0;
        tick(4);
        nRESET = 1;
        tick(4);
        expect_m1('h300, 1, "after a reset");
    endtask

    // In reset a read is answered with no access, as before, and fills nothing
    task automatic test_reset_answers_with_no_access();
        logic [7:0] q;
        int lat, n0;
        nRESET = 0;
        tick(2);
        n0 = mem_c0.access_count;
        m1_read('h400, q, lat);
        check(mem_c0.access_count == n0, "M1 read reached the chip in reset");
        nRESET = 1;
        tick(4);
        expect_m1('h400, 1, "after the reset, nothing buffered");
    endtask

    // Random reads with the 68K running: right byte each time, one access per word change
    bit stop = 0;
    int cpu_reads = 0;

    task automatic cpu_client();
        while (!stop) begin
            int w = $urandom_range(255);
            M68K_ADDR = 20'(w); nAS = 0; nROMOE = 0;
            while (!PROM_DATA_READY) tick;
            check(PROM_DATA == mem_c0.mem[23'(int'(MAP_P1 >> 1) + w)], "68K data in the random run");
            cpu_reads++;
            tick(4);
            nAS = 1; nROMOE = 1;
            tick(2 + $urandom_range(30));
        end
    endtask

    task automatic z80_client(input int n, output int misses);
        int last = -1, a = 'h1000;
        logic [7:0] q;
        int lat;
        misses = 0;
        repeat (n) begin
            logic [15:0] w;
            // Mostly the next byte, as a program counter; sometimes a jump
            a = $urandom_range(7) == 0 ? 'h1000 + $urandom_range(255) : a + 1;
            if (a >= 'h1100) a = 'h1000;
            w = mem_c0.mem[m1_key(a)];
            m1_read(a, q, lat);
            check(q == (a[0] ? w[15:8] : w[7:0]), $sformatf("random read %h: got %h from %h", a, q, w));
            if ((a >> 1) != last) misses++;
            last = a >> 1;
            tick($urandom_range(40));
        end
        stop = 1;
    endtask

    task automatic test_random_with_the_68k();
        int misses, n0;
        for (int w = 0; w < 256; w++) mem_c0.mem[23'(int'(MAP_P1 >> 1) + w)] = m1_data(w + 'h4000);
        n0 = mem_c0.access_count;
        fork
            cpu_client();
            z80_client(5000, misses);
        join
        tick(40);
        check(mem_c0.access_count - n0 == misses + cpu_reads,
              $sformatf("%0d accesses for %0d misses and %0d 68K reads", mem_c0.access_count - n0, misses, cpu_reads));
        $display("random: 5000 Z80 reads took %0d accesses, with %0d 68K reads alongside", misses, cpu_reads);
    endtask

    initial begin
        for (int a = 0; a < 'h2000; a += 2) mem_c0.mem[m1_key(a)] = m1_data(a);
        tick(8);
        mem_init = 0;
        tick(8);
        nRESET = 1;
        tick(4);

        test_other_byte_takes_no_access();
        test_hit_while_the_68k_reads();
        test_never_older_than_the_chip();
        test_reset_answers_with_no_access();
        test_random_with_the_68k();

        check(mem_c0.error_count == 0, "CRAM0 model errors");
        if (failures != 0) $fatal(1, "%0d failures", failures);
        $display("PASS tb_z80_word_buf");
        $finish;
    end
endmodule
