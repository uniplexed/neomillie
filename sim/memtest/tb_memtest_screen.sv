// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// memtest_screen alone: frame geometry, the colour of each row's band, and one frame written to
// build/memtest_screen.ppm to look at.
`timescale 1ns/1ps
module tb_memtest_screen;

    logic clk = 0;
    always #82.7 clk = ~clk;

    logic [4:0][31:0] res_err = 0, res_addr = 0;
    logic [4:0][15:0] res_pass = 0, res_got = 0, res_exp = 0;
    logic [2:0]       running = 2;
    wire [23:0] rgb;
    wire        de, vs, hs;

    memtest_screen #(.RD_WAIT(8)) dut (
        .clk(clk), .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
        .lat(32'h15141317), .loops(16'h0012), .seconds(32'h0000025B), .running(running), .dl_overflow(1'b0),
        .rfsh_count(32'h00012C00), .rfsh_max(16'h02D8), .seq_answer(2'd2), .seq_mask(4'hF),
        .last_addr(32'h00C00008), .last_got(16'hC756), .last_exp(16'hC951), .last_sec(16'h01E0),
        .video_rgb(rgb), .video_de(de), .video_vs(vs), .video_hs(hs)
    );

    initial begin
        #200_000_000;
        $fatal(1, "timeout");
    end

    int failures = 0;
    task automatic check(bit ok, string what);
        if (!ok) begin
            failures++;
            $error("FAIL: %s", what);
        end
    endtask

    localparam logic [23:0] GREEN = 24'h00A000, RED = 24'hC00000, YELLOW = 24'hC0C000, GREY = 24'h606060, BLUE = 24'h0000C0;

    logic [23:0] frame [0:223][0:319];

    initial begin
        int de_n = 0, n = 0, px = 0, py = 0, hs_n = 0;
        int fd;
        // Row 0 passed, row 1 failed, row 2 running, row 3 passed, row 4 not run yet
        res_pass[0] = 16'h0012;
        res_err[1]  = 32'h00000003; res_addr[1] = 32'h01FFFFFE; res_got[1] = 16'h1234; res_exp[1] = 16'h1235;
        res_pass[1] = 16'h0011;
        res_pass[2] = 16'h0011;
        res_pass[3] = 16'h0011;

        @(posedge vs);
        @(posedge clk);
        #1;
        while (!vs) begin
            if (de) begin
                de_n++;
                frame[py][px] = rgb;
                px++;
                if (px == 320) begin px = 0; py++; end
            end
            if (hs) hs_n++;
            n++;
            @(posedge clk);
            #1;
        end
        check(n == 384 * 264 - 1, $sformatf("frame length %0d", n));
        check(de_n == 320 * 224, $sformatf("DE count %0d", de_n));
        check(hs_n == 264, $sformatf("HS count %0d", hs_n));

        // The last pixel of each band line is outside the text
        check(frame[3 * 8 + 7][319] == GREEN,  "row 1 band is not green");
        check(frame[7 * 8 + 7][319] == RED,    "row 2 band is not red");
        check(frame[11 * 8 + 7][319] == YELLOW, "row 3 band is not yellow");
        check(frame[15 * 8 + 7][319] == BLUE,  "row 4 band is not blue");
        check(frame[19 * 8 + 7][319] == GREY,  "row 5 band is not grey");
        check(frame[2 * 8][319] == 24'h0 && frame[6 * 8 + 7][319] == 24'h0, "gaps between the bands are not black");

        fd = $fopen("build/memtest_screen.ppm", "w");
        $fdisplay(fd, "P3 320 224 255");
        for (int y = 0; y < 224; y++)
            for (int x = 0; x < 320; x++)
                $fdisplay(fd, "%0d %0d %0d", frame[y][x][23:16], frame[y][x][15:8], frame[y][x][7:0]);
        $fclose(fd);

        if (failures != 0) $fatal(1, "%0d failures", failures);
        $display("PASS tb_memtest_screen");
        $finish;
    end
endmodule
