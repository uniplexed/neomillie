// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// pll_mvs_cfg against a stub altera_pll_reconfig slave that models the real core:
// after the start write waitrequest falls ~10 cycles later while 'locked' is still
// high, then 'locked' drops for UNLOCK_LEN cycles and relocks. Checks the write order
// (7 then 2), the K values, that 'reconfiguring' stays high through the whole sequence
// and drops only after relock + settle, and the timeout path (PLL never drops lock).
module tb_pll_mvs_cfg;
    localparam logic [31:0] K_AES = 32'd1785695733;
    localparam logic [31:0] K_MVS = 32'd1475039273;

    localparam int UNLOCK_TIMEOUT = 200;
    localparam int SETTLE_CYCLES  = 20;
    localparam int BUSY_LEN       = 10;   // waitrequest high for this many cycles after start
    localparam int UNLOCK_AT      = 16;   // 'locked' drops this many cycles after start
    localparam int UNLOCK_LEN     = 40;

    logic        clk = 0;
    logic        rst = 1;
    logic        mvs = 0;
    wire         reconfiguring;
    wire         wr, waitreq;
    wire  [5:0]  addr;
    wire  [31:0] wdata;

    // Stub slave: like the real core, waitrequest is high while busy or unlocked.
    logic        locked = 1;
    logic        busy = 0;
    logic        drop_lock = 1;           // 0: the PLL never drops lock (timeout path)
    int          sc = -1;                 // cycles since the start write, -1 when idle
    assign waitreq = busy | ~locked;

    // Accepted writes, in order.
    logic [5:0]  wr_addr [$];
    logic [31:0] wr_data [$];

    logic        saw_unlock = 0;          // lock dropped since the last start write
    int          since_start = 0;         // cycles since the last start write
    int          since_lock = 0;          // cycles since 'locked' last rose
    int          rises = 0;               // rising edges of 'reconfiguring'

    always #6 clk = ~clk;

    pll_mvs_cfg #(.UNLOCK_TIMEOUT(UNLOCK_TIMEOUT), .SETTLE_CYCLES(SETTLE_CYCLES)) dut (
        .clk_74a(clk), .rst(rst), .mvs(mvs), .locked(locked),
        .reconfiguring(reconfiguring),
        .mgmt_waitrequest(waitreq), .mgmt_write(wr),
        .mgmt_address(addr), .mgmt_writedata(wdata)
    );

    always @(posedge clk) begin
        since_start <= since_start + 1;
        since_lock  <= locked ? since_lock + 1 : 0;

        if (wr && !waitreq) begin
            wr_addr.push_back(addr);
            wr_data.push_back(wdata);
            if (addr == 6'd2) begin  // start
                busy        <= 1;
                sc          <= 0;
                saw_unlock  <= 0;
                since_start <= 0;
            end
        end else if (sc >= 0) begin
            sc <= sc + 1;
            if (sc == BUSY_LEN - 1) busy <= 0;
            if (drop_lock && sc == UNLOCK_AT) begin locked <= 0; saw_unlock <= 1; end
            if (drop_lock && sc == UNLOCK_AT + UNLOCK_LEN) locked <= 1;
            if (sc == UNLOCK_AT + UNLOCK_LEN + 10) sc <= -1;
        end
    end

    // 'reconfiguring' must not fall before the PLL relocked and settled, and must not
    // glitch low in the middle of a sequence.
    logic rec_q = 0;
    always @(posedge clk) begin
        rec_q <= reconfiguring;
        if (!rec_q && reconfiguring) rises <= rises + 1;
        if (rec_q && !reconfiguring) begin
            if (!locked)
                $fatal(1, "reconfiguring dropped while the PLL was unlocked");
            if (drop_lock && !saw_unlock)
                $fatal(1, "reconfiguring dropped before the PLL ever unlocked");
            if (drop_lock && since_lock < SETTLE_CYCLES)
                $fatal(1, "reconfiguring dropped %0d cycles after relock, want >= %0d", since_lock, SETTLE_CYCLES);
            if (!drop_lock && since_start < UNLOCK_TIMEOUT)
                $fatal(1, "reconfiguring dropped %0d cycles after start, before the %0d cycle timeout",
                       since_start, UNLOCK_TIMEOUT);
        end
    end

    task automatic expect_pair(input int idx, input logic [31:0] k, input string what);
        if (wr_addr.size() < idx + 2) $fatal(1, "%s: expected 2 more writes, have %0d total", what, wr_addr.size());
        if (wr_addr[idx] != 6'd7 || wr_data[idx] != k)
            $fatal(1, "%s: first write was addr %0d data %0d, want addr 7 data %0d", what, wr_addr[idx], wr_data[idx], k);
        if (wr_addr[idx+1] != 6'd2)
            $fatal(1, "%s: second write was addr %0d, want 2", what, wr_addr[idx+1]);
    endtask

    // Flip mvs, check 'reconfiguring' goes high at once and stays high through the whole
    // sequence (the monitor above checks the release conditions), then returns low.
    task automatic switch_mode(input logic new_mvs, input logic [31:0] k, input string what);
        int n = wr_addr.size();
        mvs = new_mvs;
        repeat (5) @(posedge clk);
        if (!reconfiguring) $fatal(1, "%s: reconfiguring not asserted after mvs change", what);
        wait (!reconfiguring);
        repeat (3) @(posedge clk);
        if (wr_addr.size() != n + 2) $fatal(1, "%s: want 2 new writes, have %0d", what, wr_addr.size() - n);
        expect_pair(n, k, what);
        if (!locked) $fatal(1, "%s: PLL unlocked after release", what);
        repeat (50) @(posedge clk);
        if (wr_addr.size() != n + 2) $fatal(1, "%s: spurious writes with stable mvs", what);
    endtask

    initial begin
        #1000000; $fatal(1, "timeout");
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);
        if (wr_addr.size() != 0 || reconfiguring) $fatal(1, "reconfiguration started with mvs=0 at power-up");

        // Real-core timing: waitrequest falls while locked is still high, then lock drops.
        drop_lock = 1;
        switch_mode(1, K_MVS, "AES->MVS");
        switch_mode(0, K_AES, "MVS->AES");

        // The PLL never drops lock: the unlock wait times out and reconfiguring releases.
        drop_lock = 0;
        switch_mode(1, K_MVS, "AES->MVS (no unlock)");

        if (rises != 3) $fatal(1, "reconfiguring rose %0d times, want 3", rises);
        $display("tb_pll_mvs_cfg ok");
        $finish;
    end
endmodule
