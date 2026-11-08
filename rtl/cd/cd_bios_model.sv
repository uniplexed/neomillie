// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The UniBIOS keeps the console model it runs as in its SYSTEM setting, the byte $10FE32 (0 top loader, 1 front loader, 2 CDZ),
// loaded from the memory card at boot and TOPLOAD when the card has none. It drives the tray bit's polarity and other branches
// of its disc code. With the core's CD/CDZ on and the setting at TOPLOAD, the BIOS reads a closed tray as open and leaves its
// disc reads (Samurai Shodown RPG's load failed on it). So no user has to set anything, the core replaces whatever is written
// to that byte with the model CD/CDZ asks for. The UniBIOS writes its magic, $5632, to $10FE30 before the byte; a BIOS that
// does not is left alone. A consequence: the SYSTEM item in the UniBIOS menu cannot change the model.
module cd_bios_model (
    input             clk,
    input             nRESET,
    input             nAS,
    input             nUDS,
    input             nLDS,
    input             M68K_RW,
    input      [23:1] M68K_ADDR,
    input      [15:0] data_in,      // the 68K's write data
    input             system_cdz,
    output     [15:0] data_out,
    output reg        unibios = 0,
    output reg [15:0] requested = 0 // debug: what the BIOS last tried to write there: SYSTEM above, its region setting below
);

// The address settles at least a 68K clock before the strobes, four of these clocks: compare it early, off the data path
reg at_setting = 0;
wire write_upper = !nAS && !nUDS && !M68K_RW;

always @(posedge clk) begin
    at_setting <= M68K_ADDR == 23'h087F19;
    if (!nRESET) unibios <= 0;
    else if (write_upper && !nLDS && M68K_ADDR == 23'h087F18 && data_in == 16'h5632) unibios <= 1;
    if (!nAS && !M68K_RW && at_setting && unibios) begin
        if (!nUDS) requested[15:8] <= data_in[15:8];
        if (!nLDS) requested[7:0]  <= data_in[7:0];
    end
end

assign data_out = (at_setting && unibios) ? {system_cdz ? 8'd2 : 8'd0, data_in[7:0]} : data_in;

endmodule
