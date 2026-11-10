// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// apf_loader against the real bridge rate and the real pocket_mem_mux, wired as neogeo_pocket.sv
// wires it: ioctl_wr through clk_sys and MiSTer's edge detector on CLK_96M. Every word is checked
// twice, where clk_sys sees ioctl_wr (masks, LO RAM) and where the mux takes DL_WR, and the chip
// models are read back. The block tests run the C formulas of neogeo_loader.cpp over the block.
`timescale 1ns/1ps
module tb_apf_loader;
`include "mem_map.svh"
`include "apf_regs.svh"

    localparam real PERIOD_96 = 10.344;     // 96.671316 MHz, the shortest period
    localparam real PERIOD_74 = 13.468;     // 74.25 MHz
    localparam int  HOLD      = 2000;       // clk_74a clocks of apf_core_reset, shortened for the bench
    localparam int  SILENCE   = 6187;       // 64 us of CLK_96M

    // What must have no effect
    localparam logic [11:0] IGNORED_REGS [8] = '{12'h014, 12'h01C, 12'h020, 12'h050, 12'h110, 12'h204, 12'h300, 12'h308};
    localparam logic [31:0] UNMAPPED_ADDRS [6] = '{32'h10B0_0000, 32'h10E0_0000, 32'h10F0_0000,
                                                   32'h1100_0000, 32'h3000_0000, 32'h8000_0000};

    logic clk96 = 0, clk48 = 0, clk74 = 0;
    // One process, so that the 48 MHz edge lands on the 96 MHz edge with no delta between them
    initial forever begin
        #(PERIOD_96 / 2) clk96 = 1;
        clk48 = ~clk48;
        #(PERIOD_96 / 2) clk96 = 0;
    end
    always #(PERIOD_74 / 2) clk74 = ~clk74;

    // ---- Bridge and host commands ----
    wire [31:0] bridge_addr, bridge_wr_data, bridge_rd_data, dut_rd_data, cd_rd_data;
    wire        bridge_wr, bridge_rd;
    logic       rd_cd = 0;      // which instance the host reads back from
    assign bridge_rd_data = rd_cd ? cd_rd_data : dut_rd_data;
    bridge_bfm bfm (.clk(clk74), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
                    .bridge_wr_data(bridge_wr_data), .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data));

    logic        reset_n = 0, allcomplete = 0, reconfiguring = 0, rtc_valid = 0;
    logic [31:0] rtc_date = 0, rtc_time = 0;
    logic [31:0] key1 = 0, key2 = 0, key3 = 0, key4 = 0;

    // The data table of core_bridge_cmd.v: 1 clock of read latency
    logic [31:0] dt [0:1023];
    logic [31:0] dt_q = 0;
    wire   [9:0] dt_addr;
    wire         dt_wren;
    wire  [31:0] dt_data;
    always @(posedge clk74) begin
        if (dt_wren) dt[dt_addr] = dt_data;
        dt_q <= dt[dt_addr];
    end

    // ---- DUT ----
    wire        ioctl_download, ioctl_wr, apf_core_reset, width320, mvs, prom1_conflict;
    wire  [7:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_dout, joy0, joy1, joy2, joy3, save_dout;
    wire [63:0] status;
    wire [31:0] cfg;
    wire [64:0] rtc;
    wire [23:0] v2_offset, v2rom_mask;
    wire  [2:0] video_slot;
    wire [14:0] sram_addr;
    wire [11:0] memcard_addr;
    wire        bk_req, bk_we, memcard_wr;
    logic       bk_ack = 0;
    logic [15:0] sram_q = 0, card_q = 0;

    logic        dsu = 0;                   // dataslot_update of core_bridge_cmd.v
    logic [15:0] dsu_id = 0;
    logic [31:0] dsu_size = 0;
    wire  [31:0] disc_size, disc_bin_size;
    wire         cd_mount_req;

    // The host's side of a data slot write: done falls, and rises when the file is written
    wire         rs_busy, rs_write;
    wire  [15:0] rs_slot;
    wire  [31:0] rs_bridge, rs_length;
    logic        rs_done = 0, rs_write_d = 0, rs_answer = 1;
    int          rs_t = 0;
    logic [79:0] rs_log[$];

    always @(posedge clk74) begin
        rs_write_d <= rs_write;
        if (rs_write && !rs_write_d && rs_answer) begin
            rs_log.push_back({rs_slot, rs_bridge, rs_length});
            rs_done <= 0;
            rs_t    <= 40;
        end
        else if (rs_t != 0) begin
            rs_t <= rs_t - 1;
            if (rs_t == 1) rs_done <= 1;
        end
    end

    apf_loader #(.RESET_HOLD_CLKS(HOLD)) dut (
        .clk_74a(clk74), .CLK_96M(clk96),
        .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .bridge_rd(bridge_rd), .bridge_rd_data(dut_rd_data),
        .reset_n(reset_n), .dataslot_allcomplete(allcomplete), .reconfiguring(reconfiguring),
        .dataslot_update(dsu), .dataslot_update_id(dsu_id), .dataslot_update_size(dsu_size),
        .rtc_valid(rtc_valid), .rtc_date_bcd(rtc_date), .rtc_time_bcd(rtc_time),
        .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dt_q),
        .cont1_key(key1), .cont2_key(key2), .cont3_key(key3), .cont4_key(key4),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .joystick_0(joy0), .joystick_1(joy1), .joystick_2(joy2), .joystick_3(joy3),
        .status(status), .cfg(cfg), .rtc(rtc), .v2_offset(v2_offset), .v2rom_mask(v2rom_mask),
        .width320(width320), .video_slot(video_slot), .mvs(mvs),
        .apf_core_reset(apf_core_reset), .prom1_conflict(prom1_conflict),
        .sram_addr(sram_addr), .bk_req(bk_req), .bk_we(bk_we), .bk_ack(bk_ack), .memcard_addr(memcard_addr), .memcard_wr(memcard_wr),
        .sd_buff_dout(save_dout), .sram_buff_dout(sram_q), .card_buff_dout(card_q),
        .disc_size(disc_size), .disc_bin_size(disc_bin_size), .cd_mount_req(cd_mount_req),
        .rs_busy(rs_busy), .rs_write(rs_write), .rs_slot(rs_slot), .rs_bridge(rs_bridge), .rs_length(rs_length),
        .rs_host_free(rs_t == 0), .rs_host_done(rs_done)
    );

    // The CD build, on the same bridge and with a data table of its own. Its ioctl and saves go nowhere
    logic [31:0] dtc [0:1023];
    logic [31:0] dtc_q = 0;
    wire   [9:0] dtc_addr;
    wire         dtc_wren;
    wire  [31:0] dtc_data;
    always @(posedge clk74) begin
        if (dtc_wren) dtc[dtc_addr] = dtc_data;
        dtc_q <= dtc[dtc_addr];
    end

    wire [63:0] cd_status;
    wire [31:0] cd_cfg, cd_disc_size, cd_disc_bin_size;
    wire        cd_mvs, cd_mount;
    int         cd_mounts = 0;
    always @(posedge clk74) if (cd_mount) cd_mounts++;

    apf_loader #(.RESET_HOLD_CLKS(HOLD), .CD_BUILD(1)) dut_cd (
        .clk_74a(clk74), .CLK_96M(clk96),
        .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .bridge_rd(bridge_rd), .bridge_rd_data(cd_rd_data),
        .reset_n(reset_n), .dataslot_allcomplete(allcomplete), .reconfiguring(reconfiguring),
        .dataslot_update(dsu), .dataslot_update_id(dsu_id), .dataslot_update_size(dsu_size),
        .rtc_valid(rtc_valid), .rtc_date_bcd(rtc_date), .rtc_time_bcd(rtc_time),
        .datatable_addr(dtc_addr), .datatable_wren(dtc_wren), .datatable_data(dtc_data), .datatable_q(dtc_q),
        .cont1_key(key1), .cont2_key(key2), .cont3_key(key3), .cont4_key(key4),
        .status(cd_status), .cfg(cd_cfg), .mvs(cd_mvs),
        .bk_ack(1'b0), .sram_buff_dout(16'd0), .card_buff_dout(16'd0),
        .disc_size(cd_disc_size), .disc_bin_size(cd_disc_bin_size), .cd_mount_req(cd_mount),
        .rs_host_free(1'b1), .rs_host_done(1'b1)
    );

    // ---- The saves: the mux's handshake to CRAM0, at the worst of 40 clocks an access; port B of memcard.v, clk_sys ----
    logic [15:0] bak [0:32767];
    logic [15:0] card [0:4095];
    int          bk_t = 0;
    always @(posedge clk96) begin
        bk_t <= bk_req != bk_ack ? bk_t + 1 : 0;
        if (bk_req != bk_ack && bk_t == 39) begin
            if (bk_we) bak[sram_addr] = save_dout;
            sram_q <= bak[sram_addr];
            bk_ack <= bk_req;
        end
    end
    always @(posedge clk48) begin
        if (memcard_wr) card[memcard_addr] = save_dout;
        card_q <= card[memcard_addr];
    end

    // ---- As neogeo_pocket.sv from ioctl_* to the mux ----
    logic [7:0] idx48 = 0;
    logic       wr48 = 0, wr_rd = 0, wr_rd1 = 0;
    always @(posedge clk48) begin
        idx48 <= ioctl_index;
        wr48  <= ioctl_wr;
    end
    always @(posedge clk96) begin
        wr_rd  <= wr48;
        wr_rd1 <= wr_rd;
    end
    wire dl_wr = ~wr_rd1 & wr_rd;

    logic mem_init = 1;
    wire  dl_overflow;
    tri   [15:0] dram_dq, c0_dq, c1_dq;
    wire  [12:0] dram_a;
    wire   [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire         c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire         c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;

    pocket_mem_mux mux (
        .CLK(clk96), .MEM_INIT(mem_init), .nRESET(1'b0), .nSYSTEM_G(1'b1), .SYSTEM_CDx(1'b0),
        .M68K_ADDR(20'd0), .M68K_DATA(16'h0), .nAS(1'b1), .nLDS(1'b1), .nUDS(1'b1),
        .nROMOE(1'b1), .nPORTOE(1'b1), .nSROMOE(1'b1), .P2ROM_ADDR(27'd0),
        .PROM_DATA(), .PROM_DATA_READY(),
        .PCK2(1'b1), .S_LATCH(16'd0), .FIX_BANK(2'b00), .FIX_EN(1'b1), .SROM_DATA(),
        .PCK1(1'b1), .CROM_ADDR(27'd0), .SPR_EN(1'b1), .CR_DOUBLE(), .REFRESH_EN(1'b0),
        .DL_EN(ioctl_download & idx48 != 8'd1 & idx48 != 8'd10), .DL_DATA(ioctl_dout), .DL_ADDR(ioctl_addr),
        .DL_WR(dl_wr), .DL_INDEX(idx48), .dl_overflow(dl_overflow), .dbg_c0(),
        .CD_TR_AREA(3'd0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
        .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'd0),
        .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
        .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
        .fx_req(), .fx_we(), .fx_word(), .fx_be(), .fx_wdata(), .fx_ack(1'b0), .fx_rdata(16'h0),
        .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0), .DMA_SDRAM_BUSY(),
        .adpcma_addr(25'd0), .adpcma_dout(), .adpcma_req(1'b0), .adpcma_ack(),
        .adpcmb_addr(25'd0), .adpcmb_dout(), .adpcmb_req(1'b0), .adpcmb_ack(),
        .v2_offset(v2_offset),
        .m1_addr(19'd0), .m1_dout(), .m1_req(1'b0), .m1_ack(),
        .BK_RD(1'b0), .BK_WR(2'b00), .bk_req(1'b0), .bk_we(1'b0), .bk_addr(15'd0), .bk_wdata(16'd0), .bk_ack(), .bk_rdata(), .ROM_COPY_BUSY(),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_wait(1'b0), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv),
        .cram1_cre(c1_cre), .cram1_ce0_n(c1_ce0), .cram1_ce1_n(c1_ce1), .cram1_oe_n(c1_oe), .cram1_we_n(c1_we),
        .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb)
    );

    sdram_model mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    psram_model mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(mux.u_cram0.dq_oe)
    );
    psram_model mem_c1 (
        .a(c1_a), .dq(c1_dq), .clk(c1_clk), .cre(c1_cre), .adv_n(c1_adv), .ce0_n(c1_ce0), .ce1_n(c1_ce1),
        .oe_n(c1_oe), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb), .fpga_dq_oe(mux.u_cram1.dq_oe)
    );

    // ---- Monitors ----
    typedef struct packed { logic [7:0] idx; logic [26:0] addr; logic [15:0] data; } wr_t;
    wr_t q48[$], q96[$];
    int  errors = 0, tests = 0;
    string test = "";

    function automatic void fail(input string msg);
        $display("FAIL %s: %s", test, msg);
        errors++;
        // A broken design can miss every word, and each miss waits: end the run instead
        if (errors >= 50) $fatal(1, "50 failures, stopping");
    endfunction

    always @(posedge clk48) if (ioctl_wr) begin
        q48.push_back('{ioctl_index, ioctl_addr, ioctl_dout});
        if (!ioctl_download) fail("ioctl_wr with ioctl_download low");
        if (!apf_core_reset) fail("ioctl_wr with the core out of reset");
    end

    // The ROM masks of neogeo_pocket.sv:585-630: built by ioctl_wr, smeared while status[0] is high and
    // cleared on its rising edge, so that edge must happen once per game
    logic [26:0] crom_mask = 0, v1_mask = 0, m_mask = 0, p2_mask = 0;
    logic        old_rst = 0;
    int          status0_rises = 0;
    wire [26:0]  p_off = 27'h200000 + ioctl_addr;
    always @(posedge clk48) begin
        old_rst <= status[0];
        if (status[0]) begin
            crom_mask <= crom_mask | crom_mask[26:1];
            v1_mask   <= v1_mask | v1_mask[26:1];
            m_mask    <= m_mask | m_mask[26:1];
            p2_mask   <= p2_mask | p2_mask[26:1];
        end
        if (ioctl_wr) begin
            if (idx48 == 8'd15) crom_mask <= crom_mask | ioctl_addr;
            else if (idx48 == 8'd16) v1_mask <= v1_mask | ioctl_addr;
            else if (idx48 == 8'd9) m_mask <= m_mask | ioctl_addr;
            else if (idx48 == 8'd4 && p_off >= 27'h300000) p2_mask <= p2_mask | (p_off - 27'h300000);
        end
        if (~old_rst & status[0]) begin
            status0_rises++;
            crom_mask <= 0;
            v1_mask   <= 0;
            m_mask    <= 0;
            p2_mask   <= 0;
        end
    end

    int dl_falls = 0, dl_rises = 0;
    logic [7:0] idx_at_fall = 0, idx_at_rise = 0;
    logic dl_last = 0;
    always @(posedge clk96) begin
        dl_last <= ioctl_download;
        if (dl_last && !ioctl_download) begin
            dl_falls++;
            idx_at_fall = ioctl_index;
        end
        if (!dl_last && ioctl_download) begin
            dl_rises++;
            idx_at_rise = ioctl_index;
        end
    end

    // The Task 5 contract at the mux's port, in CLK_96M clocks from one DL_WR to the next
    int gap = 1000, min_gap = 1000;
    always @(posedge clk96) begin
        if (gap < 1000) gap <= gap + 1;
        if (dl_wr) begin
            q96.push_back('{idx48, ioctl_addr, ioctl_dout});
            if (gap < (idx48 == 8'd15 ? 9 : 10)) fail($sformatf("rate contract: DL_WR %0d clocks after the last", gap));
            if (gap < min_gap) min_gap = gap;
            gap <= 1;
        end
        if (dl_overflow) fail("dl_overflow set");
    end

    // ---- Helpers ----
    task automatic begin_test(input string name);
        test = name;
        tests++;
    endtask

    // The next word at both places. A word that never comes is reported once, then gives up
    task automatic next_word(output wr_t w, output bit ok);
        int waited = 0;
        while ((q48.size() == 0 || q96.size() == 0) && waited < 20000) begin
            @(posedge clk96);
            waited++;
        end
        ok = q48.size() != 0 && q96.size() != 0;
        if (!ok) begin
            fail("expected ioctl word did not arrive");
            return;
        end
        w = q48.pop_front();
        if (q96[0] !== w) fail($sformatf("clk_sys saw idx %0d addr %h data %h, the mux %0d %h %h",
                                         w.idx, w.addr, w.data, q96[0].idx, q96[0].addr, q96[0].data));
        void'(q96.pop_front());
    endtask

    task automatic expect_word(input logic [7:0] idx, input logic [26:0] addr, input logic [15:0] data);
        wr_t w;
        bit  ok;
        next_word(w, ok);
        if (ok && (w.idx !== idx || w.addr !== addr || w.data !== data))
            fail($sformatf("got idx %0d addr %h data %h, expected idx %0d addr %h data %h",
                           w.idx, w.addr, w.data, idx, addr, data));
    endtask

    // Everything in flight has landed and nothing else came
    task automatic expect_quiet();
        repeat (400) @(posedge clk96);
        if (q48.size() != 0 || q96.size() != 0) begin
            fail($sformatf("%0d unexpected ioctl words, first addr %h", q48.size(), q48[0].addr));
            q48 = {};
            q96 = {};
        end
    endtask

    function automatic logic [15:0] c0_word(input logic [23:0] byte_addr);
        logic [22:0] k = byte_addr[23:1];
        return mem_c0.mem.exists(k) ? mem_c0.mem[k] : 16'hDEAD;
    endfunction
    function automatic logic [15:0] c1_word(input logic [23:0] byte_addr);
        logic [22:0] k = byte_addr[23:1];
        return mem_c1.mem.exists(k) ? mem_c1.mem[k] : 16'hDEAD;
    endfunction
    function automatic logic [15:0] sd_word(input logic [25:0] byte_addr);
        // Word address to {bank, row, column}, as sdram_ctrl splits it
        logic [24:0] k = {byte_addr[24:23], byte_addr[22:10], byte_addr[25], byte_addr[9:1]};
        return mem_sd.mem.exists(k) ? mem_sd.mem[k] : 16'hDEAD;
    endfunction

    function automatic void check16(input string what, input logic [15:0] got, input logic [15:0] exp);
        if (got !== exp) fail($sformatf("%s: got %h, expected %h", what, got, exp));
    endfunction

    task automatic setting(input logic [11:0] reg_addr, input logic [31:0] data);
        bfm.write32({20'hF0000, reg_addr}, data);
        repeat (6) @(posedge clk96);
    endtask

    // Whatever the tests before left: core running, ready for the next load
    task automatic host_idle();
        reset_n = 1;
        allcomplete = 1;
        repeat (HOLD * 2) @(posedge clk74);
    endtask

    // A bridge word: the first file byte is [31:24]
    function automatic logic [31:0] be32(input logic [7:0] b[$], input int at);
        return {b[at], b[at + 1], b[at + 2], b[at + 3]};
    endfunction

    // A pattern with no symmetry: each byte differs from every other in the block
    function automatic logic [7:0] pattern(input int i, input int seed);
        logic [15:0] x = 16'(i) * 16'd167 + 16'(seed) * 16'd13 + 16'h5B;
        return x[7:0] ^ x[15:8];
    endfunction

    // ---- Tests ----

    task automatic check_masks(input string when);
        if (crom_mask !== 27'hFFFFF) fail($sformatf("%s: CROM_MASK %h", when, crom_mask));
        if (v1_mask !== 27'h1FFFFF) fail($sformatf("%s: V1ROM_MASK %h", when, v1_mask));
        if (m_mask !== 27'h1FFFF) fail($sformatf("%s: MROM_MASK %h", when, m_mask));
        if (p2_mask !== 27'hFFFFF) fail($sformatf("%s: P2ROM_MASK %h", when, p2_mask));
        if (status0_rises != 1) fail($sformatf("%s: status[0] rose %0d times", when, status0_rises));
    endtask

    // The load at power-on, under status[0]: the top of each ROM sets its mask
    task automatic test_first_load_masks();
        begin_test("test_first_load_masks");
        if (!status[0] || !apf_core_reset) fail("status[0] not high at power-on");
        if (status[14]) fail("status[14] high at power-on");
        for (int i = 0; i < 32; i++) bfm.write32(32'h400F_FF80 + 32'(i * 4), 32'h0);
        bfm.write32(32'h201F_FFFC, 32'h0);
        bfm.write32(32'h10F9_FFFC, 32'h0);
        bfm.write32(32'h101F_FFFC, 32'h0);
        repeat (1500) @(posedge clk96);
        q48 = {};
        q96 = {};
        check_masks("after the load");
    endtask

    // A game is running. Nothing here may lose the masks, as only a full load rebuilds them
    task automatic test_reset_keeps_masks();
        begin_test("test_reset_keeps_masks");
        check_masks("after the first release");
        if (status[0] || status[14] || apf_core_reset) fail("not released");

        bfm.write32(32'hF000_0100, 1);          // Reset Core
        repeat (6) @(posedge clk96);
        if (status[0] !== 0 || status[14] !== 1 || !apf_core_reset) fail("Core_reset: status[0] low and status[14] high expected");
        repeat (HOLD + 200) @(posedge clk74);
        if (status[14] || apf_core_reset) fail("stuck after Core_reset");

        repeat (3) begin                        // The menu writing what is already there
            bfm.write32(32'hF000_0108, 1);
            repeat (6) @(posedge clk96);
            if (status[14] || apf_core_reset) fail("0x108 with the same value reset the core");
        end

        bfm.write32(32'hF000_0108, 0);          // MVS to AES
        repeat (6) @(posedge clk96);
        if (status[0] !== 0 || status[14] !== 1) fail("MVS/AES change: status[0] low and status[14] high expected");
        repeat (HOLD + 200) @(posedge clk74);
        repeat (2) bfm.write32(32'hF000_0108, 0);
        repeat (6) @(posedge clk96);
        if (status[14] || apf_core_reset) fail("0x108 with the same value reset the core, in AES");
        bfm.write32(32'hF000_0108, 1);
        repeat (6) @(posedge clk96);
        if (status[0] !== 0 || status[14] !== 1) fail("AES/MVS change");
        repeat (HOLD + 200) @(posedge clk74);

        reset_n = 0;                            // BIOS reload: Reset Enter, the slot, Reset Exit
        repeat (6) @(posedge clk96);
        if (status[0] !== 0 || status[14] !== 1) fail("Reset Enter: status[0] low and status[14] high expected");
        bfm.write32(32'h10A0_0000, 32'h0001_0203);
        expect_word(8'd0, 27'd0, 16'h0100);
        expect_word(8'd0, 27'd2, 16'h0302);
        reset_n = 1;
        repeat (HOLD + 200) @(posedge clk74);
        if (status[14] || apf_core_reset) fail("stuck after the BIOS reload");
        check_masks("after Reset Core, MVS/AES and a BIOS reload");
    endtask

    // The menu: read, change its bits, write. Items 6 and 7 share 0x20C
    task automatic rmw(input logic [11:0] reg_addr, input logic [31:0] and_mask, input logic [31:0] or_bits);
        logic [31:0] addr = {20'hF0000, reg_addr}, w;
        bfm.read32(addr, w);    // the strobe of this one loads the register
        bfm.read32(addr, w);
        bfm.write32(addr, (w & and_mask) | or_bits);
        repeat (6) @(posedge clk96);
    endtask

    task automatic expect_setting(input logic [11:0] reg_addr, input logic [31:0] exp);
        logic [31:0] addr = {20'hF0000, reg_addr}, w;
        bfm.read32(addr, w);
        bfm.read32(addr, w);
        if (w !== exp) fail($sformatf("read of %h gave %h, expected %h", reg_addr, w, exp));
    endtask

    task automatic test_settings_read_modify_write();
        logic [31:0] file[$];
        begin_test("test_settings_read_modify_write");
        expect_setting(REG_SYSTEM_TYPE, 1);     // the menu must show MVS, not a saved AES nobody chose
        expect_setting(REG_VIDEO_MODE, 0);
        expect_setting(REG_VIDEO_RATIO, 0);

        rmw(REG_VIDEO_RATIO, 32'hFFFF_FFFB, 32'h4);     // id 6: 320 wide
        if (width320 !== 1 || status[16] !== 0) fail("320 did not take");
        rmw(REG_VIDEO_RATIO, 32'hFFFF_FFFC, 32'h3);     // id 7: scale 3 must not clear the 320 bit
        if (width320 !== 1 || status[16] !== 0) fail("changing the scale cleared the 320 bit");
        if (video_slot !== 3'b111) fail($sformatf("slot %b", video_slot));
        expect_setting(REG_VIDEO_RATIO, 7);
        rmw(REG_VIDEO_RATIO, 32'hFFFF_FFFB, 32'h0);     // id 6: back to 304 keeps the scale
        if (width320 !== 0 || video_slot !== 3'b011) fail("304 lost the scale");
        rmw(REG_VIDEO_RATIO, 32'hFFFF_FFFC, 32'h0);
        expect_setting(REG_VIDEO_RATIO, 0);

        rmw(REG_VIDEO_MODE, 32'hFFFF_FFFE, 32'h1);
        if (status[3] !== 1) fail("PAL did not take");
        expect_setting(REG_VIDEO_MODE, 1);
        rmw(REG_VIDEO_MODE, 32'hFFFF_FFFE, 32'h0);
        expect_setting(REG_VIDEO_MODE, 0);

        rmw(REG_SYSTEM_TYPE, 32'hFFFF_FFFE, 32'h1);     // same value: nothing happens
        if (apf_core_reset) fail("a read-modify-write with no change reset the core");
        rmw(REG_SYSTEM_TYPE, 32'hFFFF_FFFE, 32'h0);
        if (!apf_core_reset) fail("MVS to AES did not reset the core");
        expect_setting(REG_SYSTEM_TYPE, 0);
        rmw(REG_SYSTEM_TYPE, 32'hFFFF_FFFE, 32'h1);
        expect_setting(REG_SYSTEM_TYPE, 1);

        bfm.write32(32'hF000_0100, 1);          // an action reads 0, so it never writes itself back on
        expect_setting(REG_CORE_RESET, 0);
        expect_setting(12'h204, 0);

        // Save reads share the output
        bfm.write32(32'h6000_0040, 32'h1234_5678);
        repeat (40) @(posedge clk96);
        bfm.read_file(32'h6000_0040, 1, file);
        if (file[0] !== 32'h1234_5678) fail($sformatf("save read after settings reads gave %h", file[0]));
        expect_setting(REG_VIDEO_RATIO, 0);
        host_idle();
    endtask

    task automatic test_cfg_defaults_zero();
        begin_test("test_cfg_defaults_zero");
        host_idle();
        if (cfg !== 32'h0080_0000) fail($sformatf("cfg = %h", cfg));
        if (status !== 64'h0000_0000_0001_0002) fail($sformatf("status = %h", status));
        if (v2_offset !== 0 || v2rom_mask !== 0) fail("v2 registers not 0");
        if (width320 !== 0 || video_slot !== 0) fail("video not 0");
        if (mvs !== 1) fail("SYSTEM_TYPE reset value must be MVS");
    endtask

    task automatic test_cfg_alias_overdrive();
        begin_test("test_cfg_alias_overdrive");
        // use_pcm: the Overdrive's sense is the inverse of MiSTer's
        setting(REG_USE_PCM, 1);
        if (cfg[23] !== 0) fail("0xF000030C = 1 must clear cfg[23]");
        setting(REG_USE_PCM, 0);
        if (cfg[23] !== 1) fail("0xF000030C = 0 must set cfg[23]");
        setting(REG_USE_PCM_OLD, 1);
        if (cfg[23] !== 0) fail("0xF0000028 = 1 must clear cfg[23]");
        setting(REG_USE_PCM_OLD, 0);
        if (cfg !== 32'h0080_0000) fail("use_pcm did not restore cfg");

        // cart_pchip: pvc is 2, sma is 2 + sub
        setting(REG_PCHIP_MAIN_OLD, 1);
        if (cfg[22:20] !== 3'd2) fail("cart_pchip_main");
        setting(REG_PCHIP_SUB, 3);      // main wins
        if (cfg[22:20] !== 3'd2) fail("cart_pchip_main over sub");
        setting(REG_PCHIP_MAIN, 0);
        for (int s = 1; s <= 5; s++) begin
            setting(REG_PCHIP_SUB_OLD, s);
            if (cfg[22:20] !== 3'(2 + s)) fail($sformatf("cart_pchip_sub %0d gives %0d", s, cfg[22:20]));
        end
        setting(REG_PCHIP_SUB, 6);
        if (cfg[22:20] !== 0) fail("cart_pchip_sub 6 must be none");
        setting(REG_PCHIP_SUB, 0);

        setting(REG_CART_CHIP_OLD, 2);
        if (cfg[25:24] !== 2) fail("cart_chip old");
        setting(REG_CART_CHIP, 1);
        if (cfg[25:24] !== 1) fail("cart_chip");
        setting(REG_CART_CHIP, 0);
        setting(REG_CMC_CHIP_OLD, 2);
        if (cfg[27:26] !== 2) fail("cmc_chip old");
        setting(REG_CMC_CHIP, 1);
        if (cfg[27:26] !== 1) fail("cmc_chip");
        setting(REG_CMC_CHIP, 0);

        // C1_wait: [2] rom_wait, [1:0] p_wait
        setting(REG_C1_WAIT_OLD, 3'b100);
        if (cfg[28] !== 1 || cfg[30:29] !== 0) fail("rom_wait");
        setting(REG_C1_WAIT, 3'b010);
        if (cfg[28] !== 0 || cfg[30:29] !== 2) fail("p_wait");
        setting(REG_C1_WAIT, 0);

        setting(REG_MS5P, 1);
        if (cfg[17] !== 1) fail("ms5p");
        setting(REG_MS5P, 0);
        setting(REG_XRAM, 1);
        if (cfg[18] !== 1) fail("xram");
        setting(REG_XRAM, 0);
        setting(REG_ADPCMA_EXT, 1);
        if (cfg[19] !== 1) fail("adpcma_ext");
        setting(REG_ADPCMA_EXT, 0);
        if (cfg !== 32'h0080_0000) fail($sformatf("cfg did not return, %h", cfg));

        // V2 from either address of the game JSON
        setting(REG_V2_OFFSET_OLD, 32'h00C0_0000);
        if (v2_offset !== 24'hC00000) fail("V2_offset old");
        setting(REG_V2_OFFSET, 32'h0080_0000);
        if (v2_offset !== 24'h800000) fail("V2_offset");
        setting(REG_V2_MASK_OLD, 32'h003F_FFFF);
        if (v2rom_mask !== 24'h3FFFFF) fail("V2ROM_MASK old");
        setting(REG_V2_MASK, 32'h001F_FFFF);
        if (v2rom_mask !== 24'h1FFFFF) fail("V2ROM_MASK");
        setting(REG_V2_OFFSET, 0);
        setting(REG_V2_MASK, 0);

        // status: the bits one by one, others stay
        setting(REG_DIPSW, 32'h0000_00FE);
        if (status[7] !== 1 || status[9:8] !== 0) fail("DIPSW[0] to status[7]");
        setting(REG_DIPSW_OLD, 32'h0000_003F);
        if (status[7] !== 0 || status[9:8] !== 2'b11) fail("DIPSW[7:6] to status[9:8]");
        setting(REG_DIPSW, 32'h0000_00FF);
        setting(REG_SYSTEM_TYPE_OLD, 0);
        if (status[1] !== 0 || mvs !== 0) fail("SYSTEM_TYPE old");
        setting(REG_SYSTEM_TYPE, 1);
        if (status[1] !== 1 || mvs !== 1) fail("SYSTEM_TYPE");
        setting(REG_VIDEO_MODE, 1);
        if (status[3] !== 1) fail("video_mode");
        setting(REG_VIDEO_MODE, 0);
        setting(REG_MEMCARD_OLD, 1);
        if (status[4] !== 1) fail("memory_card_enable old");
        setting(REG_MEMCARD, 0);
        if (status[4] !== 0) fail("memory_card_enable");

        // status[16] = 1 means 304 wide in MiSTer
        setting(REG_VIDEO_RATIO, 3'b100);
        if (status[16] !== 0 || width320 !== 1 || video_slot !== 3'b100) fail("APF_Video_ratio 320");
        setting(REG_VIDEO_RATIO, 3'b011);
        if (status[16] !== 1 || width320 !== 0 || video_slot !== 3'b011) fail("APF_Video_ratio 304");
        setting(REG_VIDEO_RATIO, 0);

        // Accepted and ignored
        foreach (IGNORED_REGS[i]) setting(IGNORED_REGS[i], 32'hFFFF_FFFF);
        setting(12'hFFC, 32'hFFFF_FFFF);
        host_idle();
        if (cfg !== 32'h0080_0000) fail($sformatf("an ignored write moved cfg, %h", cfg));
        if (status !== 64'h0000_0000_0001_0002) fail($sformatf("an ignored write moved status, %h", status));
    endtask

    task automatic test_start_without_game();
        begin_test("test_start_without_game");
        reset_n = 0;
        allcomplete = 0;
        repeat (6) @(posedge clk96);
        if (!apf_core_reset || !status[14] || status[0]) fail("not high with reset_n low");

        // Only the common files
        bfm.write32(32'h10A0_0000, 32'h0001_0203);
        expect_word(8'd0, 27'd0, 16'h0100);
        expect_word(8'd0, 27'd2, 16'h0302);
        for (int w = 0; w < 8; w++) bfm.write32(32'h10D0_0000 + 32'(w * 4), 32'h0);
        for (int w = 0; w < 16; w++) expect_word(8'd2, 27'(w * 2), 16'h0);
        bfm.write32(32'h5000_0000, 32'h0);
        for (int w = 0; w < 4; w++) expect_word(8'd1, 27'(w * 2), 16'h0);
        expect_quiet();

        reset_n = 1;
        repeat (HOLD * 2) @(posedge clk74);
        if (!apf_core_reset) fail("low before dataslot_allcomplete");

        allcomplete = 1;
        repeat (HOLD - 200) @(posedge clk74);
        if (!apf_core_reset) fail("low before the timer expired");
        repeat (400) @(posedge clk74);
        if (apf_core_reset || status[0] || status[14]) fail("still high after reset_n, allcomplete and the timer");

        // reset_n alone brings it back, at once and with allcomplete high (Reset Enter on a reload)
        reset_n = 0;
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("reset_n low with allcomplete high is ignored");
        reset_n = 1;
        repeat (HOLD - 200) @(posedge clk74);
        if (!apf_core_reset) fail("the timer did not run from Reset Exit");
        repeat (400) @(posedge clk74);
        if (apf_core_reset) fail("stuck after Reset Exit");

        // allcomplete falling (0x0082 of a new access sequence)
        allcomplete = 0;
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("allcomplete low is ignored");
        allcomplete = 1;
        repeat (HOLD + 200) @(posedge clk74);
        if (apf_core_reset) fail("stuck after allcomplete");

        // The timer restarts on the Core_reset action, an MVS/AES write, the first slot write, the PLL
        bfm.write32(32'hF000_0100, 0);
        repeat (6) @(posedge clk96);
        if (apf_core_reset) fail("Core_reset value_off restarted the timer");
        bfm.write32(32'hF000_0100, 1);
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("Core_reset did not restart the timer");
        repeat (HOLD + 200) @(posedge clk74);
        if (apf_core_reset) fail("stuck after Core_reset");

        bfm.write32(32'hF000_0108, 0);
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("SYSTEM_TYPE change did not restart the timer");
        repeat (HOLD + 200) @(posedge clk74);
        bfm.write32(32'hF000_0108, 1);
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("SYSTEM_TYPE change back did not restart the timer");
        repeat (HOLD + 200) @(posedge clk74);

        bfm.write32(32'h10A0_0000, 32'h0001_0203);  // reload with no Reset Enter: first_write_active
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("first slot write did not raise it");
        repeat (HOLD + 200) @(posedge clk74);
        if (apf_core_reset) fail("stuck after a slot write");
        q48 = {};
        q96 = {};

        @(posedge clk74);
        #1 reconfiguring = 1;
        repeat (6) @(posedge clk96);
        if (!apf_core_reset) fail("reconfiguring does not hold it");
        repeat (HOLD + 200) @(posedge clk74);
        if (!apf_core_reset) fail("released while the PLL reconfigures");
        #1 reconfiguring = 0;
        repeat (HOLD - 200) @(posedge clk74);
        if (!apf_core_reset) fail("no full hold after reconfiguring");
        repeat (400) @(posedge clk74);
        if (apf_core_reset) fail("stuck after reconfiguring");
    endtask

    task automatic test_byte_order_p_rom();
        begin_test("test_byte_order_p_rom");
        bfm.write32(32'h1000_0000, 32'h0001_0203);
        bfm.write32(32'h1000_0004, 32'h0405_0607);
        expect_word(8'd4, 27'd0, 16'h0100);
        expect_word(8'd4, 27'd2, 16'h0302);
        expect_word(8'd4, 27'd4, 16'h0504);
        expect_word(8'd4, 27'd6, 16'h0706);
        expect_quiet();
        check16("P ROM word 0 in CRAM0", c0_word(MAP_P1 + 24'd0), 16'h0100);
        check16("P ROM word 3 in CRAM0", c0_word(MAP_P1 + 24'd6), 16'h0706);
    endtask

    task automatic test_slot_to_index();
        logic [31:0] w;
        begin_test("test_slot_to_index");
        // Raw slots: one write
        bfm.write32(32'h10A0_0000, 32'hA1A2_A3A4);          // 1 BIOS
        expect_word(8'd0, 27'd0, 16'hA2A1);
        expect_word(8'd0, 27'd2, 16'hA4A3);
        bfm.write32(32'h1000_0000, 32'hB1B2_B3B4);          // 4 prom
        expect_word(8'd4, 27'd0, 16'hB2B1);
        expect_word(8'd4, 27'd2, 16'hB4B3);
        bfm.write32(32'h10F8_0000, 32'hC1C2_C3C4);          // 6 m1rom
        expect_word(8'd9, 27'd0, 16'hC2C1);
        expect_word(8'd9, 27'd2, 16'hC4C3);
        bfm.write32(32'h2000_0000, 32'hD1D2_D3D4);          // 7 vroma0, linear
        expect_word(8'd16, 27'd0, 16'hD2D1);
        expect_word(8'd16, 27'd2, 16'hD4D3);
        bfm.write32(32'h2080_0000, 32'hD5D6_D7D8);          // 7 past 8 MB: still 16, not 17 or 48
        expect_word(8'd16, 27'h800000, 16'hD6D5);
        expect_word(8'd16, 27'h800002, 16'hD8D7);
        bfm.write32(32'h1080_0000, 32'hE1E2_E3E4);          // 8 prom1 at 0x800000
        expect_word(8'd4, 27'h800000, 16'hE2E1);
        expect_word(8'd4, 27'h800002, 16'hE4E3);
        // 2 LO: one word per byte, byte in [7:0], addr + 2 per byte
        bfm.write32(32'h5000_0000, 32'h1011_1213);
        expect_word(8'd1, 27'd0, 16'h0010);
        expect_word(8'd1, 27'd2, 16'h0011);
        expect_word(8'd1, 27'd4, 16'h0012);
        expect_word(8'd1, 27'd6, 16'h0013);
        bfm.write32(32'h5000_FFFC, 32'hF1F2_F3F4);          // a 64 KB file ends at 0x1FFFE
        expect_word(8'd1, 27'h1FFF8, 16'h00F1);
        expect_word(8'd1, 27'h1FFFA, 16'h00F2);
        expect_word(8'd1, 27'h1FFFC, 16'h00F3);
        expect_word(8'd1, 27'h1FFFE, 16'h00F4);
        bfm.write32(32'h5001_0000, 32'h2122_2324);          // the second half of a 128 KB file: dropped,
        expect_quiet();                                     // or it would wrap over the first
        expect_quiet();
        check16("M1 in CRAM0", c0_word(MAP_M1), 16'hC2C1);
        check16("V in CRAM1", c1_word(24'h0), 16'hD2D1);
        check16("V 8 MB in CRAM1", c1_word(24'h800000), 16'hD6D5);
        check16("prom1 in CRAM0", c0_word(MAP_PROG1), 16'hE2E1);
        check16("BIOS in CRAM0", c0_word(MAP_BIOS), 16'hA2A1);

        // Block slots hold their words back until the block is whole: the index comes with them
        for (int s = 0; s < 2; s++) begin
            for (int i = 0; i < 8; i++) bfm.write32((s == 0 ? 32'h10C0_0000 : 32'h10D0_0000) + 32'(i * 4), 32'h0);
            for (int i = 0; i < 16; i++) expect_word(s == 0 ? 8'd8 : 8'd2, 27'(i * 2), 16'h0);
        end
        for (int i = 0; i < 32; i++) bfm.write32(32'h4000_0000 + 32'(i * 4), 32'h0);
        for (int i = 0; i < 64; i++) expect_word(8'd15, 27'(i * 2), 16'h0);
        expect_quiet();

        // The save regions and everything else in the map produce no ioctl word
        bfm.write32(32'h6000_0000, 32'h0);
        bfm.write32(32'h7000_0000, 32'h0);
        bfm.read32(32'h6000_0000, w);
        foreach (UNMAPPED_ADDRS[i]) bfm.write32(UNMAPPED_ADDRS[i], 32'h1234_5678);
        expect_quiet();
    endtask

    task automatic test_crom_overflow_ignored();
        begin_test("test_crom_overflow_ignored");
        for (int i = 0; i < 32; i++) bfm.write32(32'h4400_0000 + 32'(i * 4), 32'h5555_AAAA);
        for (int i = 0; i < 32; i++) bfm.write32(32'h4800_0000 + 32'(i * 4), 32'h5555_AAAA);
        expect_quiet();
        check16("first sprite word", sd_word(26'h0), 16'h0);
    endtask

    task automatic test_joystick_mapping();
        // U D L R, A B X/C Y/D, Start, Select on 9 and 10, then keys that drive nothing
        int          keys[15] = '{0, 1, 2, 3, 4, 5, 6, 7, 15, 14, 8, 9, 10, 11, 28};
        logic [15:0] joys[15] = '{16'h0008, 16'h0004, 16'h0002, 16'h0001, 16'h0010, 16'h0020, 16'h0040, 16'h0080,
                                  16'h0100, 16'h0600, 16'h0, 16'h0, 16'h0, 16'h0, 16'h0};
        begin_test("test_joystick_mapping");
        for (int i = 0; i < 15; i++) begin
            key1 = 32'd1 << keys[i];
            key2 = key1;
            key3 = key1;
            key4 = key1;
            repeat (6) @(posedge clk96);
            check16($sformatf("joystick_0 key %0d", keys[i]), joy0, joys[i]);
            check16($sformatf("joystick_1 key %0d", keys[i]), joy1, joys[i]);
            check16($sformatf("joystick_2 key %0d", keys[i]), joy2, joys[i]);
            check16($sformatf("joystick_3 key %0d", keys[i]), joy3, joys[i]);
        end
        // Each pad is its own
        key1 = 32'h1; key2 = 32'h2; key3 = 32'h4; key4 = 32'h8;
        repeat (6) @(posedge clk96);
        if ({joy0, joy1, joy2, joy3} !== {16'h8, 16'h4, 16'h2, 16'h1}) fail("pads are crossed");
        key1 = 0; key2 = 0; key3 = 0; key4 = 0;
    endtask

    task automatic test_save_roundtrip();
        logic [31:0] got, last, file[$];
        begin_test("test_save_roundtrip");

        // A write lands in two 16-bit words, {b1, b0} and {b3, b2}, as MiSTer's save file
        bfm.write32(32'h6000_0000, 32'h1122_3344);
        bfm.write32(32'h6000_1FFC, 32'h5566_7788);      // top of the 8 KB file
        repeat (40) @(posedge clk96);
        check16("card word 0", card[0], 16'h2211);
        check16("card word 1", card[1], 16'h4433);
        check16("card word 4094", card[4094], 16'h6655);
        check16("card word 4095", card[4095], 16'h8877);
        bfm.write32(32'h7000_0000, 32'h99AA_BBCC);
        bfm.write32(32'h7000_FFFC, 32'hDDEE_FF00);      // top of the 64 KB file
        repeat (120) @(posedge clk96);      // two accesses of 40 clocks, the bench's slowest CRAM0
        check16("backup word 0", bak[0], 16'hAA99);
        check16("backup word 1", bak[1], 16'hCCBB);
        check16("backup word 32766", bak[32766], 16'hEEDD);
        check16("backup word 32767", bak[32767], 16'h00FF);
        check16("the card is not the backup", card[0], 16'h2211);

        for (int i = 0; i < 16; i++) bfm.write32(32'h6000_0100 + 32'(i * 4), 32'hCA00_0000 + 32'(i));
        for (int i = 0; i < 16; i++) bfm.write32(32'h7000_0100 + 32'(i * 4), 32'hBA00_0000 + 32'(i));

        // The one-word lag: the word of address N is in the read of N + 1
        for (int b = 0; b < 2; b++) begin
            logic [31:0] base = b == 0 ? 32'h6000_0100 : 32'h7000_0100;
            logic [31:0] tag  = b == 0 ? 32'hCA00_0000 : 32'hBA00_0000;
            bfm.read32(base, last);
            for (int i = 1; i < 16; i++) begin
                bfm.read32(base + 32'(i * 4), got);
                if (got !== tag + 32'(i - 1))
                    fail($sformatf("region %0d: read of word %0d gave %h, expected word %0d", b, i, got, i - 1));
            end

            // And the file the host makes of that has no lag
            bfm.read_file(base, 15, file);
            for (int i = 0; i < 15; i++)
                if (file[i] !== tag + 32'(i)) fail($sformatf("region %0d: file word %0d is %h", b, i, file[i]));
        end

        // The top words
        bfm.read_file(32'h6000_1FFC, 1, file);
        if (file[0] !== 32'h5566_7788) fail($sformatf("top of the card file is %h", file[0]));
        bfm.read_file(32'h7000_FFFC, 1, file);
        if (file[0] !== 32'hDDEE_FF00) fail($sformatf("top of the backup file is %h", file[0]));
    endtask

    task automatic reset_core_and_wait(input string what);
        rs_log.delete();
        bfm.write32(32'hF000_0100, 1);
        repeat (20) @(posedge clk74);
        if (!apf_core_reset) fail({what, ": no reset"});
        for (int i = 0; i < 16 * HOLD && rs_busy; i++) @(posedge clk74);
        if (rs_busy) fail({what, ": still saving"});
        if (!apf_core_reset) fail({what, ": the core left reset during the save"});
        repeat (2 * HOLD) @(posedge clk74);
        if (apf_core_reset) fail({what, ": stuck in reset"});
    endtask

    task automatic test_reset_core_writes_saves();
        begin_test("test_reset_core_writes_saves");
        bfm.write32(32'hF000_0108, 1);
        repeat (2 * HOLD) @(posedge clk74);
        reset_core_and_wait("MVS");
        if (rs_log.size() != 2 || rs_log[0] !== {16'h0101, 32'h6000_0000, 32'd8192} || rs_log[1] !== {16'h0102, 32'h7000_0000, 32'd65536})
            fail($sformatf("MVS: %0d writes", rs_log.size()));

        bfm.write32(32'hF000_0108, 0);
        repeat (2 * HOLD) @(posedge clk74);
        reset_core_and_wait("AES");
        if (rs_log.size() != 1 || rs_log[0] !== {16'h0101, 32'h6000_0000, 32'd8192}) fail($sformatf("AES: %0d writes", rs_log.size()));

        // A host that never answers does not leave the core in reset
        rs_answer = 0;
        rs_done   = 0;
        reset_core_and_wait("no answer");
        rs_answer = 1;

        bfm.write32(32'hF000_0108, 1);
        repeat (2 * HOLD) @(posedge clk74);
    endtask

    task automatic test_datatable_size_loop();
        begin_test("test_datatable_size_loop");
        // Written by the host in clk_74a at setup: {id, size} pairs in the order of data.json
        dt[0] = 32'h0;     dt[1] = 32'h0;
        dt[2] = 32'h101;   dt[3] = 32'hFFFF_FFFF;
        dt[4] = 32'h102;   dt[5] = 32'hFFFF_FFFF;
        dt[6] = 32'h1;     dt[7] = 32'h101;             // a size that reads like an id
        dt[8] = 32'h7;     dt[9] = 32'd5;
        repeat (2000) @(posedge clk74);
        if (dt[3] !== 32'd8192) fail($sformatf("memory card size %0d", dt[3]));
        if (dt[5] !== 32'd65536) fail($sformatf("backup size %0d", dt[5]));
        if (dt[7] !== 32'h101 || dt[9] !== 32'd5) fail("another slot's size moved");
        if (dt[6] !== 32'h1 || dt[8] !== 32'h7 || dt[2] !== 32'h101) fail("an id moved");
    endtask

    task automatic test_rtc_repack();
        begin_test("test_rtc_repack");
        if (rtc[64] !== 0) fail("toggle before the host sent the time");
        rtc_date = 32'h2022_1031;
        rtc_time = 32'h0523_5958;       // weekday 5, 23:59:58
        repeat (2) @(posedge clk74);
        #1 rtc_valid = 1;
        repeat (6) @(posedge clk96);
        if (rtc[64] !== 1) fail("no toggle");
        if (rtc[50:48] !== 3'd6) fail($sformatf("weekday %0d", rtc[50:48]));
        if (rtc[47:40] !== 8'h22) fail("year");
        if (rtc[36:32] !== 5'h10) fail("month");
        if (rtc[29:24] !== 6'h31) fail("day");
        if (rtc[21:16] !== 6'h23) fail("hour");
        if (rtc[14:8] !== 7'h59) fail("minute");
        if (rtc[6:0] !== 7'h58) fail("second");
        if ({rtc[63:51], rtc[39:37], rtc[31:30], rtc[23:22], rtc[15], rtc[7]} !== 0) fail("unused bits set");
    endtask

    // ---- Block conversions ----

    // fix_convert, neogeo_loader.cpp:108
    function automatic int c_fix(input int i);
        return (i & ~32'h1F) | ((i >> 2) & 7) | ((i & 1) << 3) | (((i & 2) << 3) ^ 32'h10);
    endfunction

    // spr_convert_dbl, neogeo_loader.cpp:83, over 16-bit words
    function automatic int c_spr(input int i);
        return (i & ~32'h3F) | ((i ^ 1) & 1) | ((i >> 1) & 32'h1E) | (((i & 2) ^ 2) << 4);
    endfunction

    task automatic test_fix_convert_block();
        begin_test("test_fix_convert_block");
        for (int s = 0; s < 2; s++) begin
            logic [31:0] base = s == 0 ? 32'h10C0_0000 : 32'h10D0_0000;
            logic [7:0]  idx  = s == 0 ? 8'd8 : 8'd2;
            logic [23:0] map  = s == 0 ? MAP_SROM : MAP_SFIX;
            logic [7:0]  in[$];
            for (int i = 0; i < 96; i++) in.push_back(pattern(i, s));    // three blocks
            for (int i = 0; i < 96; i += 4) bfm.write32(base + 32'(i), be32(in, i));
            for (int i = 0; i < 96; i += 2) begin
                logic [15:0] exp = {in[c_fix(i + 1)], in[c_fix(i)]};
                expect_word(idx, 27'(i), exp);
            end
            expect_quiet();
            for (int i = 0; i < 96; i += 2)
                check16($sformatf("slot %0d chip word %0d", s == 0 ? 3 : 9, i / 2), c0_word(map + 24'(i)),
                        {in[c_fix(i + 1)], in[c_fix(i)]});
        end
    endtask

    task automatic test_spr_convert_block();
        logic [7:0] in[$];
        logic [15:0] in_w[$];
        begin_test("test_spr_convert_block");
        for (int i = 0; i < 256; i++) in.push_back(pattern(i, 7));       // two blocks
        for (int i = 0; i < 256; i += 2) in_w.push_back({in[i + 1], in[i]});
        for (int i = 0; i < 256; i += 4) bfm.write32(32'h4010_0000 + 32'(i), be32(in, i));
        for (int i = 0; i < 128; i++) expect_word(8'd15, 27'h100000 + 27'(i * 2), in_w[c_spr(i)]);
        expect_quiet();
        for (int i = 0; i < 128; i++)
            check16($sformatf("sprite chip word %0d", i), sd_word(26'h100000 + 26'(i * 2)), in_w[c_spr(i)]);
    endtask

    // A block is whole or it is nothing, and what follows it does not suffer
    task automatic test_block_boundaries();
        logic [7:0] in[$];
        begin_test("test_block_boundaries");
        for (int i = 0; i < 64; i++) in.push_back(pattern(i, 3));

        // A fix block still open when the next slot starts is dropped
        for (int i = 0; i < 28; i += 4) bfm.write32(32'h10C0_1000 + 32'(i), be32(in, i));
        bfm.write32(32'h1000_0100, 32'h0001_0203);
        expect_word(8'd4, 27'h100, 16'h0100);
        expect_word(8'd4, 27'h102, 16'h0302);
        expect_quiet();

        // A word lost inside a block drops that block; the next aligned block is complete
        for (int i = 0; i < 12; i += 4) bfm.write32(32'h10C0_2000 + 32'(i), be32(in, i));
        for (int i = 16; i < 32; i += 4) bfm.write32(32'h10C0_2000 + 32'(i), be32(in, i));
        expect_quiet();
        for (int i = 32; i < 64; i += 4) bfm.write32(32'h10C0_2000 + 32'(i), be32(in, i));
        for (int i = 32; i < 64; i += 2) expect_word(8'd8, 27'h2000 + 27'(i), {in[c_fix(i + 1)], in[c_fix(i)]});
        expect_quiet();

        // A file starting mid-block has nothing to convert until the next boundary
        for (int i = 16; i < 64; i += 4) bfm.write32(32'h10D0_0400 + 32'(i), be32(in, i));
        for (int i = 32; i < 64; i += 2) expect_word(8'd2, 27'h400 + 27'(i), {in[c_fix(i + 1)], in[c_fix(i)]});
        expect_quiet();

        // The last word of a sprite block with the next slot right behind it: nothing is lost,
        // and the next slot's index waits for the block
        for (int i = 0; i < 32; i++) bfm.write32(32'h4020_0000 + 32'(i * 4), 32'h5A00_0000 + 32'(i));
        bfm.write32(32'h1000_0200, 32'h0001_0203);
        bfm.write32(32'h1000_0204, 32'h0405_0607);
        for (int i = 0; i < 64; i++) begin
            int s = c_spr(i);
            expect_word(8'd15, 27'h200000 + 27'(i * 2), s[0] ? 16'(16'h0000 | (s >> 1) << 8) : 16'h005A);
        end
        expect_word(8'd4, 27'h200, 16'h0100);
        expect_word(8'd4, 27'h202, 16'h0302);
        expect_word(8'd4, 27'h204, 16'h0504);
        expect_word(8'd4, 27'h206, 16'h0706);
        expect_quiet();
    endtask

    task automatic test_download_window();
        begin_test("test_download_window");
        repeat (SILENCE + 100) @(posedge clk96);
        if (ioctl_download) fail("still high after the silence");

        bfm.write32(32'h1000_0300, 32'h0001_0203);
        expect_word(8'd4, 27'h300, 16'h0100);
        expect_word(8'd4, 27'h302, 16'h0302);
        if (!ioctl_download) fail("low right after the last word");

        // Still up well inside 64 us, down after it
        repeat (SILENCE - 400) @(posedge clk96);
        if (!ioctl_download) fail("fell before 64 us of silence");
        repeat (800) @(posedge clk96);
        if (ioctl_download) fail("did not fall after 64 us of silence");

        // A new slot: it falls with the old index and rises with the new one
        bfm.write32(32'h1000_0400, 32'h0);
        expect_word(8'd4, 27'h400, 16'h0);
        expect_word(8'd4, 27'h402, 16'h0);
        dl_falls = 0;
        dl_rises = 0;
        bfm.write32(32'h2000_0100, 32'h0);
        expect_word(8'd16, 27'h100, 16'h0);
        expect_word(8'd16, 27'h102, 16'h0);
        if (dl_falls != 1 || dl_rises != 1) fail($sformatf("%0d falls and %0d rises at the slot change", dl_falls, dl_rises));
        if (idx_at_fall !== 8'd4 || idx_at_rise !== 8'd16) fail($sformatf("fell at index %0d, rose at %0d", idx_at_fall, idx_at_rise));
        expect_quiet();
    endtask

    task automatic test_prom1_conflict();
        begin_test("test_prom1_conflict");
        if (prom1_conflict !== 0) fail("set by the normal loads above");

        // Normal order: prom ends at 8 MB, other slots, prom1 at 0x800000
        reset_n = 0;
        repeat (4) @(posedge clk74);
        reset_n = 1;
        bfm.write32(32'h107F_FFFC, 32'h0);
        bfm.write32(32'h4000_0000, 32'h0);
        bfm.write32(32'h1080_0000, 32'h0);
        bfm.write32(32'h1080_0004, 32'h0);
        @(posedge clk74);
        if (prom1_conflict !== 0) fail("a normal prom and prom1 set it");

        // prom1 straight after an 8 MB prom is still normal
        reset_n = 0;
        repeat (4) @(posedge clk74);
        reset_n = 1;
        @(posedge clk74);
        if (prom1_conflict !== 0) fail("not cleared by reset");
        bfm.write32(32'h107F_FFFC, 32'h0);
        bfm.write32(32'h1080_0000, 32'h0);
        bfm.write32(32'h1080_0004, 32'h0);
        @(posedge clk74);
        if (prom1_conflict !== 0) fail("prom1 right behind prom set it");

        // A prom running past 8 MB, then a prom1 of its own
        bfm.write32(32'h4000_0000, 32'h0);
        bfm.write32(32'h1080_0000, 32'h0);
        @(posedge clk74);
        if (prom1_conflict !== 1) fail("prom past 8 MB plus prom1 did not set it");

        reset_n = 0;
        repeat (4) @(posedge clk74);
        reset_n = 1;
        @(posedge clk74);
        if (prom1_conflict !== 0) fail("not cleared by reset");
        repeat (2000) @(posedge clk96);
        q48 = {};
        q96 = {};
    endtask

    // The CD build's settings land in the status bits of MiSTer's CD core, and read back for the menu
    task automatic test_cd_settings();
        begin_test("test_cd_settings");
        host_idle();
        // Changing CD/CDZ restarts the core as Reset Core does, the same value does not, and the cart ignores it
        setting(REG_CD_TYPE, 1);
        repeat (10) @(posedge clk96);
        if (cd_status[14] !== 1 || cd_status[0] !== 0) fail($sformatf("changing CD/CDZ: status = %h", cd_status));
        if (status[14] !== 0) fail("the cart took CD/CDZ as a reset");
        repeat (HOLD + 100) @(posedge clk74);
        if (cd_status[14] !== 0) fail("stuck after changing CD/CDZ");
        setting(REG_CD_TYPE, 1);
        repeat (10) @(posedge clk96);
        if (cd_status[14] !== 0) fail("CD/CDZ written unchanged reset the core");
        setting(REG_CD_REGION, 2);
        setting(REG_CD_SPEED, 3);
        setting(REG_CD_LID, 1);
        repeat (10) @(posedge clk96);
        if (cd_status[2] !== 1 || cd_status[11:10] !== 2 || cd_status[30:29] !== 3 || cd_status[15] !== 1)
            fail($sformatf("status = %h", cd_status));
        if (cd_cfg[31] !== 1) fail($sformatf("CD cfg = %h", cd_cfg));
        if (cd_mvs !== 0) fail("the CD build must not run the MVS clock");
        // The cart build ignores all of them
        if (cfg[31] !== 0 || mvs !== 1) fail($sformatf("cart cfg = %h, mvs = %b", cfg, mvs));
        if (status[2] !== 0 || status[11:10] !== 0 || status[30:29] !== 0 || status[15] !== 0)
            fail($sformatf("the cart took a CD setting, status = %h", status));
        rd_cd = 1;
        expect_setting(REG_CD_TYPE, 1);
        expect_setting(REG_CD_REGION, 2);
        expect_setting(REG_CD_SPEED, 3);
        expect_setting(REG_CD_LID, 1);
        rd_cd = 0;
        setting(REG_CD_TYPE, 0);
        setting(REG_CD_REGION, 0);
        setting(REG_CD_SPEED, 0);
        setting(REG_CD_LID, 0);
        repeat (10) @(posedge clk96);
        if (cd_status[2] !== 0 || cd_status[11:10] !== 0 || cd_status[30:29] !== 0 || cd_status[15] !== 0)
            fail($sformatf("settings did not clear, status = %h", cd_status));
        repeat (HOLD + 100) @(posedge clk74);       // the CD/CDZ change above restarted the CD instance
    endtask

    // The disc slots' sizes come from the data table, and a mount is asked for when the host loads slot 2
    task automatic test_disc_size_and_mount_req();
        begin_test("test_disc_size_and_mount_req");
        for (int i = 0; i < 1024; i++) dtc[i] = 0;
        host_idle();
        allcomplete = 0;
        repeat (100) @(posedge clk74);
        allcomplete = 1;                        // no disc: nothing to mount
        repeat (100) @(posedge clk74);
        if (cd_mounts != 0 || disc_size !== 0 || cd_disc_size !== 0) fail("a mount with no disc");

        dtc[0] = 32'h1;   dtc[1] = 32'd2;       // a size that reads like the disc's id
        dtc[2] = 32'h2;   dtc[3] = 32'h1234_5678;
        dtc[4] = 32'h3;   dtc[5] = 32'h0000_9ABC;
        dtc[6] = 32'h101; dtc[7] = 32'hFFFF_FFFF;
        repeat (2000) @(posedge clk74);
        if (cd_disc_size !== 32'h1234_5678) fail($sformatf("disc size %h", cd_disc_size));
        if (cd_disc_bin_size !== 32'h0000_9ABC) fail($sformatf("disc data size %h", cd_disc_bin_size));
        if (dtc[7] !== 32'd8192) fail("the memory card slot lost its answer");
        if (disc_size !== 0 || disc_bin_size !== 0 || cd_mount_req !== 0) fail("the cart took a disc size");
        if (cd_mounts != 0) fail("a mount before the host finished");

        allcomplete = 0;
        repeat (50) @(posedge clk74);
        allcomplete = 1;                        // the load is over and a disc is there
        repeat (50) @(posedge clk74);
        if (cd_mounts != 1) fail($sformatf("%0d mount requests at allcomplete", cd_mounts));

        dsu <= 1; dsu_id <= 16'd2;              // the disc changed
        @(posedge clk74);
        dsu <= 0;
        repeat (50) @(posedge clk74);
        if (cd_mounts != 2) fail($sformatf("%0d mount requests after a disc update", cd_mounts));
        if (cd_disc_size !== 32'h1234_5678) fail("a pick with no size in its command left the table's");

        dsu <= 1; dsu_id <= 16'd2; dsu_size <= 32'h0000_4321;   // the table still has the last disc's size
        @(posedge clk74);
        dsu <= 0;
        @(posedge clk74);
        @(posedge clk74);
        if (cd_disc_size !== 32'h0000_4321) fail($sformatf("disc size %h at the pick's mount request", cd_disc_size));
        repeat (2000) @(posedge clk74);
        if (cd_disc_size !== 32'h0000_4321) fail($sformatf("disc size %h a table sweep after the pick", cd_disc_size));
        if (cd_mounts != 3) fail($sformatf("%0d mount requests after a sized pick", cd_mounts));
        if (disc_size !== 0) fail("the cart took a pick's size");

        dsu <= 1; dsu_id <= 16'd1; dsu_size <= 32'h0000_0777;
        @(posedge clk74);
        dsu <= 0;
        repeat (50) @(posedge clk74);
        if (cd_disc_size !== 32'h0000_4321) fail("another slot's update changed the disc size");
        if (cd_mounts != 3) fail($sformatf("%0d mount requests after another slot's update", cd_mounts));
        if (cd_mount_req !== 0) fail("the cart asked for a mount");
        host_idle();
    endtask

    // ---- Sequence ----
    initial begin
        #1;
        for (int i = 0; i < 1024; i++) dt[i] = 0;
        for (int i = 0; i < 32768; i++) bak[i] = 0;
        for (int i = 0; i < 4096; i++) card[i] = 0;
        repeat (20) @(posedge clk96);
        mem_init = 0;
        repeat (13000) @(posedge clk96);    // the SDRAM's startup

        test_first_load_masks();
        test_cfg_defaults_zero();
        test_reset_keeps_masks();
        test_settings_read_modify_write();
        test_cfg_alias_overdrive();
        test_joystick_mapping();
        test_datatable_size_loop();
        test_rtc_repack();
        test_start_without_game();
        host_idle();
        test_byte_order_p_rom();
        test_slot_to_index();
        test_crom_overflow_ignored();
        test_fix_convert_block();
        test_spr_convert_block();
        test_block_boundaries();
        test_save_roundtrip();
        test_reset_core_writes_saves();
        test_download_window();
        test_prom1_conflict();
        test_cd_settings();
        test_disc_size_and_mount_req();

        if (dl_overflow) fail("dl_overflow");
        if (status0_rises != 1) fail($sformatf("status[0] rose %0d times in the run", status0_rises));
        if (mem_sd.error_count != 0 || mem_c0.error_count != 0 || mem_c1.error_count != 0)
            fail($sformatf("memory model errors: %0d %0d %0d", mem_sd.error_count, mem_c0.error_count, mem_c1.error_count));
        if (errors != 0) $fatal(1, "%0d failures in %0d tests", errors, tests);
        $display("apf: %0d tests passed, dl_overflow low, memory models clean, tightest DL_WR gap %0d clocks", tests, min_gap);
        $finish;
    end

    initial begin
        #20ms;      // a passing run takes under 2 ms
        $fatal(1, "timeout");
    end

endmodule
