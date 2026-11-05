# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Added to pocket.sdc for the memory self-test.

# The PSRAM output window of pocket.sdc, for this top only. On this small top the 96 MHz clock tree
# puts the pads 0.6 ns later than on the real core: 8.84 ns at Slow 85C, the latest being OE (packed
# in the IOEs). -max 1.25 allows 8.96. What the window guards is the RD_WAIT budget, and the 0.25 ns
# comes out of its spare: 8.96 + 1.71 + 0.8 = 11.47 ns on tAA 70, 1.25 ns under 82.72. Pin to pin times
# are clocks apart and only see the skew; turnarounds have 20.68 ns against 7 + 11.47.
set_output_delay -clock [get_clocks {*cyclonev_pll|counter[0].output_counter|divclk}] -max 1.25 \
    [get_ports {cram?_a[*] cram?_dq[*] cram?_adv_n cram?_ce?_n cram?_oe_n cram?_we_n cram?_ub_n cram?_lb_n}]

# The only crossing from the test to the pixel clocks
# is the results shown on screen; a torn digit for one frame is harmless, and these paths would
# otherwise have one 96 MHz period through the text mux. No other path of the test is relaxed.
set_false_path -from [get_clocks {*cyclonev_pll|counter[0].output_counter|divclk}] \
               -to   [get_clocks {*cyclonev_pll|counter[2].output_counter|divclk}]
