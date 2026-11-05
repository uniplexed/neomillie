// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The APF bridge as io_bridge_peripheral.v drives it, at its fastest: one 32-bit word per 88 clocks
// of 74.25 MHz (io_bridge_peripheral.v:49). Outputs move 1 ns after the clock, like registers.
//
// write32: the address and data are complete before bridge_wr pulses for one clock, and stay until
// the next transaction starts shifting in, which the BFM shows by scrambling them.
//
// read32 is what ran on a Pocket against memtest_top.v (io_bridge_peripheral.v:209-226):
// the address is latched, 4 clocks later the current bridge_rd_data is what the host gets, and only
// then bridge_rd pulses. A core that loads its read register on the strobe, as memtest_bridge and
// apf_io.sv do, answers the transaction for N with the word of the transaction before it.
// read_file adds the host's side: the one read it spends so that a file has no lag, which is what
// "read lag: none" in the memory test's save file shows (inferred: only the file was observed).
//
// The bus is one word at a time, so the tasks here take turns: a bench and host_bfm may both use it. read_file and
// read_twice are one turn, as a read's lag makes them one thing.
`timescale 1ns/1ps
module bridge_bfm #(
    parameter int WORD_CLOCKS = 88
) (
    input  wire        clk,
    output reg  [31:0] bridge_addr = 32'hFFFF_FFFF,
    output reg         bridge_wr = 0,
    output reg  [31:0] bridge_wr_data = 32'hFFFF_FFFF,
    output reg         bridge_rd = 0,
    input  wire [31:0] bridge_rd_data
);

    localparam int SHIFT_CLOCKS = WORD_CLOCKS - 8;  // address and data bytes arriving on the SPI

    bit busy = 0;

    task automatic take();
        while (busy) @(posedge clk);
        busy = 1;
    endtask

    task automatic write32(input logic [31:0] addr, input logic [31:0] data);
        take();
        repeat (SHIFT_CLOCKS) @(posedge clk);
        #1 bridge_addr = addr;
        bridge_wr_data = data;
        repeat (4) @(posedge clk);
        #1 bridge_wr = 1;
        @(posedge clk);
        #1 bridge_wr = 0;
        repeat (WORD_CLOCKS - SHIFT_CLOCKS - 5) @(posedge clk);
        #1 bridge_addr = ~addr;
        bridge_wr_data = ~data;
        busy = 0;
    endtask

    task automatic read_word(input logic [31:0] addr, output logic [31:0] data);
        repeat (SHIFT_CLOCKS) @(posedge clk);
        #1 bridge_addr = addr;
        repeat (4) @(posedge clk);
        data = bridge_rd_data;
        #1 bridge_rd = 1;
        @(posedge clk);
        #1 bridge_rd = 0;
        repeat (WORD_CLOCKS - SHIFT_CLOCKS - 5) @(posedge clk);
        #1 bridge_addr = ~addr;
    endtask

    task automatic read32(input logic [31:0] addr, output logic [31:0] data);
        take();
        read_word(addr, data);
        busy = 0;
    endtask

    // A register that answers a read with the word of the read before
    task automatic read_twice(input logic [31:0] addr, output logic [31:0] data);
        take();
        read_word(addr, data);
        read_word(addr, data);
        busy = 0;
    endtask

    // n words from base, as the host gets them into a file
    task automatic read_file(input logic [31:0] base, input int n, output logic [31:0] data[$]);
        logic [31:0] w;
        data = {};
        take();
        read_word(base, w);    // answers with whatever came before: not part of the file
        for (int i = 1; i <= n; i++) begin
            read_word(base + 32'(i * 4), w);
            data.push_back(w);
        end
        busy = 0;
    endtask

endmodule
