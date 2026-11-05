// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Neo Geo clock generator for the Analogue Pocket: the MiSTer clock tree from the
// 74.25 MHz reference. mvs = 0: 96.671316 / 48.335658 MHz (AES, CD); mvs = 1: exactly
// 96.000 / 48.000 MHz (MVS), switched at run time through altera_pll_reconfig.
// CLK_PIX = CLK_96M / 16; CLK_PIX_90 is the same clock shifted by 90 degrees.
// While 'reconfiguring' is high the outputs are not usable (the PLL relocks).
// 'reconfiguring' is in the refclk (clk_74a) domain and is not asserted during the initial
// power-up lock, so consumers must also use ~locked. 'rst' must stay tied low in normal
// operation: a reset in MVS mode desynchronises mvs_cur from the PLL's K.
module pll_pocket (
    input  wire refclk,         // 74.25 MHz
    input  wire rst,
    input  wire mvs,
    output wire CLK_96M,
    output wire CLK_48M,
    output wire CLK_PIX,
    output wire CLK_PIX_90,
    output wire locked,
    output wire reconfiguring
);
    wire [63:0] reconfig_to_pll, reconfig_from_pll;
    wire        cfg_waitrequest, cfg_write;
    wire [5:0]  cfg_address;
    wire [31:0] cfg_data;

    pll_pocket_0002 pll (
        .refclk            (refclk),
        .rst               (rst),
        .outclk_0          (CLK_96M),
        .outclk_1          (CLK_48M),
        .outclk_2          (CLK_PIX),
        .outclk_3          (CLK_PIX_90),
        .locked            (locked),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    altera_pll_reconfig_top #(
        .device_family     ("Cyclone V"),
        .ENABLE_MIF        (0),
        .ENABLE_BYTEENABLE (0),
        .WAIT_FOR_LOCK     (1)
    ) reconfig (
        .mgmt_clk          (refclk),
        .mgmt_reset        (rst),
        .mgmt_waitrequest  (cfg_waitrequest),
        .mgmt_read         (1'b0),
        .mgmt_write        (cfg_write),
        .mgmt_readdata     (),
        .mgmt_address      (cfg_address),
        .mgmt_writedata    (cfg_data),
        .mgmt_byteenable   (4'b0000),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    pll_mvs_cfg mvs_cfg (
        .clk_74a          (refclk),
        .rst              (rst),
        .mvs              (mvs),
        .locked           (locked),
        .reconfiguring    (reconfiguring),
        .mgmt_waitrequest (cfg_waitrequest),
        .mgmt_write       (cfg_write),
        .mgmt_address     (cfg_address),
        .mgmt_writedata   (cfg_data)
    );
endmodule
