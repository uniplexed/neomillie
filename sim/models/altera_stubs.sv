// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Behavioural stand-ins for Altera primitives, so Verilator can simulate RTL that keeps
// the real primitive. Simulation only: never list this file in a Quartus project.

// DDR output: dataout follows datain_h while outclock is high and datain_l while it is
// low. Only what the design uses (no clear/set/enable handling).
module altddio_out #(
    parameter extend_oe_disable      = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output          = "OFF",
    parameter lpm_hint               = "UNUSED",
    parameter lpm_type               = "altddio_out",
    parameter oe_reg                 = "UNREGISTERED",
    parameter power_up_high          = "OFF",
    parameter width                  = 1
) (
    input  wire [width-1:0] datain_h,
    input  wire [width-1:0] datain_l,
    input  wire             outclock,
    output wire [width-1:0] dataout,
    input  wire             aclr,
    input  wire             aset,
    input  wire             oe,
    input  wire             outclocken,
    input  wire             sclr,
    input  wire             sset
);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

// Dual port RAM, the subset dpram.v and mf_datatable.v use: both widths equal, no byte enables.
// A port reads its own write as new data; a read of the other port's write is old data.
module altsyncram #(
    parameter address_reg_b = "", parameter clock_enable_input_a = "", parameter clock_enable_input_b = "",
    parameter clock_enable_output_a = "", parameter clock_enable_output_b = "", parameter indata_reg_b = "",
    parameter init_file = "", parameter intended_device_family = "", parameter lpm_type = "",
    parameter operation_mode = "", parameter outdata_aclr_a = "", parameter outdata_aclr_b = "",
    parameter outdata_reg_a = "UNREGISTERED", parameter outdata_reg_b = "UNREGISTERED",
    parameter power_up_uninitialized = "", parameter read_during_write_mode_mixed_ports = "",
    parameter read_during_write_mode_port_a = "", parameter read_during_write_mode_port_b = "",
    parameter wrcontrol_wraddress_reg_b = "",
    parameter int numwords_a = 256, parameter int numwords_b = 256,
    parameter int widthad_a = 8, parameter int widthad_b = 8,
    parameter int width_a = 8, parameter int width_b = 8,
    parameter int width_byteena_a = 1, parameter int width_byteena_b = 1
) (
    input  wire [widthad_a-1:0] address_a,
    input  wire [widthad_b-1:0] address_b,
    input  wire                 clock0,
    input  wire                 clock1,
    input  wire [width_a-1:0]   data_a,
    input  wire [width_b-1:0]   data_b,
    input  wire                 wren_a,
    input  wire                 wren_b,
    output wire [width_a-1:0]   q_a,
    output wire [width_b-1:0]   q_b,
    input  wire aclr0, aclr1, addressstall_a, addressstall_b, byteena_a, byteena_b,
    input  wire clocken0, clocken1, clocken2, clocken3, rden_a, rden_b,
    output wire eccstatus
);
    logic [width_a-1:0] mem [0:numwords_a-1];
    logic [width_a-1:0] ra = 0, rb = 0, ra2 = 0, rb2 = 0;

    initial for (int i = 0; i < numwords_a; i++) mem[i] = '0;

    always @(posedge clock0) begin
        ra  <= wren_a ? data_a : mem[address_a];
        ra2 <= ra;
        if (wren_a) mem[address_a] <= data_a;
    end
    always @(posedge clock1) begin
        rb  <= wren_b ? data_b : mem[address_b];
        rb2 <= rb;
        if (wren_b) mem[address_b] <= data_b;
    end

    assign q_a = outdata_reg_a == "UNREGISTERED" ? ra : ra2;
    assign q_b = outdata_reg_b == "UNREGISTERED" ? rb : rb2;
    assign eccstatus = 1'b0;
endmodule
