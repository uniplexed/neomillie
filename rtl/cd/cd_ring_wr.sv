// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The CD ring's write path: bridge writes to the ring's window, 0x7400_0000 plus the byte offset in the ring, become SDRAM
// word writes for pocket_mem_mux. The ring is 602,112 bytes at SDRAM word 0x0200000 (byte 0x400000, after the CD build's
// 4 MB of SPR RAM). A bridge word {b0, b1, b2, b3}, b0 in [31:24], is two SDRAM words, {b1, b0} then {b3, b2}: the order
// cd_fetch streams, as MiSTer's 16-bit words of the file.
//
// Clock crossing, clk_74a to CLK_96M: a FIFO of 4 bridge words in registers. The write pointer crosses as a Gray code through
// two flops; an entry is written on the edge the pointer moves, so it has been still for two clocks of CLK_96M when the reader
// sees it. STA does not time the entries' path into CLK_96M (clk_74a is in its own asynchronous group, and Quartus 25.1 lets
// that cut override a set_max_delay): the two clocks, about 20 ns, against a few ns of routing are the margin, as for
// apf_loader's block ring. There is no back-pressure and none is needed: the bridge writes one word per 88 clocks of 74.25 MHz (1.18 us),
// and the mux writes both of its SDRAM words in well under that (sim/mem's test_ring_with_sprites).
//
// rw_valid, rw_word and rw_data are a function of CLK_96M registers and of entries that do not move while they are read.
// rw_take, one clock, is the mux taking the word shown: the next one shows from the clock after.
module cd_ring_wr (
    input             clk_74a,
    input             bridge_wr,
    input      [31:0] bridge_addr,
    input      [31:0] bridge_wr_data,

    input             CLK_96M,
    output            rw_valid,
    output     [24:0] rw_word,      // SDRAM word address
    output     [15:0] rw_data,
    input             rw_take
);

localparam [24:0] RING_WORD  = 25'h0200000;
localparam [23:0] RING_BYTES = 24'd602112;     // 16 chunks of 16 sectors of 2,352 bytes

// ---- clk_74a: {word offset of the bridge word, data} ----

(* ramstyle = "logic" *) reg [49:0] fifo [0:3];
reg  [2:0] wp = 0, wg = 0;

wire       hit = bridge_wr && bridge_addr[31:24] == 8'h74 && bridge_addr[23:0] < RING_BYTES;
wire [2:0] wp_next = wp + 1'd1;

always @(posedge clk_74a) if (hit) begin
    fifo[wp[1:0]] <= {bridge_addr[19:2], bridge_wr_data};
    wp <= wp_next;
    wg <= wp_next ^ (wp_next >> 1);
end

// ---- CLK_96M ----

reg  [2:0] wg_1 = 0, wg_2 = 0, rp = 0;
reg        half = 0;        // the second SDRAM word of the head, {b3, b2}

wire [49:0] head = fifo[rp[1:0]];

assign rw_valid = (rp ^ (rp >> 1)) != wg_2;
assign rw_word  = RING_WORD | 25'({head[49:32], half});
assign rw_data  = half ? {head[7:0], head[15:8]} : {head[23:16], head[31:24]};

always @(posedge CLK_96M) begin
    {wg_2, wg_1} <= {wg_1, wg};
    if (rw_take) begin
        half <= ~half;
        if (half) rp <= rp + 1'd1;
    end
end

endmodule
