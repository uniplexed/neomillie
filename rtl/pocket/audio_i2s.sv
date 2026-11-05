// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Adapted from i2s.v of Mazamars312's Neo Geo Overdrive for Pocket, which runs on real Pockets
// (the file has no author header; his README lists the I2S bus among his modules and allows free
// use). Kept as it is: the fractional accumulator for MCLK, SCLK = MCLK / 4, 32 SCLK per channel,
// the sample loaded when the LRCK counter is 31 and LRCK goes 1 to 0, the MSB driven one SCLK after
// the LRCK edge, 16 bits MSB first and then the shift register stops. Changed: the logic runs in
// clk_74a with clock enables where his clocks the registers on MCLK and SCLK, and the sample crosses
// from clk_48m as one coherent word through a request/acknowledge handshake where his passes each
// bit through a 3 flop synchroniser.

// I2S audio output for the Analogue Pocket: 16 bit left and right at 48 kHz.
//
//   audio_mclk   12.288 MHz = 74.25 MHz x 245760 / 742500 / 2 (accumulator toggles it)
//   audio_lrck   48 kHz, low = left, toggles every 32 SCLK
//   audio_dac    changes on the falling SCLK edge; the MSB is one SCLK after the LRCK edge
//
// l and r are signed 16 bit samples in the clk_48m domain (the YM2610 mix, ~55.5 kHz, is simply
// sampled at 48 kHz here, with no resampler or filter, as the Overdrive does). The levels are not
// changed: the cart build takes snd_left / snd_right as they are, which are not halved as MiSTer's
// AUDIO_L = snd_mix_l[16:1] is.
module audio_i2s (
    input  wire        clk_74a,
    input  wire        clk_48m,
    input  wire        rst,             // clk_74a
    input  wire [15:0] l,               // clk_48m
    input  wire [15:0] r,
    output wire        audio_mclk,
    output wire        audio_lrck,
    output wire        audio_dac
);

// ---- Sample handshake: clk_48m holds {l, r} stable until clk_74a has taken it ----

reg [31:0] hold = 0;
reg        req = 0;
reg  [1:0] ack_s = 0;
reg        ack = 0;                     // clk_74a

always @(posedge clk_48m) begin
    ack_s <= {ack_s[0], ack};
    if (req == ack_s[1]) begin
        hold <= {l, r};
        req  <= ~req;
    end
end

reg  [1:0] req_s = 0;
reg [31:0] samp = 0;
always @(posedge clk_74a) begin
    req_s <= {req_s[0], req};
    if (req_s[1] != ack) begin
        samp <= hold;
        ack  <= req_s[1];
    end
end

// ---- MCLK = 12.288 MHz, fractional accumulator ----

localparam [21:0] CYCLE_48KHZ = 22'd245760;
localparam [21:0] REF_74MHZ   = 22'd742500;

reg [21:0] accum = 0;
reg        mclk = 0;
reg  [1:0] div = 0;                     // SCLK = div[1]
reg  [4:0] lrck_cnt = 0;
reg        lrck = 0;
reg        dac = 0;
reg [31:0] shift = 0;

assign audio_mclk = mclk;
assign audio_lrck = lrck;
assign audio_dac  = dac;

wire tick = accum >= REF_74MHZ;

always @(posedge clk_74a) begin
    if (rst) begin
        accum    <= 0;
        mclk     <= 0;
        div      <= 0;
        lrck_cnt <= 0;
        lrck     <= 0;
        dac      <= 0;
        shift    <= 0;
    end else begin
        accum <= accum + CYCLE_48KHZ;
        if (tick) begin
            mclk  <= ~mclk;
            accum <= accum - REF_74MHZ + CYCLE_48KHZ;
            if (!mclk) begin
                // MCLK rising edge: the original's posedge MCLK block
                div <= div + 1'b1;
                if (div == 2'd3) begin
                    // SCLK falling edge: the original's negedge SCLK block
                    dac      <= shift[31];
                    lrck_cnt <= lrck_cnt + 1'b1;
                    if (lrck_cnt == 5'd31) begin
                        lrck <= ~lrck;
                        if (lrck) shift <= samp;    // LRCK 1 to 0: load {left, right}
                    end else if (lrck_cnt < 5'd16) begin
                        shift <= {shift[30:0], 1'b0};
                    end
                end
            end
        end
    end
end

endmodule
