# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Clock constraints for the Pocket build. Replaces apf_constraints.sdc plus
# core_constraints.sdc of the core-template (same APF clocks, PLL clock names differ).

create_clock -name clk_74a -period 13.468 [get_ports clk_74a]
create_clock -name clk_74b -period 13.468 [get_ports clk_74b]
create_clock -name bridge_spiclk -period 13.468 [get_ports bridge_spiclk]

derive_pll_clocks
derive_clock_uncertainty

# The APF clocks are asynchronous to each other and to the Neo Geo PLL. The PLL outputs
# (96/48 MHz and the two pixel clocks) come from one VCO and stay together in one group.
set_clock_groups -asynchronous \
    -group { bridge_spiclk } \
    -group { clk_74a } \
    -group { clk_74b } \
    -group [get_clocks {*cyclonev_pll|counter*divclk}]

# SDRAM (Task 2). dram_clk is the 96 MHz clock inverted by the DDR output cell in
# sdram_ctrl (so the SDRAM samples on the falling edge of the controller clock).
# Delay values from the datasheet of the Pocket's AS4C32M16MSA-6BIN (Analogue developer page,
# external hardware). The x16 datasheet was not available, so the numbers come from its x32
# sibling AS4C16M32MSA-6BIN (same family and speed grade, AC characteristics pages 17-18):
#  - input max 5.9 = tAC(3) 5.5 ns (CL3, 1.8 V) + 0.4 ns board flight;
#  - input min 2.5 = tOH 2.5 ns, board flight conservatively taken as 0;
#  - output max 2.0 = tCMS/tCAS/tCDS (command, address, data setup) 2.0 ns;
#  - output min -1.0 = -tCMH/tCAH/tCDH (hold) 1.0 ns.
# Re-check against the x16 datasheet and the board when it is at hand.
create_generated_clock -name dram_clk -invert \
    -source [get_pins -compatibility_mode {*cyclonev_pll|counter[0].output_counter|divclk}] \
    [get_ports dram_clk]

set_input_delay  -clock dram_clk -max 5.9 [get_ports {dram_dq[*]}]
set_input_delay  -clock dram_clk -min 2.5 [get_ports {dram_dq[*]}]

set_output_delay -clock dram_clk -max  2.0 [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]
set_output_delay -clock dram_clk -min -1.0 [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]

# Word 0 of a burst (CL3): READ is registered at core edge t, the SDRAM (inverted clock) sees
# it at t+0.5T, starts driving the data on its edge t+2.5T (tAC after that edge) and the core
# captures it at t+4T, i.e. 1.5 clocks after the launching dram_clk edge (the single-cycle
# default is 0.5T). Same 1.5 clock relationship as for CL2, one core clock later.
# No -hold exception: the next word launches T/2 before this capture, so the default hold
# check against it is a real constraint.
set_multicycle_path -setup -end 2 -from [get_clocks dram_clk]     -to [get_clocks {*cyclonev_pll|counter[0].output_counter|divclk}]

# PSRAM (Task 3). The AS1C8M16PL-70BIN runs asynchronously, with no clock on its pins: nothing on
# the chip is related to a clock edge, and its timing comes from the clock counts in cram_ctrl.
# What STA must guarantee is the register-to-pad delay those counts assume, so these are windows
# on that delay, not chip timing: a register that misses its IOE fails here. Delays are in the
# frame of the 96 MHz PLL output, as measured with both controllers in the placeholder top:
#  - outputs reach the pad 3.44 (Fast 0C) to 8.46 ns (Slow 85C) after the edge, at most 1.1 ns
#    apart between pins in one corner. -max 1.5 and -min -3.0 allow 3.0 to 8.71 (T - 1.5 - 0.13
#    of clock uncertainty). All OE registers are packed in the IOEs (dq_oe~_Duplicate_n);
#  - inputs need the pad at most 0.18 ns (Fast 85C) before the edge. -max 8.5 allows 1.71. The
#    fitter sizes the input delay chain against this: with a loose -max it adds up to 3.5 ns;
#  - input hold: the chip drives until OE#/CE#, launched on the sampling edge, reach it, which
#    is at least the 3.44 above (tOHZ has no minimum, board flight taken as 0). -min 3.0.
# RD_WAIT budget from these windows: 8.71 + 1.71 + 0.8 assumed flight = 11.22 ns on top of tAA 70,
# covered by 8 clocks (82.72 ns) with 1.50 ns spare. 7 clocks (72.38 ns) would not be.
set cram_out [get_ports {cram?_a[*] cram?_dq[*] cram?_adv_n cram?_ce?_n cram?_oe_n cram?_we_n cram?_ub_n cram?_lb_n}]
set cram_in  [get_ports {cram?_dq[*]}]
set clk_96   [get_clocks {*cyclonev_pll|counter[0].output_counter|divclk}]
set_output_delay -clock $clk_96 -max  1.5 $cram_out
set_output_delay -clock $clk_96 -min -3.0 $cram_out
set_input_delay  -clock $clk_96 -max  8.5 $cram_in
set_input_delay  -clock $clk_96 -min  3.0 $cram_in

# SRAM. The AS6C2016-55BIN holds the fix and part of M1 in the cart core and FIX RAM in the CD core. sram_port launches
# every pin from a register on CLK_48M. As for the PSRAM above, these constraints are windows on the delay the port's clock
# counts assume, in the frame of the 48 MHz PLL output (CLK_48M, shortest period T = 20.687 ns). The chip's own timing is in
# sram_model.sv.
#  - outputs (address, data, strobes, enables), reg to pad: -max 2.0 allows up to T - 2.0 - 0.12
#    (clock uncertainty) = 18.6 ns after the edge, -min -1.0 allows no less than 1.0 ns. The window
#    is 17.6 ns wide, less than a clock: of two pins launched a clock apart the later one cannot
#    arrive first, which is the ordering sram_port relies on. The model checks it as ORDER_NS.
#  - inputs (read data): the chip's data cannot be valid earlier than the last output at its latest
#    (T - 2.0 = 18.7 ns) + 0.4 board flight (ASSUMED, no board data) + tAA/tBA 55 ns (tOE 30 ns is
#    shorter) + 0.4 flight = 74.5 ns after the edge: -max 74.5. -min 0.0: tOHZ and tBHZ have no
#    minimum and flight is taken as 0.
#  - the read data goes from the pins straight to a register in sram_port. The rule asks 4 edges of it: -setup 4 from the
#    pins, -hold 3 so that hold stays the same-edge check, as for SDRAM above. RD_CLKS is 5, one more than STA checks.
set clk_48   [get_clocks {*cyclonev_pll|counter[1].output_counter|divclk}]
set sram_out [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set sram_in  [get_ports {sram_dq[*]}]
set_output_delay -clock $clk_48 -max  2.0 $sram_out
set_output_delay -clock $clk_48 -min -1.0 $sram_out
set_input_delay  -clock $clk_48 -max 74.5 $sram_in
set_input_delay  -clock $clk_48 -min  0.0 $sram_in
set_multicycle_path -setup -end 4 -from $sram_in
set_multicycle_path -hold  -end 3 -from $sram_in

# 48 to 96 MHz hold is a same-edge check over two clock trees 0.5 ns apart: placements of this top
# land at -0.06 to +0.12 ns at the fast corners on CROM_ADDR to sd_addr. The fitter gets 0.2 ns more
# to aim for. Timing analysis itself is not changed, it still checks the true requirement.
# 96 to 48 MHz is the same check the other way: a placement of the RD_WAIT 7 build landed at -0.028 ns
# at Fast 0C on SROM_DATA to neo_b1's FIXD_REG, a path that build did not change.
if { $::quartus(nameofexecutable) == "quartus_fit" } {
    set_clock_uncertainty -add -hold 0.2 -from $clk_48 -to $clk_96
    set_clock_uncertainty -add -hold 0.2 -from $clk_96 -to $clk_48
}

# Z80 multicycle of MiSTer's NeoGeo.sdc (no match in the memtest projects, which only warn)
set_multicycle_path -from [get_registers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_registers {*|Z80CPU|*}] -hold 1
