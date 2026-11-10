// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// pocket_mem_mux with ROM_SRAM on, the cart core's layout: the copy of S and M1 to the SRAM with both sizes of S, the fix
// and the Z80 reading it, what stays on CRAM0, the MVS backup RAM from the 68K and from the save path.
`timescale 1ns/1ps
module tb_cart_layout;
`include "mem_map.svh"

    localparam real PERIOD = 10.34;
    localparam int  PCK_PERIOD = 64, PCK_HIGH = 4, FIX_DEADLINE = 23;
    localparam int  SAVE_WORD_NS = 1180;    // apf_loader.sv: the bridge's gap between two 32-bit words

    logic clk = 0, clk48 = 0;
    always #(PERIOD / 2) begin
        clk = ~clk;
        if (clk) clk48 = ~clk48;
    end

    logic        mem_init = 1, nRESET = 0, nSYSTEM_G = 1;
    logic [20:1] M68K_ADDR = 0;
    logic [15:0] M68K_DATA = 0, S_LATCH = 0, DL_DATA = 0, bk_wdata = 0;
    logic        nAS = 1, nROMOE = 1, PCK2 = 1;
    logic  [1:0] FIX_BANK = 0, BK_WR = 0;
    logic [26:0] DL_ADDR = 0;
    logic        DL_EN = 0, DL_WR = 0, BK_RD = 0, bk_req = 0, bk_we = 0;
    logic  [7:0] DL_INDEX = 0;
    logic [18:0] m1_addr = 0;
    logic        m1_req = 0;
    logic [14:0] bk_addr = 0;

    wire  [15:0] PROM_DATA, SROM_DATA, bk_rdata, fx_wdata, fx_rdata;
    wire  [16:0] fx_word;
    wire   [1:0] fx_be;
    wire         PROM_DATA_READY, m1_ack, bk_ack, busy, fx_req, fx_we, fx_ack;
    wire   [7:0] m1_dout;
    tri   [15:0] c0_dq, c1_dq, dram_dq, s_dq;
    wire [21:16] c0_a;
    wire  [16:0] s_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb, s_oe, s_we, s_ub, s_lb;

    pocket_mem_mux #(.ROM_SRAM(1), .M1_CACHE(1), .FIX_CACHE(1), .READY_COMB(1)) dut (
        .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(nSYSTEM_G), .SYSTEM_CDx(1'b0),
        .M68K_ADDR(M68K_ADDR), .M68K_DATA(M68K_DATA), .nAS(nAS), .nLDS(1'b1), .nUDS(1'b1),
        .nROMOE(nROMOE), .nPORTOE(1'b1), .nSROMOE(1'b1), .P2ROM_ADDR(27'h0),
        .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
        .PCK2(PCK2), .S_LATCH(S_LATCH), .FIX_BANK(FIX_BANK), .FIX_EN(1'b1), .SROM_DATA(SROM_DATA),
        .PCK1(1'b1), .CROM_ADDR(27'h0), .SPR_EN(1'b0), .REFRESH_EN(1'b0),
        .DL_EN(DL_EN), .DL_DATA(DL_DATA), .DL_ADDR(DL_ADDR), .DL_WR(DL_WR), .DL_INDEX(DL_INDEX),
        .CD_TR_AREA(3'b0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
        .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'b0),
        .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
        .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
        .fx_req(fx_req), .fx_we(fx_we), .fx_word(fx_word), .fx_be(fx_be), .fx_wdata(fx_wdata), .fx_ack(fx_ack), .fx_rdata(fx_rdata),
        .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0),
        .adpcma_addr(25'h0), .adpcma_req(1'b0), .adpcmb_addr(25'h0), .adpcmb_req(1'b0), .v2_offset(24'h0),
        .m1_addr(m1_addr), .m1_dout(m1_dout), .m1_req(m1_req), .m1_ack(m1_ack),
        .BK_RD(BK_RD), .BK_WR(BK_WR), .bk_req(bk_req), .bk_we(bk_we), .bk_addr(bk_addr), .bk_wdata(bk_wdata),
        .bk_ack(bk_ack), .bk_rdata(bk_rdata), .ROM_COPY_BUSY(busy),
        .dram_dq(dram_dq),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_dq(c1_dq), .cram1_wait(1'b0)
    );

    psram_model #(.POLL_NS(1.0)) mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.u_cram0.dq_oe)
    );

    sram_port u_sram (
        .clk(clk48), .req(fx_req), .we(fx_we), .word(fx_word), .be(fx_be), .wdata(fx_wdata), .ack(fx_ack), .rdata(fx_rdata),
        .sram_a(s_a), .sram_dq(s_dq), .sram_oe_n(s_oe), .sram_we_n(s_we), .sram_ub_n(s_ub), .sram_lb_n(s_lb)
    );
    sram_model #(.POLL_NS(2.0)) mem_s (
        .a(s_a), .dq(s_dq), .oe_n(s_oe), .we_n(s_we), .ub_n(s_ub), .lb_n(s_lb), .fpga_dq_oe(u_sram.dq_oe), .cut_write_ok(1'b0)
    );

    initial begin
        #2_000_000_000;
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

    function automatic logic [15:0] pattern(int word, int salt);
        logic [31:0] x = (32'(word) + 32'(salt) + 32'd1) * 32'h9E37_79B1;
        return x[31:16] ^ x[15:0];
    endfunction

    function automatic bit [22:0] c0_key(logic [23:0] base, int word);
        return 23'(int'(base >> 1) + word);
    endfunction

    // The whole of both ROMs and the rest of CRAM0's areas, straight into the chip
    task automatic fill_c0(int salt);
        for (int w = 0; w < 'h40000; w++) mem_c0.mem[c0_key(MAP_SROM, w)] = pattern(w, salt + 1);
        for (int w = 0; w < 'h40000; w++) mem_c0.mem[c0_key(MAP_M1, w)]   = pattern(w, salt + 2);
        for (int w = 0; w < 'h10000; w++) mem_c0.mem[c0_key(MAP_SFIX, w)] = pattern(w, salt + 3);
    endtask

    // A loader word: the same word the chip already has, so that only the mux's view changes
    task automatic dl(input logic [7:0] idx, input logic [26:0] a, input logic [15:0] d);
        DL_INDEX = idx; DL_ADDR = a; DL_DATA = d; DL_WR = 1;
        tick;
        DL_WR = 0;
        tick(12);
    endtask

    task automatic load(input bit big_s, input int salt);
        nRESET = 0;
        tick(4);
        fill_c0(salt);
        DL_EN = 1;
        dl(8'd8, 0, pattern(0, salt + 1));
        if (big_s) dl(8'd8, 27'h3FFFE, pattern('h1FFFF, salt + 1));
        tick(4);
        DL_EN = 0;
        tick(20);       // silence, then the next slot
        DL_EN = 1;
        dl(8'd9, 0, pattern(0, salt + 2));
        tick(4);
        DL_EN = 0;
        tick(2);
        check(busy === 1'b1, "the copy is not running after a load");
        while (busy) tick(100);
    endtask

    task automatic check_sram(input bit big_s, input int salt, input string what);
        int bad = 0;
        for (int w = 0; w < 'h20000; w++) begin
            logic [15:0] want = big_s ? pattern(w, salt + 2) : w < 'h10000 ? pattern(w, salt + 1) : pattern(w - 'h10000, salt + 2);
            if (mem_s.mem[w] !== want) bad++;
        end
        check(bad == 0, $sformatf("%s: %0d SRAM words differ", what, bad));
    endtask

    // ---- One fix read: PCK2 falls at the start, the data checked against the deadline ----
    function automatic [15:0] tile_word(input [15:0] s);
        return {s[15:4], s[2:0], ~s[3]};
    endfunction

    int fix_worst = 0;

    task automatic fix_fetch(input logic [15:0] s, input logic [15:0] want, input string what);
        int lat = 0;
        S_LATCH = s;
        PCK2 = 0;
        tick;
        while (SROM_DATA !== want && lat < FIX_DEADLINE + 8) begin tick; lat++; end
        check(lat + 1 <= FIX_DEADLINE, $sformatf("%s: fix of %h took %0d clocks", what, s, lat + 1));
        check(SROM_DATA === want, $sformatf("%s: fix of %h read %h, not %h", what, s, SROM_DATA, want));
        if (lat + 1 > fix_worst) fix_worst = lat + 1;
        tick(PCK_PERIOD - PCK_HIGH - lat - 1);
        PCK2 = 1;
        tick(PCK_HIGH);
    endtask

    task automatic m1_read(input int a, output logic [7:0] q, output int lat);
        lat = 0;
        m1_addr = 19'(a); m1_req = ~m1_req;
        while (m1_ack != m1_req && lat < 400) begin tick; lat++; end
        check(m1_ack == m1_req, "M1 read not acknowledged");
        q = m1_dout;
    endtask

    task automatic expect_m1(input int a, input logic [15:0] w, input bit from_c0, input string what);
        logic [7:0] q;
        int lat, n0 = mem_c0.access_count;
        m1_read(a, q, lat);
        check(q === (a[0] ? w[15:8] : w[7:0]), $sformatf("%s: M1 %h read %h, word %h", what, a, q, w));
        check(from_c0 == (mem_c0.access_count != n0), $sformatf("%s: M1 %h, %0d CRAM0 accesses", what, a, mem_c0.access_count - n0));
    endtask

    // ---- MVS backup RAM ----
    task automatic bk_cpu_read(input int word, output logic [15:0] d);
        M68K_ADDR = 20'(word); nAS = 0; BK_RD = 1;
        while (!PROM_DATA_READY) tick;
        d = PROM_DATA;
        tick(2);
        nAS = 1; BK_RD = 0;
        tick(4);
    endtask

    task automatic bk_cpu_write(input int word, input logic [15:0] d, input logic [1:0] lanes);
        M68K_ADDR = 20'(word); M68K_DATA = d; nAS = 0; BK_WR = lanes;
        tick(4);
        BK_WR = 0; nAS = 1;
    endtask

    task automatic bk_save(input bit we, input int word, input logic [15:0] d, output logic [15:0] q, output int clks);
        bk_we = we; bk_addr = 15'(word); bk_wdata = d;
        bk_req = ~bk_req;
        clks = 0;
        while (bk_ack != bk_req && clks < 1000) begin tick; clks++; end
        check(bk_ack == bk_req, "save access not acknowledged");
        q = bk_rdata;
    endtask

    task automatic test_copy_both_sizes();
        load(0, 100);
        check(dut.s_big == 0, "a 128 KB S ROM counted as large");
        check_sram(0, 100, "S up to 128 KB");
        load(1, 200);
        check(dut.s_big == 1, "a larger S ROM not seen");
        check_sram(1, 200, "S over 128 KB");
        load(0, 300);
        check(dut.s_big == 0, "the size must follow the new file");
        check_sram(0, 300, "back to a small S");
    endtask

    task automatic test_late_write_restarts_the_copy();
        logic [15:0] d = 16'hC0DE;
        load(0, 400);
        DL_EN = 1;
        dl(8'd9, 0, pattern(0, 402));
        tick(2);
        DL_EN = 0;
        while (dut.cp_w < 17'h100 || dut.cp_st == 0) tick;
        // Well into the copy, the loader changes a word it has passed
        DL_EN = 1;
        dl(8'd9, 27'h20, d);
        tick(8);
        DL_EN = 0;
        tick(2);
        check(busy === 1'b1, "busy fell with a late write");
        while (busy) tick(100);
        check(mem_s.mem['h10010] === d, "the late word did not reach the SRAM");
    endtask

    task automatic test_reads_small_s();
        int n0;
        logic [15:0] s;
        load(0, 500);
        nRESET = 1;
        tick(8);
        n0 = mem_c0.access_count;
        for (int i = 0; i < 64; i++) begin
            s = 16'($urandom);
            fix_fetch(s, pattern(tile_word(s), 501), "SRAM fix");
        end
        check(mem_c0.access_count == n0, "a fix in the SRAM reached CRAM0");
        expect_m1('h1234, pattern('h1234 >> 1, 502), 0, "low M1");
        expect_m1('h1FFFF, pattern('hFFFF, 502), 0, "top of the window");
        expect_m1('h20000, pattern('h10000, 502), 1, "above the window");
        expect_m1('h7FFFE, pattern('h3FFFF, 502), 1, "top of M1");
        nSYSTEM_G = 0;
        s = 16'hABC5;
        fix_fetch(s, pattern(tile_word(s), 503), "SFIX");
        check(mem_c0.access_count > n0, "SFIX did not reach CRAM0");
        nSYSTEM_G = 1;
    endtask

    task automatic test_reads_big_s();
        int n0;
        logic [15:0] s = 16'h7777;
        load(1, 600);
        nRESET = 1;
        tick(8);
        expect_m1('h1FFFF, pattern('hFFFF, 602), 0, "big S: under 128 KB");
        expect_m1('h3FFFE, pattern('h1FFFF, 602), 0, "big S: top of the window");
        expect_m1('h40000, pattern('h20000, 602), 1, "big S: above the window");
        n0 = mem_c0.access_count;
        FIX_BANK = 2;
        fix_fetch(s, pattern(int'({2'd2, tile_word(s)}), 601), "banked S");
        FIX_BANK = 0;
        check(mem_c0.access_count == n0 + 1, "a large S ROM's fix must read CRAM0");
    endtask

    task automatic test_backup();
        logic [15:0] d;
        int clks;
        load(0, 700);
        nRESET = 1;
        tick(8);
        mem_c0.mem[c0_key(MAP_BACKUP, 5)] = 16'h1234;
        bk_cpu_read(5, d);
        check(d === 16'h1234, $sformatf("68K backup read %h", d));
        bk_cpu_write(6, 16'hBEEF, 2'b11);
        tick(40);
        check(mem_c0.mem[c0_key(MAP_BACKUP, 6)] === 16'hBEEF, "68K backup write");
        bk_cpu_write(6, 16'h77AA, 2'b01);
        tick(40);
        check(mem_c0.mem[c0_key(MAP_BACKUP, 6)] === 16'hBEAA, "low lane only");
        bk_cpu_write(6, 16'h7711, 2'b10);
        tick(40);
        check(mem_c0.mem[c0_key(MAP_BACKUP, 6)] === 16'h77AA, "high lane only");
        // A read right behind the write it depends on
        bk_cpu_write(7, 16'h5A5A, 2'b11);
        bk_cpu_read(7, d);
        check(d === 16'h5A5A, $sformatf("read after a posted write %h", d));
        bk_cpu_write(8, 16'h1111, 2'b11);
        tick(28);
        bk_cpu_write(8, 16'h2222, 2'b11);
        tick(40);
        check(mem_c0.mem[c0_key(MAP_BACKUP, 8)] === 16'h2222, "the second of two writes at the shortest gap");
        // The save path, both ways and at the top of the area
        bk_save(1, 'h7FFF, 16'hA55A, d, clks);
        check(mem_c0.mem[c0_key(MAP_BACKUP, 'h7FFF)] === 16'hA55A, "save write");
        check(mem_c0.mem[c0_key(MAP_M1, 0)] === pattern(0, 702), "the backup area must stop short of M1");
        bk_save(0, 6, 0, d, clks);
        check(d === 16'h77AA, $sformatf("save read %h", d));
        // In reset too, as the host restores the file at boot
        nRESET = 0;
        tick(4);
        bk_save(1, 9, 16'h9999, d, clks);
        bk_save(0, 9, 0, d, clks);
        check(d === 16'h9999, "save path in reset");
        nRESET = 1;
        tick(8);
    endtask

    task automatic test_caches();
        int n0;
        logic [15:0] s = 16'h1238;
        load(1, 900);       // a large S: the fix is on CRAM0, and M1 above 256 KB
        nRESET = 1;
        tick(8);
        expect_m1('h40100, pattern('h20080, 902), 1, "M1 miss");
        expect_m1('h40101, pattern('h20080, 902), 0, "the other byte");
        expect_m1('h40100, pattern('h20080, 902), 0, "M1 hit");
        expect_m1('h41100, pattern('h20880, 902), 1, "same index, another tag");
        expect_m1('h40100, pattern('h20080, 902), 1, "the first was evicted");

        n0 = mem_c0.access_count;
        fix_fetch(s, pattern(int'(tile_word(s)), 901), "fix miss");
        check(mem_c0.access_count == n0 + 1, "a fix miss must read CRAM0");
        fix_fetch(16'h1248, pattern(int'(tile_word(16'h1248)), 901), "a neighbour, to change the output");
        n0 = mem_c0.access_count;
        fix_fetch(s, pattern(int'(tile_word(s)), 901), "fix hit");
        check(mem_c0.access_count == n0, "a fix hit reached CRAM0");
        FIX_BANK = 1;
        fix_fetch(s, pattern(int'({2'd1, tile_word(s)}), 901), "another bank is another tag");
        check(mem_c0.access_count == n0 + 1, "a bank change must miss");
        FIX_BANK = 0;
        nSYSTEM_G = 0;
        fix_fetch(s, mem_c0.mem[c0_key(MAP_SFIX, int'(tile_word(s)))], "SFIX is another tag");
        check(mem_c0.access_count == n0 + 2, "SFIX must miss after S");
        nSYSTEM_G = 1;

        // A reset empties them, whatever the chip holds now
        mem_c0.mem[c0_key(MAP_M1, 'h20080)] = 16'hBEEF;
        nRESET = 0;
        tick(2100);
        nRESET = 1;
        tick(8);
        expect_m1('h40100, 16'hBEEF, 1, "after a reset");
        n0 = mem_c0.access_count;
        fix_fetch(s, pattern(int'(tile_word(s)), 901), "after a reset");
        check(mem_c0.access_count == n0 + 1, "the fix cache survived a reset");

        // Hits and evictions at random: the data is always the chip's
        for (int i = 0; i < 20000; i++) begin
            automatic int a = 'h40000 + $urandom_range('h3FFF);
            automatic logic [15:0] w = mem_c0.mem[c0_key(MAP_M1, a >> 1)];
            automatic logic [7:0] q;
            automatic int lat;
            m1_read(a, q, lat);
            check(q === (a[0] ? w[15:8] : w[7:0]), $sformatf("random M1 %h read %h, word %h", a, q, w));
        end
    endtask

    // ---- Everything at once ----
    bit stop = 0;
    logic [15:0] model [16];      // what the backup words hold, across both phases
    int n_fix = 0, n_z80 = 0, n_bk = 0, n_cpu = 0, save_worst = 0;

    task automatic fix_client(input int salt);
        logic [15:0] s;
        while (!stop) begin
            s = 16'($urandom);
            fix_fetch(s, pattern(tile_word(s), salt + 1), "traffic");
            n_fix++;
        end
    endtask

    task automatic z80_client(input int salt);
        logic [7:0] q;
        int lat;
        while (!stop) begin
            automatic int a = $urandom_range('h7FFFF);
            automatic logic [15:0] w = pattern(a >> 1, salt + 2);
            m1_read(a, q, lat);
            check(q === (a[0] ? w[15:8] : w[7:0]), $sformatf("traffic: M1 %h read %h, word %h", a, q, w));
            n_z80++;
            tick($urandom_range(60));
        end
    endtask

    task automatic cpu_client();
        // Backup reads and writes through the 68K's own port, each word's value kept to check what comes back
        logic [15:0] d;
        while (!stop) begin
            automatic int w = $urandom_range(15);
            if ($urandom_range(1)) begin
                automatic logic [15:0] v = 16'($urandom);
                bk_cpu_write(w, v, 2'b11);
                model[w] = v;
            end else begin
                bk_cpu_read(w, d);
                check(d === model[w], $sformatf("traffic: backup %0d read %h, not %h", w, d, model[w]));
                n_cpu++;
            end
            tick(24 + $urandom_range(40));
        end
    endtask

    task automatic save_client(input int n);
        logic [15:0] d;
        int clks;
        for (int i = 0; i < n; i++) begin
            bk_save(0, 'h100 + i, 0, d, clks);
            if (clks > save_worst) save_worst = clks;
            bk_save(1, 'h100 + i, 16'(i), d, clks);
            if (clks > save_worst) save_worst = clks;
            n_bk++;
            tick(60);
        end
        stop = 1;
    endtask

    task automatic test_traffic(input bit big_s);
        for (int w = 0; w < 16; w++) begin
            mem_c0.mem[c0_key(MAP_BACKUP, w)] = 0;
            model[w] = 0;
        end
        load(big_s, 800);
        nRESET = 1;
        tick(8);
        stop = 0;
        fix_worst = 0;
        save_worst = 0;
        // A game running: the fix must keep its deadline
        fork
            fix_client(800);
            z80_client(800);
            cpu_client();
            begin tick(400000); stop = 1; end
        join
        tick(100);
        // Saves happen at boot and on Quit, above everything but the loader: the fix may be late then, a save may not
        stop = 0;
        fork
            z80_client(800);
            cpu_client();
            save_client(4000);
        join
        tick(100);
        // Two accesses a 32-bit word, each behind the 68K's or the fix's
        check(2 * save_worst * PERIOD < real'(SAVE_WORD_NS), $sformatf("the save path took %0d clocks an access", save_worst));
        $display("traffic, S %s: fix worst %0d of %0d, %0d fix, %0d Z80, %0d 68K, save worst %0d clocks an access",
                 big_s ? "large" : "128 KB", fix_worst, FIX_DEADLINE, n_fix, n_z80, n_cpu, save_worst);
    endtask

    initial begin
        tick(8);
        mem_init = 0;
        tick(8);

        test_copy_both_sizes();
        test_late_write_restarts_the_copy();
        test_reads_small_s();
        test_reads_big_s();
        test_backup();
        test_caches();
        test_traffic(0);
        test_traffic(1);

        check(mem_c0.error_count == 0, "CRAM0 model errors");
        check(mem_s.error_count == 0, "SRAM model errors");
        if (failures != 0) $fatal(1, "%0d failures", failures);
        $display("PASS tb_cart_layout");
        $finish;
    end
endmodule
