// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// audio_i2s: the frame rate, and the bits as the Pocket's DAC reads them. The decoder does not know
// the internals: it takes MCLK from the pin (12.288 MHz), counts MCLK from each LRCK edge, and reads
// DAC bit k of a channel at 4 x (k + 1) MCLK after the edge (one SCLK after the edge is the MSB, as
// in I2S, then one bit every SCLK = 4 MCLK), in the middle of the bit. LRCK low is the left channel.
`timescale 1ns/1ps
module tb_audio_i2s;
    logic clk74 = 0, clk48 = 0, rst = 1;
    always #6.734 clk74 = ~clk74;       // 74.25 MHz
    always #10.344 clk48 = ~clk48;      // 48.33 MHz

    logic [15:0] l = 16'h1234, r = 16'hABCD;
    wire  mclk, lrck, dac;
    audio_i2s dut (.clk_74a(clk74), .clk_48m(clk48), .rst(rst), .l(l), .r(r),
                   .audio_mclk(mclk), .audio_lrck(lrck), .audio_dac(dac));

    // ---- Decoder, one step per falling MCLK edge (half an MCLK after the edge that moves LRCK/DAC) ----
    logic        old_lrck = 0;
    int          cnt = 1000, mclk_rises = 0, lrck_falls = 0, lrck_edges = 0;
    logic [15:0] sh = 0, left = 0, right = 0;
    logic        have_l = 0;
    event        got_pair;
    always @(posedge mclk) mclk_rises++;
    always @(negedge lrck) lrck_falls++;
    always @(negedge mclk) begin
        old_lrck <= lrck;
        if (lrck !== old_lrck) begin
            lrck_edges++;
            cnt = 0;
        end else begin
            cnt = cnt + 1;
        end
        // bit k is valid from 4(k+1) to 4(k+2) MCLK after the edge; read it 1.5 MCLK in
        for (int k = 0; k < 16; k++) begin
            if (cnt == 4 * (k + 1) + 1) begin
                sh[15 - k] = dac;
                if (k == 15) begin
                    if (!lrck) begin
                        left = sh; have_l = 1;
                    end else if (have_l) begin
                        right = sh; have_l = 0; -> got_pair;
                    end
                end
            end
        end
    end

    // ---- Checks ----
    int errors = 0;
    task automatic fail(input string msg);
        $display("FAIL: %s", msg);
        errors++;
    endtask

    task automatic test_lrck_48khz();
        int f0, m0, f1, m1;
        // 10 ms measured from an LRCK fall to avoid an edge at each end
        @(negedge lrck);
        f0 = lrck_falls; m0 = mclk_rises;
        #10ms;
        f1 = lrck_falls; m1 = mclk_rises;
        if (f1 - f0 < 479 || f1 - f0 > 481) fail($sformatf("test_lrck_48khz: %0d frames in 10 ms, want 480 +-1", f1 - f0));
        if (m1 - m0 < 122878 || m1 - m0 > 122882) fail($sformatf("test_lrck_48khz: %0d MCLK in 10 ms, want 122880 +-2", m1 - m0));
        $display("lrck: %0d frames and %0d MCLK in 10 ms", f1 - f0, m1 - m0);
    endtask

    task automatic test_sample_bits_msb_first();
        int bad = 0;
        l = 16'h1234; r = 16'hABCD;
        repeat (3) @(got_pair);     // let the handshake deliver the values
        for (int i = 0; i < 20; i++) begin
            @(got_pair);
            if (left !== 16'h1234 || right !== 16'hABCD) begin
                bad++;
                if (bad < 4) $display("  frame %0d: left %h right %h", i, left, right);
            end
        end
        if (bad != 0) fail($sformatf("test_sample_bits_msb_first: %0d of 20 frames decoded wrong", bad));
    endtask

    // The sample changes every 2.9 us (no relation to the 20.8 us frame): a left/right or bit tear
    // shows up as a pair that is not (v, ~v) with equal bytes
    task automatic test_no_torn_samples();
        int bad = 0, n = 0, seen = 0;
        logic [15:0] last = 0;
        fork
            begin
                forever begin
                    @(posedge clk48);
                    l <= {l[7:0] + 8'd37, l[7:0] + 8'd37};
                    r <= ~{l[7:0] + 8'd37, l[7:0] + 8'd37};
                    repeat (139) @(posedge clk48);
                end
            end
            begin
                repeat (300) begin
                    @(got_pair);
                    n++;
                    if (left[15:8] !== left[7:0] || right !== ~left) bad++;
                    if (left !== last) seen++;
                    last = left;
                end
            end
        join_any
        disable fork;
        if (bad != 0) fail($sformatf("test_no_torn_samples: %0d of %0d frames torn", bad, n));
        if (seen < 250) fail($sformatf("test_no_torn_samples: only %0d different samples in %0d frames", seen, n));
    endtask

    initial begin
        repeat (20) @(posedge clk74);
        rst = 0;
        #1ms;
        test_lrck_48khz();
        test_sample_bits_msb_first();
        test_no_torn_samples();
        if (errors != 0) $fatal(1, "%0d audio_i2s failures", errors);
        $display("audio_i2s: all tests passed");
        $finish;
    end

    initial begin
        #100ms;
        $fatal(1, "timeout");
    end
endmodule
