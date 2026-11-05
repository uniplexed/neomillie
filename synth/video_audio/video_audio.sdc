# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Clocks as in synth/neogeo/pocket.sdc: CLK_48M and CLK_PIX (8 x 20.687 ns) come from one VCO and are
# related; clk_74a is asynchronous to them.
create_clock -name clk_74a  -period 13.468  [get_ports clk_74a]
create_clock -name clk_48m  -period 20.687  [get_ports clk_48m]
create_clock -name clk_pix  -period 165.496 [get_ports clk_pix]
derive_clock_uncertainty
set_clock_groups -asynchronous -group { clk_74a } -group { clk_48m clk_pix }
