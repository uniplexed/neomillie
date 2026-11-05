// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// A small stand-in for T80pa, the Z80 core of MiSTer, in the top-level bench: T80 is VHDL and Verilator
// reads no VHDL. cpu_z80.v stays real. Bus cycles follow T80pa.vhd: address on CEN_p, MREQ# and RD# low
// on the CEN_n of T1, WAIT# sampled on each CEN_n and acted on at the next CEN_p from T2 on, opcode
// sampled at the CEN_p starting T3, RD# high on the CEN_n of T3, refresh in T3 and T4, one automatic
// wait in I/O cycles. It runs only the instructions the bench's sound program needs; anything else
// stops the simulation. It proves bus traffic, not the T80.
`timescale 1ns/1ps
module T80pa (
    input  wire        RESET_n,
    input  wire        CLK,
    input  wire        CEN_p,
    input  wire        CEN_n,
    input  wire        WAIT_n,
    input  wire        INT_n,
    input  wire        NMI_n,
    input  wire        BUSRQ_n,
    output reg         MREQ_n = 1,
    output reg         IORQ_n = 1,
    output reg         RD_n = 1,
    output reg         WR_n = 1,
    output reg         RFSH_n = 1,
    output wire        BUSAK_n,
    output reg  [15:0] A = 0,
    input  wire  [7:0] DI,
    output reg   [7:0] DO = 0
);
    assign BUSAK_n = 1'b1;

    logic [15:0] pc = 0, sp = 0;
    logic  [7:0] acc = 0;
    bit          zero = 0;
    bit          nmi_old = 1, nmi_pend = 0, abort = 0;

    // For the bench
    int nmi_count = 0, opcode_count = 0;

    always @(posedge CLK) if (CEN_p | CEN_n) begin
        nmi_old <= NMI_n;
        if (nmi_old && !NMI_n) nmi_pend <= 1;
    end

    task automatic tick_p();
        if (!abort) begin
            @(posedge CLK iff CEN_p);
            if (!RESET_n) abort = 1;
        end
    endtask

    task automatic tick_n();
        if (!abort) begin
            @(posedge CLK iff CEN_n);
            if (!RESET_n) abort = 1;
        end
    endtask

    task automatic idle_bus();
        MREQ_n <= 1;
        IORQ_n <= 1;
        RD_n   <= 1;
        WR_n   <= 1;
        RFSH_n <= 1;
    endtask

    // T2 and any wait states: return at the CEN_p that starts T3
    task automatic wait_states();
        logic w;
        tick_p();       // T2
        tick_n();
        w = WAIT_n;
        tick_p();
        while (!abort && !w) begin
            tick_n();
            w = WAIT_n;
            tick_p();
        end
    endtask

    task automatic m1(output logic [7:0] op);
        A <= pc;
        tick_n();
        MREQ_n <= 0;
        RD_n   <= 0;
        wait_states();
        op = DI;
        pc = pc + 1'd1;
        RFSH_n <= 0;
        tick_n();
        RD_n   <= 1;
        MREQ_n <= 1;
        tick_p();       // T4
        tick_n();
        MREQ_n <= 0;
        tick_p();
        MREQ_n <= 1;
        RFSH_n <= 1;
        opcode_count++;
    endtask

    task automatic mem_rd(input logic [15:0] a, output logic [7:0] d);
        A <= a;
        tick_n();
        MREQ_n <= 0;
        RD_n   <= 0;
        wait_states();
        tick_n();
        d = DI;
        RD_n   <= 1;
        MREQ_n <= 1;
        tick_p();
    endtask

    task automatic mem_wr(input logic [15:0] a, input logic [7:0] d);
        A  <= a;
        DO <= d;
        tick_n();
        MREQ_n <= 0;
        wait_states();
        WR_n <= 0;
        tick_n();
        WR_n   <= 1;
        MREQ_n <= 1;
        tick_p();
    endtask

    task automatic io_cycle(input bit wr, input logic [7:0] port, input logic [7:0] d, output logic [7:0] q);
        A <= {acc, port};
        if (wr) DO <= d;
        tick_n();
        tick_p();       // T2
        IORQ_n <= 0;
        if (wr) WR_n <= 0; else RD_n <= 0;
        tick_n();
        tick_p();       // Tw
        tick_n();
        wait_states();
        tick_n();
        q = DI;
        IORQ_n <= 1;
        RD_n   <= 1;
        WR_n   <= 1;
        tick_p();
    endtask

    task automatic imm8(output logic [7:0] d);
        mem_rd(pc, d);
        pc = pc + 1'd1;
    endtask

    task automatic imm16(output logic [15:0] d);
        logic [7:0] l, h;
        imm8(l);
        imm8(h);
        d = {h, l};
    endtask

    logic [7:0] op, b, tmp;
    logic [15:0] w;

    initial forever begin
        @(posedge CLK);
        if (!RESET_n || abort) begin
            idle_bus();
            pc = 0;
            nmi_pend = 0;
            abort = !RESET_n;
        end else begin
            @(posedge CLK iff CEN_p);
            if (nmi_pend) begin
                // Dummy M1 of five T states (not fetched from the program counter), then the pushes
                nmi_pend = 0;
                nmi_count++;
                m1(op);
                pc = pc - 1'd1;
                tick_n();
                tick_p();
                sp = sp - 1'd1;
                mem_wr(sp, pc[15:8]);
                sp = sp - 1'd1;
                mem_wr(sp, pc[7:0]);
                pc = 16'h0066;
            end else begin
                m1(op);
                if (!abort) case (op)
                    8'h00: ;                                                    // NOP
                    8'h18: begin imm8(b); pc = pc + 16'($signed(b)); end        // JR e
                    8'h20: begin imm8(b); if (!zero) pc = pc + 16'($signed(b)); end  // JR NZ,e
                    8'h31: imm16(sp);                                           // LD SP,nn
                    8'h32: begin imm16(w); mem_wr(w, acc); end                  // LD (nn),A
                    8'h3A: begin imm16(w); mem_rd(w, acc); end                  // LD A,(nn)
                    8'h3E: imm8(acc);                                           // LD A,n
                    8'hC3: begin imm16(w); pc = w; end                          // JP nn
                    8'hC6: begin imm8(b); acc = acc + b; zero = acc == 0; end   // ADD A,n
                    8'hD3: begin imm8(b); io_cycle(1, b, acc, tmp); end         // OUT (n),A
                    8'hDB: begin imm8(b); io_cycle(0, b, 8'h00, acc); end       // IN A,(n)
                    8'hFE: begin imm8(b); zero = acc == b; end                  // CP n
                    8'hED: begin
                        m1(op);
                        if (!abort && op != 8'h45) $fatal(1, "T80pa model: unknown ED %02x at %04x", op, pc);
                        mem_rd(sp, w[7:0]);                                     // RETN
                        sp = sp + 1'd1;
                        mem_rd(sp, w[15:8]);
                        sp = sp + 1'd1;
                        pc = w;
                    end
                    default: $fatal(1, "T80pa model: unknown opcode %02x at %04x", op, pc - 1'd1);
                endcase
            end
            if (abort) idle_bus();
        end
    end
endmodule
