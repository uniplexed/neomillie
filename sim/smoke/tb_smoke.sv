// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Smoke test for the simulation runner: a counter must reach 10.
module tb_smoke;
    logic clk = 0;
    int   count = 0;

    always #5 clk = ~clk;
    always @(posedge clk) count <= count + 1;

    initial begin
        repeat (12) @(posedge clk);
        if (count < 10) $fatal(1, "counter reached only %0d", count);
        $display("smoke ok: count=%0d", count);
        $finish;
    end
endmodule
