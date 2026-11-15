// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// neo_sma_pocket against MiSTer's neo_sma, side by side on the same 68K writes: random data to the bank port and to
// other addresses, each of the five SMA types, write strobes of 2 to 12 clocks of CLK_48M. Once a strobe has ended
// both must give the same P2_ADDR for every address. During the strobe the copy may lag by one clock, never more.
`timescale 1ns/1ps
module tb_sma;
    logic        clk = 0, nRESET = 0;
    logic [19:1] addr = 0;
    logic [15:0] data = 0;
    logic        nWEL = 1, nWEU = 1;
    logic  [2:0] type_ = 3;
    wire  [15:0] bus = !(nWEL & nWEU) ? data : 16'hzzzz;
    wire  [23:0] p2_ref, p2_new;
    int          fails = 0, writes = 0, bank_writes = 0;

    always #10.4 clk = ~clk;

    neo_sma ref_ (.nRESET, .CLK_48M(clk), .M68K_ADDR(addr), .M68K_DATA(bus), .PROM_DATA(16'h0), .nPORTOEL(1'b1),
                  .nPORTOEU(1'b1), .nPORTWEL(nWEL), .nPORTWEU(nWEU), .TYPE(type_), .P2_ADDR(p2_ref));
    neo_sma_pocket new_ (.nRESET, .CLK_48M(clk), .M68K_ADDR(addr), .M68K_DATA(bus), .PROM_DATA(16'h0), .nPORTOEL(1'b1),
                         .nPORTOEU(1'b1), .nPORTWEL(nWEL), .nPORTWEU(nWEU), .TYPE(type_), .P2_ADDR(p2_new));

    function automatic logic [19:1] bank_addr(input logic [2:0] t);
        return t == 3 ? 19'h7FFF8 : t == 4 || t == 5 ? 19'h7FFE0 : t == 6 ? 19'h7FFF2 : 19'h7FFF6;
    endfunction

    task automatic compare(input string when);
        for (int i = 0; i < 4; i++) begin
            addr = 19'($urandom);
            #1;
            if (p2_ref !== p2_new) begin
                fails++;
                if (fails < 10) $display("FAIL %s: type %0d addr %05x ref %06x new %06x", when, type_, addr, p2_ref, p2_new);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        nRESET = 1;
        for (int t = 3; t <= 7; t++) begin
            type_ = 3'(t);
            repeat (4) @(posedge clk);
            for (int n = 0; n < 4000; n++) begin
                automatic bit to_bank = $urandom_range(0, 3) != 0;
                @(negedge clk);
                addr = to_bank ? bank_addr(type_) : 19'($urandom);
                data = 16'($urandom);
                {nWEU, nWEL} = 2'b00;
                if (to_bank) bank_writes++;
                writes++;
                repeat ($urandom_range(2, 12)) @(negedge clk);
                {nWEU, nWEL} = 2'b11;
                repeat ($urandom_range(2, 6)) @(negedge clk);
                compare("after a write");
            end
        end
        $display("sma: %0d writes, %0d to the bank port, %0d mismatches", writes, bank_writes, fails);
        if (fails) $fatal(1, "FAIL sma");
        $display("PASS sma");
        $finish;
    end
endmodule
