// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// sram_ctrl against the checking AS6C2016-55BIN model. The 68K side is driven like the fx68k
// bus of the core: address and data are set before the strobes and held after them, the strobes
// last several CLK_48M cycles, and nothing changes in the same clock as a strobe edge.
`timescale 1ns/1ps
module tb_sram_ctrl;
    localparam real PERIOD = 20.687;        // shortest period of the design (AES 48.336 MHz): strictest ns limits
    localparam int  CLR_WE  = 3;            // clear: clocks of WE# low
    localparam int  CLR_CYC = 5;            // clear: clocks per word
    localparam int  SWEEP  = CLR_CYC * 32768;   // clocks of reset the clear needs: 32768 words
    localparam int  CAP    = 6;             // edges from the strobes to the CPU's read of wram_dout, which is the pins registered:
                                            // the pins are sampled at edge CAP - 1 (pocket.sdc asks the pin path 4 of them)
    localparam int  STB    = 8;             // write strobe clocks: S4..S7 of a 68K cycle at the shortest
    localparam int  HOLD   = 2;             // clocks address and data stay after a strobe (one 68K half clock)

    logic        clk = 0, rst_n = 0;
    logic [15:1] wram_addr = 0;
    logic [15:0] wram_din = 0;
    logic        nWRL = 1, nWRU = 1, nWWL = 1, nWWU = 1;
    wire         busy;

    tri   [15:0] dq;
    wire  [16:0] sram_a;
    wire         oe_n, we_n, ub_n, lb_n;
    wire  [15:0] wram_dout;

    always #(PERIOD / 2) clk = ~clk;

    sram_ctrl #(.CLR_WE_CLKS(CLR_WE), .CLR_CYCLE_CLKS(CLR_CYC)) dut (
        .clk(clk), .rst_n(rst_n),
        .sram_a(sram_a), .sram_dq(dq), .sram_oe_n(oe_n), .sram_we_n(we_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .wram_addr(wram_addr), .wram_din(wram_din), .wram_dout(wram_dout),
        .nWRL(nWRL), .nWRU(nWRU), .nWWL(nWWL), .nWWU(nWWU), .busy(busy)
    );

    sram_model mem (
        .a(sram_a), .dq(dq), .oe_n(oe_n), .we_n(we_n), .ub_n(ub_n), .lb_n(lb_n), .fpga_dq_oe(dut.dq_oe),
        .cut_write_ok(dut.run & ~dut.clearing)
    );

    // Watchdog: the whole bench takes about 42 ms of simulated time
    initial begin
        #100_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;
    localparam int READ_AT [3] = '{2, 5, 8};    // clocks into the strobes: chip going low-Z, valid, near the end
    localparam int WRITE_AT [2] = '{1, 4};

    // busy: high from the clock after rst_n falls (also the sweep after configuration) until the
    // sweep is over. It must stay high every clock until it falls, it must not fall while a clear
    // write is in flight (WE# low), and every word is 0x0000 when it falls.
    int busy_gap = 0, busy_early = 0, busy_falls = 0, expect_clks = 1;
    bit expect_busy = 1;
    always @(posedge clk) if (expect_busy) begin
        if (expect_clks >= 1 && !busy) busy_gap++;
        expect_clks++;
    end
    always @(negedge rst_n) if (!expect_busy) begin expect_busy = 1; expect_clks = 0; end
    always @(negedge busy) begin
        busy_falls++;
        expect_busy = 0;
        if (we_n !== 1'b1) busy_early++;
        for (int i = 0; i < 32768; i++) if (mem.mem[i] !== 16'h0000) busy_early++;
    end

    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    // ---- 68K bus cycles. Entered and left 1 ns after a clock edge, like registered outputs. ----

    // lanes: bit 1 = UDS (high byte), bit 0 = LDS (low byte)
    task automatic wram_write(input logic [15:1] a, input logic [15:0] d, input logic [1:0] lanes = 2'b11,
                              input int strobe = STB);
        wram_addr = a; wram_din = d;
        repeat (HOLD) @(posedge clk);
        #1 {nWWU, nWWL} = ~lanes;
        repeat (strobe) @(posedge clk);
        #1 {nWWU, nWWL} = 2'b11;
        repeat (HOLD) @(posedge clk);
        #1;
    endtask

    // Captures wram_dout the way the CPU does: CAP edges after the strobes fall. wram_dout is the
    // pins registered, so the value seen at edge CAP is what the pins showed at edge CAP - 1.
    task automatic wram_read(input logic [15:1] a, output logic [15:0] q, input logic [1:0] lanes = 2'b11,
                             input int cap = CAP);
        wram_addr = a;
        @(posedge clk);
        #1 {nWRU, nWRL} = ~lanes;
        repeat (cap) @(posedge clk);
        q = wram_dout;
        @(posedge clk);                 // the strobes outlast the capture by a clock
        #1 {nWRU, nWRL} = 2'b11;
        repeat (HOLD) @(posedge clk);
        #1;
    endtask

    task automatic wram_expect(input logic [15:1] a, input logic [15:0] expected);
        logic [15:0] q;
        wram_read(a, q);
        check(q === expected, $sformatf("wram %h = %h, expected %h", a, q, expected));
    endtask

    // Waits for the sweep to be over and returns the clocks busy stayed high
    task automatic wait_clear(output int clks);
        clks = 0;
        while (busy) begin
            @(posedge clk);
            clks++;
        end
        repeat (10) @(posedge clk);
        #1;
    endtask

    function automatic logic [15:0] pattern(input int i);
        return 16'(i * 16'h9E37) ^ 16'h5AC3 | 16'h0001;     // never 0
    endfunction

    function automatic bit all_zero();
        for (int i = 0; i < 32768; i++) if (mem.mem[i] !== 16'h0000) return 0;
        return 1;
    endfunction

    task automatic dirty_all();
        for (int i = 0; i < 32768; i++) mem.mem[i] = 16'hFFFF;
    endtask

    // rst_n low for n clocks, entered and left like a registered output
    task automatic rst_pulse(input int n);
        @(posedge clk);
        #1 rst_n = 0;
        repeat (n) @(posedge clk);
        #1 rst_n = 1;
    endtask

    // ---- Tests ----

    // A reset lands wherever the 68K happens to be: on a read the chip is driving, on a write WE# is
    // low. The CPU's own reset arrives a few clocks later, so its strobes run on. The model checks the
    // bus and the pins (contention, an address change in a write) and stops the run if they are wrong.
    task automatic reset_during(input bit wr, input int k);
        int n;
        wram_addr = 15'h1234;
        wram_din  = 16'hA5A5;
        repeat (HOLD) @(posedge clk);
        #1 if (wr) {nWWU, nWWL} = 2'b00; else {nWRU, nWRL} = 2'b00;
        repeat (k) @(posedge clk);
        #1 rst_n = 0;
        @(posedge clk);
        #1 rst_n = 1;
        repeat (3) @(posedge clk);
        #1 {nWWU, nWWL, nWRU, nWRL} = 4'b1111;
        wait_clear(n);
        check(all_zero(), $sformatf("work RAM not all 0 after a reset during a %s", wr ? "write" : "read"));
    endtask

    task automatic test_reset_entry();
        foreach (READ_AT[i])  reset_during(0, READ_AT[i]);
        foreach (WRITE_AT[i]) reset_during(1, WRITE_AT[i]);
        $display("test_reset_entry done");
    endtask

    // The model starts non-zero everywhere. A clear that misses any word of the 32K, or runs past
    // it, shows here. The reset is held SWEEP clocks and not a clock more.
    task automatic test_reset_clears_to_zero();
        logic [15:0] q;
        int bad = 0, n;
        check(mem.mem[0] != 0 && mem.mem[16'h7FFF] != 0 && mem.mem[16'h8000] != 0, "model should start dirty");
        rst_n = 0;
        repeat (SWEEP) @(posedge clk);
        #1 rst_n = 1;
        wait_clear(n);
        check(n <= 3, $sformatf("busy stayed high %0d clocks after a reset of exactly the sweep length", n));
        for (int i = 0; i < 32768; i++) begin
            wram_read(15'(i), q);
            if (q !== 16'h0000) bad++;
        end
        check(bad == 0, $sformatf("%0d of 32768 words not cleared", bad));
        check(mem.mem[17'h8000] == (16'hC000 | 16'h8000) && mem.mem[17'h1FFFF] == (16'hC000 | 16'hFFFF),
              "the clear ran past the work RAM");
        $display("test_reset_clears_to_zero done");
    endtask

    // A falling edge of rst_n starts a sweep that runs to the end whatever rst_n does after it:
    // one clock is enough, more falling edges during the sweep do not restart it, and busy says
    // when it is over. The 68K strobes are not looked at while busy.
    task automatic test_reset_pulses();
        int n;
        // 1. One clock of rst_n
        dirty_all();
        rst_pulse(1);
        repeat (3) @(posedge clk);
        check(busy, "busy not high after a one clock rst_n pulse");
        wait_clear(n);
        check(all_zero(), "work RAM not all 0 after a one clock rst_n pulse");
        check(n >= SWEEP - 10 && n <= SWEEP + 10, $sformatf("sweep after a one clock pulse took %0d clocks, expected about %0d", n, SWEEP));

        // 2. rst_n pulses again during the sweep: no restart, no break
        dirty_all();
        rst_pulse(1);
        repeat (700) @(posedge clk);
        rst_pulse(1);
        repeat (SWEEP / 2) @(posedge clk);
        rst_pulse(3);
        repeat (SWEEP / 2 - 800 - 5) @(posedge clk);
        rst_pulse(1);                           // again close to the last word
        wait_clear(n);
        check(all_zero(), "work RAM not all 0 after rst_n pulsed during the sweep");
        check(n >= 2 && n <= 300, $sformatf("sweep restarted by a later pulse (busy %0d clocks after the last)", n));

        // 3. After busy has fallen a new falling edge starts a fresh sweep
        dirty_all();
        rst_pulse(2);
        wait_clear(n);
        check(all_zero() && n >= SWEEP - 10, $sformatf("fresh sweep after busy fell: %0d clocks, zero %0b", n, all_zero()));

        // 4. rst_n back high, busy still high: a 68K write strobe (it should not come, the core is
        // held in reset) does not reach the chip
        dirty_all();
        rst_pulse(1);
        repeat (100) @(posedge clk);
        wram_write(15'h2000, 16'h1234);
        wait_clear(n);
        check(all_zero(), "a 68K write during the sweep reached the work RAM");
        $display("test_reset_pulses done");
    endtask

    task automatic test_68k_write_read_async();
        // Both bytes, then each byte on its own
        wram_write(15'h0000, 16'h1234);
        wram_write(15'h7FFF, 16'hCAFE);
        wram_write(15'h2AAA, 16'hA55A);
        wram_expect(15'h0000, 16'h1234);
        wram_expect(15'h7FFF, 16'hCAFE);
        wram_expect(15'h2AAA, 16'hA55A);
        wram_write(15'h0000, 16'hFF99, 2'b01);      // low byte only
        wram_expect(15'h0000, 16'h1299);
        wram_write(15'h0000, 16'h77FF, 2'b10);      // high byte only
        wram_expect(15'h0000, 16'h7799);
        // Byte reads: only the selected lane is looked at
        begin
            logic [15:0] q;
            wram_read(15'h7FFF, q, 2'b10);
            check(q[15:8] === 8'hCA, "high byte read");
            wram_read(15'h7FFF, q, 2'b01);
            check(q[7:0] === 8'hFE, "low byte read");
        end
        // Strobes of the minimum length: tBW 50 ns plus the 17.6 ns order margin is 4 clocks (83 ns)
        wram_write(15'h0100, 16'hBEEF, 2'b11, 4);
        wram_expect(15'h0100, 16'hBEEF);
        // Many addresses: write all, read all back
        for (int i = 0; i < 256; i++) wram_write(15'(i * 127 + 1), pattern(i));
        for (int i = 0; i < 256; i++) wram_expect(15'(i * 127 + 1), pattern(i));
        // Nothing outside the work RAM is touched
        check(mem.mem[17'h8000] == (16'hC000 | 16'h8000), "a write reached SRAM word 0x8000");
        $display("test_68k_write_read_async done");
    endtask

    // Bus turnaround (the model checks DQ contention and the data hold after WE#): read and write
    // cycles in every order, back to back at the 68K's own pace, and the other byte lane
    task automatic test_turnaround();
        logic [15:0] q;
        for (int i = 0; i < 64; i++) begin
            wram_write(15'h4000 + 15'(i), pattern(i));
            wram_expect(15'h4000 + 15'(i), pattern(i));
            wram_write(15'h4000 + 15'(i), 16'h00FF, 2'b01);
            wram_read(15'h4000 + 15'(i), q, 2'b10);
            check(q[15:8] === pattern(i) >> 8, "high byte changed by a low byte write");
        end
        $display("test_turnaround done");
    endtask

    // Inverted expectations: the model must reject accesses shorter than the datasheet allows
    task automatic test_short_accesses_flagged();
        logic [15:0] q;
        int e;
        // 68K write strobes of 2 clocks (41 ns) are shorter than tWP 45 ns
        mem.quiet = 1;
        e = mem.expected_count;
        wram_write(15'h3000, 16'h0F0F, 2'b11, 2);
        check(mem.expected_count > e, "model accepted a 41 ns write pulse");
        mem.quiet = 0;
        // A read captured 2 clocks (41 ns) after the strobes is too early: wrong data
        wram_write(15'h3001, 16'h6969);
        wram_read(15'h3001, q, 2'b11, 2);
        check(q !== 16'h6969, "model returned valid data 41 ns after the strobes");
        wram_expect(15'h3001, 16'h6969);
        $display("test_short_accesses_flagged done");
    endtask

    initial begin
        test_reset_clears_to_zero();
        test_68k_write_read_async();
        test_turnaround();
        test_short_accesses_flagged();
        test_reset_pulses();
        test_reset_entry();
        check(busy_gap == 0, $sformatf("busy low %0d clocks inside a sweep", busy_gap));
        check(busy_early == 0, $sformatf("busy fell early or with the clear incomplete (%0d)", busy_early));
        check(busy_falls >= 5, "busy did not fall once per sweep");
        check(mem.error_count == 0, "SRAM model reported protocol or timing errors");
        if (failures != 0) $fatal(1, "%0d check(s) failed", failures);
        $display("PASS tb_sram_ctrl");
        $finish;
    end
endmodule
