// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// The real top: core_top with core_bridge_cmd, apf_loader, neogeo_pocket with the real fx68k, LSPC, jt10
// and every block of the core, pocket_mem_mux and the three memory controllers, against the models of
// the chips. Only three things are stand-ins: pll_pocket (clocks; the real pll_mvs_cfg), T80pa (the T80
// is VHDL) and the Altera RAMs. The program is tools/make_test_roms.py, which needs no Neo Geo ROM.
//
// Host sequence as Analogue's docs give it: Reset Enter, slots, all complete, persisted settings,
// Reset Exit. Bridge words at the real rate of one per 88 clocks.
//
// test_power_up    reset, work RAM sweep before release, first fetches from the BIOS, the program's
//                  steps: work RAM, ROM zones, palette, video RAM, Z80 handshake
// test_masks       ROM masks after the load
// test_picture     fix and sprite pixels on the APF video pins, from S ROM and SFIX
// test_sound       ADPCM-A from CRAM1 through jt10 to the I2S pin
// test_inputs      P1 controller through loader and neo_c1 to the 68K
// test_reset_core  Reset Core: masks kept, RAM cleared, program restarts, picture back
// test_relock      MVS to AES and back: PLL relock, memories through MEM_INIT, ROMs intact, game runs
// test_saves       memory card and backup through the bridge into the real RAMs and back, the host's way.
//                  A few bridge words, about 10 us. Not the 68K's side of the card, and not a power cycle
// test_wait_budget clocks the memory costs the 68K, against a limit
// test_wait_counter (with NEOGEO_WAIT_COUNTER) the debug counter against this bench, and its save file
//
// All along: every read on the 68K bus latches what the memory holds, and each class of cycle is
// measured against the budgets of the mux. The chip models check their own timing.
`timescale 1ns/1ps
module tb_top;
    localparam real PERIOD_74 = 13.468;
    localparam int  HOLD = 2000;            // clk_74a clocks of apf_core_reset, shortened for the bench

    // Numbers of tools/make_test_roms.py
    localparam logic [23:1] MBOX_W = 23'h087F80, VBL_W = 23'h087F82, P1_W = 23'h087F83;
    localparam int FIX_COL = 5, FIX_ROW = 10, SPR_X = 100, SPR_Y = 100;

    logic clk74 = 0;
    always #(PERIOD_74 / 2) clk74 = ~clk74;

    // ---- DUT and chips ----
    wire [31:0] bridge_addr, bridge_wr_data, bridge_rd_data;
    wire        bridge_wr, bridge_rd;
    logic [31:0] key1 = 0, key2 = 0;

    tri  [15:0] dram_dq, c0_dq, c1_dq, s_dq;
    wire [12:0] dram_a;
    wire  [1:0] dram_ba, dram_dqm;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] c0_a, c1_a;
    wire        c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb;
    wire        c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb;
    wire [16:0] s_a;
    wire        s_oe, s_we, s_ub, s_lb;
    wire [23:0] video_rgb;
    wire        video_clk, video_clk90, video_de, video_skip, video_vs, video_hs;
    wire        audio_mclk, audio_dac, audio_lrck;

    bridge_bfm bfm (.clk(clk74), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
                    .bridge_wr_data(bridge_wr_data), .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data));

    core_top #(.RESET_HOLD_CLKS(HOLD)) dut (
        .clk_74a(clk74), .clk_74b(clk74),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_wait(1'b0), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv),
        .cram0_cre(c0_cre), .cram0_ce0_n(c0_ce0), .cram0_ce1_n(c0_ce1), .cram0_oe_n(c0_oe), .cram0_we_n(c0_we),
        .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_wait(1'b0), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv),
        .cram1_cre(c1_cre), .cram1_ce0_n(c1_ce0), .cram1_ce1_n(c1_ce1), .cram1_oe_n(c1_oe), .cram1_we_n(c1_we),
        .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
        .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
        .sram_a(s_a), .sram_dq(s_dq), .sram_oe_n(s_oe), .sram_we_n(s_we), .sram_ub_n(s_ub), .sram_lb_n(s_lb),
        .vblank(1'b0), .dbg_rx(1'b1), .user2(1'b0), .port_ir_rx(1'b1),
        .video_rgb(video_rgb), .video_rgb_clock(video_clk), .video_rgb_clock_90(video_clk90), .video_de(video_de),
        .video_skip(video_skip), .video_vs(video_vs), .video_hs(video_hs),
        .audio_mclk(audio_mclk), .audio_adc(1'b0), .audio_dac(audio_dac), .audio_lrck(audio_lrck),
        .bridge_endian_little(), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data),
        .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .cont1_key(key1), .cont2_key(key2), .cont3_key(32'd0), .cont4_key(32'd0),
        .cont1_joy(32'd0), .cont2_joy(32'd0), .cont3_joy(32'd0), .cont4_joy(32'd0),
        .cont1_trig(16'd0), .cont2_trig(16'd0), .cont3_trig(16'd0), .cont4_trig(16'd0)
    );

    // A relock stops refresh for the relock and the controller's 125 us startup: more than JEDEC's 8
    // postponed refreshes, once, by about 0.3% of the 64 ms retention period.
    sdram_model #(.MAX_POSTPONE(40)) mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    // The models poll, and a poll can see read data that late. The 0.1 ns default takes minutes per
    // simulated millisecond with a whole core. RD_WAIT 8 has 1.5 ns spare at the AES clock (82.75 ns against
    // 81.22), so the PSRAM poll must stay under that; the SRAM has tens of ns.
    // SIM_DEFINES runs other configurations: RD_WAIT 7 with PSRAM_T_ACC 60, RD_WAIT 6 with 50 and a shorter
    // poll, 0.84 ns spare. Those chip speeds are assumed: this shows the logic, not that a chip keeps up.
`ifndef PSRAM_T_ACC
`define PSRAM_T_ACC 70.0
`endif
`ifndef PSRAM_POLL_NS
`define PSRAM_POLL_NS 1.0
`endif
    psram_model #(.T_ACC(`PSRAM_T_ACC), .POLL_NS(`PSRAM_POLL_NS)) mem_c0 (
        .a(c0_a), .dq(c0_dq), .clk(c0_clk), .cre(c0_cre), .adv_n(c0_adv), .ce0_n(c0_ce0), .ce1_n(c0_ce1),
        .oe_n(c0_oe), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb), .fpga_dq_oe(dut.neogeo.SDRAM_MUX.u_cram0.dq_oe)
    );
    psram_model #(.T_ACC(`PSRAM_T_ACC), .POLL_NS(`PSRAM_POLL_NS)) mem_c1 (
        .a(c1_a), .dq(c1_dq), .clk(c1_clk), .cre(c1_cre), .adv_n(c1_adv), .ce0_n(c1_ce0), .ce1_n(c1_ce1),
        .oe_n(c1_oe), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb), .fpga_dq_oe(dut.neogeo.SDRAM_MUX.u_cram1.dq_oe)
    );
    sram_model #(.POLL_NS(2.0)) mem_s (
        .a(s_a), .dq(s_dq), .oe_n(s_oe), .we_n(s_we), .ub_n(s_ub), .lb_n(s_lb), .fpga_dq_oe(dut.neogeo.SRAM_PORT.dq_oe),
        .cut_write_ok(1'b0)
    );

    // ---- Core signals the monitors watch ----
    wire        clk48 = dut.clk_48m;
    wire        clk96 = dut.clk_96m;
    wire        nRESET = dut.neogeo.nRESET;
    wire        nAS = dut.neogeo.nAS, nLDS = dut.neogeo.nLDS, nUDS = dut.neogeo.nUDS, RW = dut.neogeo.M68K_RW;
    wire [23:1] CPU_A = dut.neogeo.M68K_ADDR;
    wire [15:0] CPU_IN = dut.neogeo.FX68K_DATAIN, CPU_OUT = dut.neogeo.FX68K_DATAOUT;
    wire        nWRL = dut.neogeo.nWRL, nWRU = dut.neogeo.nWRU, nWWL = dut.neogeo.nWWL, nWWU = dut.neogeo.nWWU;
    wire        nROMOE = dut.neogeo.nROMOE, nPORTOE = dut.neogeo.nPORTOE, nSROMOE = dut.neogeo.nSROMOE;
    wire        nDTACK = dut.neogeo.nDTACK_ADJ, READY = dut.neogeo.PROM_DATA_READY;
    wire        PHI2 = dut.neogeo.CLK_EN_68K_N;
    wire        LATCH = (dut.neogeo.M68KCPU.FX68K.excUnit.dataIo.xToIrc | dut.neogeo.M68KCPU.FX68K.excUnit.dataIo.xToDbin) & PHI2;

    int errors = 0, tests = 0;
    string test = "";

    // For mutation runs. +failfast stops at the first failure, +quick skips the tests that only wait
    bit fail_fast = $test$plusargs("failfast");
    bit quick = $test$plusargs("quick");

    function automatic void fail(input string msg);
        $display("FAIL %s t=%0.0f us: %s", test, $realtime / 1000.0, msg);
        errors++;
        if (errors >= 30 || fail_fast) $fatal(1, "stopping after %0d failures", errors);
    endfunction

    function automatic void check(input bit ok, input string msg);
        if (!ok) fail(msg);
    endfunction

    // ---- The watchdog's 8 frames of reset ----
    // watchdog.v keeps nRESET low for 8 BNKB edges after nRST, 133 ms. The first release runs that in
    // full; after it the count is moved on, so nRESET rises on the next BNKB edge, still on the frame.
    // With +fastwd the first release does too, for bring-up.
    bit nrst_d = 0;
    bit fast_first = $test$plusargs("fastwd");
    always @(posedge clk48) begin
        nrst_d <= dut.neogeo.nRESET_CORE;
        if (dut.neogeo.nRESET_CORE && !nrst_d && (releases != 0 || fast_first)) dut.neogeo.B1.WD.WDCNT = 4'hF;
    end

    // ---- Reset, the work RAM clear ----
    int  releases = 0, setup_rises = 0;
    bit  setup_d = 0;
    always @(posedge clk74) begin
        setup_d <= dut.status_setup_done;
        if (dut.status_setup_done && !setup_d) setup_rises++;
    end
    bit  nreset_d = 0;
    longint swept_words = 0;
    always @(posedge clk48) begin
        nreset_d <= nRESET;
        // The copy of S and M1 to the SRAM must be over when the core leaves reset, and the work RAM cleared
        if (nRESET && !nreset_d && dut.neogeo.sram_busy) fail("the core left reset while the ROM copy was running");
        if (nRESET && !nreset_d) begin
            automatic int bad = 0;
            for (int i = 0; i < 32768; i++)
                if (dut.neogeo.WRAML.altsyncram_component.mem[i] != 0 || dut.neogeo.WRAMU.altsyncram_component.mem[i] != 0) bad++;
            check(bad == 0, $sformatf("%0d work RAM words not zero when the core left reset", bad));
            bad = 0;
            for (int i = 0; i < 'h10000; i++) begin
                automatic bit [22:0] k = 23'h600000 + 23'(i);     // MAP_SROM, in words
                if (mem_s.mem[i] !== (mem_c0.mem.exists(k) ? mem_c0.mem[k] : 16'h0000)) bad++;
            end
            check(bad == 0, $sformatf("%0d S ROM words differ between the SRAM and CRAM0 when the core left reset", bad));
            releases++;
        end
    end

    // ---- The 68K bus, one record per cycle ----
    // stable is the read margin: clocks the data had been there at the last latch, 0 if it arrived on
    // that clock.
    typedef enum int { C_BIOS, C_P1, C_P2, C_WRAM_R, C_WRAM_W, C_OTHER_R, C_OTHER_W, C_N } cycle_t;
    string cname [C_N] = '{"BIOS read", "P1 read", "P2 read", "work RAM read", "work RAM write", "other read", "other write"};

    typedef struct {
        longint n;
        int len_min, len_max;           // nAS low, CLK_48M
        longint len_sum;
        int ds_min, ds_max;             // strobe fall to strobe rise, CLK_48M
        int as_ds_max;                  // nAS fall to strobe fall
        int dt_min, dt_max;             // strobe fall to nDTACK low
        int latch_min, latch_max;       // strobe fall to the last latch
        int stable_min;                 // data unchanged this many clocks before the last latch
        int rdy_min, rdy_max;           // mux: strobe fall to PROM_DATA_READY, CLK_96M
    } stat_t;
    stat_t st [C_N];

    initial foreach (st[i]) begin
        st[i].n = 0; st[i].len_min = 9999; st[i].len_max = 0; st[i].len_sum = 0; st[i].ds_min = 9999; st[i].ds_max = 0;
        st[i].as_ds_max = 0; st[i].dt_min = 9999; st[i].dt_max = 0; st[i].latch_min = 9999; st[i].latch_max = 0;
        st[i].stable_min = 9999; st[i].rdy_min = 9999; st[i].rdy_max = 0;
    end

    bit    in_cycle = 0;
    int    c_len = 0, c_ds = -1, c_dt = -1, c_latch = -1, c_stable = 0, c_dslen = 0, c_as_ds = 0;
    cycle_t c_class = C_OTHER_R;
    logic [15:0] c_data = 0, c_prev = 0;
    logic [23:1] c_addr = 0;
    logic [22:0] c_word = 0;
    bit    c_rw = 1, c_rl = 0, c_ru = 0, wr_seen = 0;
    int    stable_cnt = 0;
    // First fetches
    logic [23:1] first_addr [8];
    bit          first_sys [8];
    int          first_n = 0;

    // Progress of the program
    logic [15:0] mbox = 0, mbox_log [$];
    logic [15:0] vbl_count = 0, p1_copy = 0;

    // ---- What the memory costs the 68K ----
    // A bus cycle with no wait state keeps nAS low for 10 CLK_48M; each wait state adds 4. Lost clocks are
    // those past 10 in a ROM zone read. Arrival is what CRAM0 was doing on the clock the 68K's request
    // reached the mux. An access in its ack clock counts as idle: the mux gives the chip to the 68K on it.
    localparam int IDEAL_LEN = 10;
    // Measured at RD_WAIT 8: 2.10% over a whole run, 2.48% over the first frame, where this bench's program
    // is at its most ROM bound. Over this the bench fails. A read that finds CRAM0 idle never waits at
    // RD_WAIT 8, 7: one that does means the read itself has grown past what the 68K allows.
    localparam real WAIT_LOST_LIMIT_PCT = 3.0;
    typedef enum int { A_IDLE, A_FIX, A_Z80, A_LOADER, A_68K, A_N } arrive_t;
    string aname [A_N] = '{"idle", "fix read", "Z80 read", "loader", "68K read"};
    typedef struct {
        longint n, waited, lost;
        int rdy_ok_min, rdy_ok_max;     // request to PROM_DATA_READY, CLK_96M, reads with no wait state
        int rdy_wait_min, rdy_wait_max; // and reads with one
    } arrive_stat_t;
    arrive_stat_t ar [A_N];
    arrive_t c_arrive = A_IDLE;
    int      c_rdy = 0;
    longint  clk68k = 0;                // CLK_48M with the 68K out of reset

    initial foreach (ar[i]) begin
        ar[i].n = 0; ar[i].waited = 0; ar[i].lost = 0;
        ar[i].rdy_ok_min = 9999; ar[i].rdy_ok_max = 0; ar[i].rdy_wait_min = 9999; ar[i].rdy_wait_max = 0;
    end

    always @(posedge clk48) if (nRESET) clk68k++;

    function automatic void count_rom_read(input int len);
        automatic int lost = len > IDEAL_LEN ? len - IDEAL_LEN : 0;
        ar[c_arrive].n++;
        if (lost != 0) begin
            ar[c_arrive].waited++;
            ar[c_arrive].lost += lost;
            if (c_rdy < ar[c_arrive].rdy_wait_min) ar[c_arrive].rdy_wait_min = c_rdy;
            if (c_rdy > ar[c_arrive].rdy_wait_max) ar[c_arrive].rdy_wait_max = c_rdy;
        end else begin
            if (c_rdy < ar[c_arrive].rdy_ok_min) ar[c_arrive].rdy_ok_min = c_rdy;
            if (c_rdy > ar[c_arrive].rdy_ok_max) ar[c_arrive].rdy_ok_max = c_rdy;
        end
    endfunction

    function automatic cycle_t classify();
        if (!RW) return (!nWWL || !nWWU) ? C_WRAM_W : C_OTHER_W;
        if (!nSROMOE) return C_BIOS;
        if (!nROMOE)  return C_P1;
        if (!nPORTOE) return C_P2;
        if (!nWRL || !nWRU) return C_WRAM_R;
        return C_OTHER_R;
    endfunction

    wire ds_low = ~(nLDS & nUDS);

    always @(posedge clk48) begin
        // Blocking: on the clock of a latch this says what the CPU takes now, 0 if it changed just now
        stable_cnt = CPU_IN != c_prev ? 0 : stable_cnt + 1;
        c_prev = CPU_IN;

        if (!nRESET) begin
            in_cycle <= 0;
        end else if (!nAS && !in_cycle) begin
            in_cycle <= 1;
            c_len <= 1; c_ds <= -1; c_dt <= -1; c_latch <= -1; c_dslen <= 0;
            c_addr <= CPU_A;
            c_rw <= RW;
        end else if (in_cycle) begin
            c_len <= c_len + 1;
            if (ds_low && c_ds < 0) begin
                c_ds <= c_len;
                c_class <= classify();
                c_as_ds <= c_len;
            end
            if (ds_low) c_dslen <= c_dslen + 1;
            if (ds_low && !RW && (!nWWL || !nWWU)) c_class <= C_WRAM_W;
            if (c_ds >= 0 && !nDTACK && c_dt < 0) c_dt <= c_len - c_ds;
            if (LATCH && c_ds >= 0) begin
                c_latch  <= c_len - c_ds;
                c_data   <= CPU_IN;
                c_word   <= dut.neogeo.SDRAM_MUX.m68k_word;
                c_stable <= stable_cnt;
                {c_rl, c_ru} <= {~nLDS, ~nUDS};
            end
            if (nAS) begin
                in_cycle <= 0;
                if (c_ds >= 0) begin
                    automatic cycle_t k = c_class;
                    if (k == C_BIOS || k == C_P1 || k == C_P2) count_rom_read(c_len);
                    st[k].n++;
                    st[k].len_sum += c_len;
                    if (c_len < st[k].len_min) st[k].len_min = c_len;
                    if (c_len > st[k].len_max) st[k].len_max = c_len;
                    if (c_dslen < st[k].ds_min) st[k].ds_min = c_dslen;
                    if (c_dslen > st[k].ds_max) st[k].ds_max = c_dslen;
                    if (c_as_ds > st[k].as_ds_max) st[k].as_ds_max = c_as_ds;
                    if (c_dt < st[k].dt_min) st[k].dt_min = c_dt;
                    if (c_dt > st[k].dt_max) st[k].dt_max = c_dt;
                    if (c_latch >= 0) begin
                        if (c_latch < st[k].latch_min) st[k].latch_min = c_latch;
                        if (c_latch > st[k].latch_max) st[k].latch_max = c_latch;
                        if (c_stable < st[k].stable_min) st[k].stable_min = c_stable;
                    end
                    // What the CPU took from the work RAM must be what the chip holds now
                    if (k == C_WRAM_R && c_latch >= 0) begin
                        automatic logic [15:0] want = {dut.neogeo.WRAMU.altsyncram_component.mem[c_addr[15:1]],
                                                       dut.neogeo.WRAML.altsyncram_component.mem[c_addr[15:1]]};
                        if ((c_rl && c_data[7:0] != want[7:0]) || (c_ru && c_data[15:8] != want[15:8]))
                            fail($sformatf("work RAM read at %06x latched %04x, the chip holds %04x", {c_addr, 1'b0}, c_data, want));
                    end
                    // And what it took from a ROM what the PSRAM holds
                    if ((k == C_BIOS || k == C_P1 || k == C_P2) && c_latch >= 0) begin
                        automatic logic [15:0] want = mem_c0.mem.exists(c_word) ? mem_c0.mem[c_word] : 16'h0000;
                        if ((c_rl && c_data[7:0] != want[7:0]) || (c_ru && c_data[15:8] != want[15:8]))
                            fail($sformatf("%s at %06x latched %04x, the PSRAM holds %04x", cname[k], {c_addr, 1'b0}, c_data, want));
                    end
                    if (first_n < 8) begin
                        first_addr[first_n] = c_addr;
                        first_sys[first_n] = k == C_BIOS;
                        first_n++;
                    end
                end
            end
        end

        // Program's own results, on the falling edge of a write strobe to work RAM
        if (nRESET && (!nWWL || !nWWU) && !wr_seen) begin
            wr_seen = 1;
            if (CPU_A == MBOX_W) begin
                mbox = CPU_OUT;
                mbox_log.push_back(CPU_OUT);
            end
            if (CPU_A == VBL_W) vbl_count = CPU_OUT;
            if (CPU_A == P1_W) p1_copy = CPU_OUT;
        end
        if (nWWL && nWWU) wr_seen = 0;
    end

    // A ROM read here is ready 18 CLK_96M after the strobe at worst, in time for the last latch even with
    // no wait state, so comparing data would not see a DTACK that ignores ready. sim/mem reaches 20. So the
    // protocol itself is checked: in a ROM zone, no DTACK before the data is ready.
    always @(posedge clk48)
        if (nRESET && !nAS && !(nROMOE & nPORTOE & nSROMOE) && !nDTACK && !READY) fail("DTACK low in a ROM zone before PROM_DATA_READY");

    // Clocks of MEM_INIT the memory controllers really saw: a relock with stopped clocks gives none
    int mem_init_clks = 0;
    always @(posedge clk96) if (!dut.pll_locked) mem_init_clks++;

    // Mux: request to data ready, CLK_96M
    bit sd_d = 0;
    int rdy_cnt = -1;
    wire rom_sig = ~&{nSROMOE, nROMOE, nPORTOE};
    always @(posedge clk96) begin
        sd_d <= rom_sig;
        if (dut.neogeo.SDRAM_MUX.req_68k) begin
            automatic logic [1:0] own = dut.neogeo.SDRAM_MUX.c0_owner;
            if (!dut.neogeo.SDRAM_MUX.c0_req || dut.neogeo.SDRAM_MUX.c0_ack) c_arrive = A_IDLE;
            else c_arrive = own == dut.neogeo.SDRAM_MUX.C0_FIX ? A_FIX : own == dut.neogeo.SDRAM_MUX.C0_M1 ? A_Z80 :
                            own == dut.neogeo.SDRAM_MUX.C0_LOADER ? A_LOADER : A_68K;
        end
        if (rom_sig && !sd_d) rdy_cnt <= 0;
        else if (rdy_cnt >= 0) begin
            rdy_cnt <= rdy_cnt + 1;
            if (READY) begin
                automatic cycle_t k = !nSROMOE ? C_BIOS : !nROMOE ? C_P1 : C_P2;
                if (rdy_cnt < st[k].rdy_min) st[k].rdy_min = rdy_cnt;
                if (rdy_cnt > st[k].rdy_max) st[k].rdy_max = rdy_cnt;
                c_rdy = rdy_cnt;
                rdy_cnt <= -1;
            end
        end
    end

    // ---- The picture, from the APF pins ----
    logic [23:0] fb [0:255][0:327];
    int   px = 0, py = 0, line_w = 0, frames = 0, last_lines = 0, last_w = 0;
    bit   de_d = 0;
    longint frame_nonblack = 0;
    int   slot_seen = -1;

    always @(posedge video_clk) begin
        de_d <= video_de;
        if (video_de) begin
            if (px < 328 && py < 256) fb[py][px] = video_rgb;
            if (video_rgb != 0) frame_nonblack++;
            px <= px + 1;
        end
        if (de_d && !video_de) begin
            line_w <= px;
            px <= 0;
            py <= py + 1;
            slot_seen <= video_rgb[15:13];
        end
        if (video_vs) begin
            last_lines = py;
            last_w = line_w;
            frames++;
            py <= 0;
            px <= 0;
        end
        if (video_skip) fail("video_skip is high");
    end

    function automatic logic [23:0] colour(input logic [15:0] w);
        logic [6:0] r6 = {1'b0, w[11:8], w[14], w[11]} - 7'(w[15]);
        logic [6:0] g6 = {1'b0, w[7:4],  w[13], w[7]}  - 7'(w[15]);
        logic [6:0] b6 = {1'b0, w[3:0],  w[12], w[3]}  - 7'(w[15]);
        logic [7:0] r8 = r6[6] ? 8'd0 : {r6[5:0], r6[4:3]};
        logic [7:0] g8 = g6[6] ? 8'd0 : {g6[5:0], g6[4:3]};
        logic [7:0] b8 = b6[6] ? 8'd0 : {b6[5:0], b6[4:3]};
        return {r8, g8, b8};
    endfunction

    function automatic logic [23:0] pal1(input int i);
        return i == 0 ? 24'd0 : colour(16'((i << 8) | ((15 - i) << 4) | 5));
    endfunction

    function automatic logic [23:0] pal2(input int i);
        return i == 0 ? 24'd0 : colour(16'((i << 4) | (15 - i) | 'h300));
    endfunction

    // Pixels wrong in the expected places. xoff is 8 less in 304 mode
    function automatic int picture_errors(input bit cart_fix, input int xoff, input bit show);
        int bad = 0, shown = 0;
        int x0 = FIX_COL * 8 + xoff, y0 = (FIX_ROW - 2) * 8;
        for (int y = 0; y < 8; y++)
            for (int x = 0; x < 16; x++) begin
                automatic int k = x & 7;
                automatic logic [23:0] want = pal1(cart_fix ? 8 - k : 1 + k);
                if (fb[y0 + y][x0 + x] != want) begin
                    bad++;
                    if (show && shown < 4) $display("  fix (%0d,%0d) is %06x, expected %06x", x0 + x, y0 + y, fb[y0 + y][x0 + x], want);
                    if (show) shown++;     // not in the condition: Verilator 5.048 refuses ++ inside &&
                end
            end
        x0 = SPR_X + xoff;
        y0 = SPR_Y;
        for (int y = 0; y < 16; y++)
            for (int x = 0; x < 16; x++) begin
                automatic logic [23:0] want = pal2(y == 0 ? 1 : (x + 1) & 15);
                if (fb[y0 + y][x0 + x] != want) begin
                    bad++;
                    if (show && shown < 8) $display("  sprite (%0d,%0d) is %06x, expected %06x", x0 + x, y0 + y, fb[y0 + y][x0 + x], want);
                    if (show) shown++;     // not in the condition: Verilator 5.048 refuses ++ inside &&
                end
            end
        return bad;
    endfunction

    function automatic void bbox();
        int xa = 999, xb = -1, ya = 999, yb = -1;
        for (int y = 0; y < 224; y++)
            for (int x = 0; x < 320; x++)
                if (fb[y][x] != 0) begin
                    if (x < xa) xa = x;
                    if (x > xb) xb = x;
                    if (y < ya) ya = y;
                    if (y > yb) yb = y;
                end
        $display("  picture: non-black from (%0d,%0d) to (%0d,%0d), frame %0d, %0d lines of %0d", xa, ya, xb, yb, frames, last_lines, last_w);
    endfunction

    // ---- The I2S pin: any bits at all ----
    int   dac_ones = 0, snd_peak = 0;
    logic mclk_d = 0;
    always @(posedge clk48) begin
        automatic int v = $signed(dut.snd_left);
        if (v < 0) v = -v;
        if (v > snd_peak) snd_peak = v;
    end
    always @(posedge clk74) begin
        mclk_d <= audio_mclk;
        if (audio_mclk && !mclk_d && audio_dac) dac_ones++;
    end

    // ---- ADPCM-A reads through the mux ----
    int   adpcma_acks = 0;
    logic ack_d = 0;
    logic [7:0] adpcma_last = 0;
    always @(posedge clk96) begin
        ack_d <= dut.neogeo.ADPCMA_READ_ACK;
        if (ack_d != dut.neogeo.ADPCMA_READ_ACK && nRESET) begin
            adpcma_acks++;
            adpcma_last = dut.neogeo.ADPCMA_DOUT;
        end
    end

    // ---- Host ----
    task automatic host_cmd(input logic [15:0] cmd, input logic [31:0] p0 = 0, input logic [31:0] p1 = 0, input logic [31:0] p2 = 0);
        bfm.write32(32'hF800_0020, p0);
        bfm.write32(32'hF800_0024, p1);
        bfm.write32(32'hF800_0028, p2);
        bfm.write32(32'hF800_0000, {16'h434D, cmd});
        wait (dut.icb.hstate == 0);
    endtask

    task automatic load_all();
        int f = $fopen("loads.hex", "r");
        logic [31:0] a, d;
        int n = 0;
        if (f == 0) $fatal(1, "no loads.hex");
        while ($fscanf(f, "%h %h", a, d) == 2) begin
            bfm.write32(a, d);
            n++;
        end
        $fclose(f);
        $display("loaded %0d bridge words", n);
    endtask

    // ---- Waits ----
    // A core that never leaves reset ends the run at once
    task automatic wait_release(input real ms);
        realtime limit = $realtime + ms * 1e6;
        while (!nRESET) begin
            @(posedge clk74);
            if ($realtime > limit) begin
                report();
                $fatal(1, "%s: the core did not leave reset in %0.0f ms", test, ms);
            end
        end
        @(posedge clk48);
        @(posedge clk48);
    endtask

    task automatic wait_frames(input int n);
        int goal = frames + n;
        while (frames < goal) @(posedge video_clk);
    endtask

    task automatic wait_mbox(input logic [15:0] v, input real ms);
        realtime limit = $realtime + ms * 1e6;
        while (mbox != v && $realtime < limit) begin
            @(posedge clk74);
            if (mbox[15:8] == 8'hE0) break;
        end
        check(mbox == v, $sformatf("program stopped at %04x, waiting for %04x; first fetches %06x %06x", mbox, v, {first_addr[0], 1'b0}, {first_addr[1], 1'b0}));
    endtask

    task automatic wait_vbl(input int n, input real ms);
        realtime limit = $realtime + ms * 1e6;
        while (vbl_count < n && $realtime < limit) @(posedge clk74);
        check(vbl_count >= n, $sformatf("VBlank count stayed at %0d, wanted %0d", vbl_count, n));
    endtask

    // Everything that must hold with a game running, after any reset
    task automatic game_runs(input bit cart_fix_last, input string when);
        int bad;
        wait_mbox(16'h0006, 40.0);
        wait_vbl(5, 200.0);
        wait_frames(2);
        bad = picture_errors(cart_fix_last, 0, 1);
        if (bad != 0) bbox();
        check(bad == 0, $sformatf("%s: %0d wrong pixels in the picture", when, bad));
        check(last_lines == 224 && last_w == 320, $sformatf("%s: frame is %0d lines of %0d", when, last_lines, last_w));
        check(dut.fifo_err == 0, {when, ": video FIFO error"});
        check(dut.dl_overflow == 0, {when, ": dl_overflow"});
        check(mem_c0.error_count == 0 && mem_c1.error_count == 0 && mem_s.error_count == 0 && mem_sd.error_count == 0,
              {when, ": chip model errors"});
    endtask

    typedef struct packed { logic [26:0] c, v1, v2, m, p2; } masks_t;
    function automatic masks_t get_masks();
        return '{c: dut.neogeo.CROM_MASK, v1: dut.neogeo.V1ROM_MASK, v2: dut.neogeo.V2ROM_MASK,
                 m: dut.neogeo.MROM_MASK, p2: dut.neogeo.P2ROM_MASK};
    endfunction

    masks_t masks;

    function automatic void check_masks(input string when);
        masks_t now = get_masks();
        check(now == masks, $sformatf("%s: masks C %x V1 %x V2 %x M %x P2 %x, expected C %x V1 %x V2 %x M %x P2 %x", when,
              now.c, now.v1, now.v2, now.m, now.p2, masks.c, masks.v1, masks.v2, masks.m, masks.p2));
    endfunction

    // ---- Tests ----
    task automatic test_power_up();
        test = "test_power_up";
        wait (dut.status_setup_done);
        check(dut.pll.locked && !dut.pll.reconfiguring, "setup done with the PLL not settled");
        check(dut.pll.relocks == 1, $sformatf("%0d relocks by setup done: the reset value of mvs must reconfigure once", dut.pll.relocks));
        host_cmd(16'h0010);
        bfm.write32(32'hF000_020C, 32'd4);      // 320 wide, as the menu restores it
        load_all();
        host_cmd(16'h008F);
        host_cmd(16'h0090, 32'd0, 32'h2026_1101, 32'h0312_3456);
        host_cmd(16'h0011);
        wait_release(300.0);
        check(releases == 1, $sformatf("%0d releases of reset", releases));
        wait_mbox(16'h0001, 10.0);
        check(first_n >= 4 && first_sys[0] && first_addr[0] == 0 && first_addr[1] == 1,
              $sformatf("the first fetches are not the vectors from the BIOS: %06x %06x", {first_addr[0], 1'b0}, {first_addr[1], 1'b0}));
        wait_mbox(16'h0006, 40.0);
        check(mbox_log.size() == 6, $sformatf("%0d progress writes, 6 expected", mbox_log.size()));
        check(dut.neogeo.Z80CPU.cpu.nmi_count == 1, "the Z80 did not take exactly one NMI");
        $display("power up: %0d words of the program's progress at t=%0.1f ms", mbox_log.size(), $realtime / 1e6);
    endtask

    task automatic test_masks();
        test = "test_masks";
        masks = '{c: 27'h1FF, v1: 27'h1FF, v2: 27'h0, m: 27'h1FF, p2: 27'h1FFFFF};
        check_masks("after the load");
        check(dut.prom1_conflict == 0, "prom1_conflict");
    endtask

    task automatic test_picture();
        int bad;
        test = "test_picture";
        wait_vbl(2, 100.0);
        wait_frames(2);
        bad = picture_errors(0, 0, 1);
        if (bad != 0) bbox();
        check(bad == 0, $sformatf("%0d wrong pixels with the fix from SFIX", bad));
        wait_vbl(5, 100.0);
        wait_frames(2);
        bad = picture_errors(1, 0, 1);
        if (bad != 0) bbox();
        check(bad == 0, $sformatf("%0d wrong pixels with the fix from S ROM", bad));
        check(last_lines == 224 && last_w == 320, $sformatf("frame is %0d lines of %0d", last_lines, last_w));
    endtask

    task automatic test_sound();
        test = "test_sound";
        check(adpcma_acks > 0, "no ADPCM-A read came back from CRAM1");
        check(adpcma_last == 8'h07, $sformatf("ADPCM-A read gave %02x, the V ROM holds 07", adpcma_last));
        check(!(dut.neogeo.adpcm_en === 1'b0), "jt10 is held by an ADPCM read that never ended");
        check(snd_peak != 0, $sformatf("jt10 output stayed at zero; ADPCM-A address %x", dut.neogeo.ADPCMA_ADDR_LATCH));
        check(dac_ones != 0, "the I2S data pin stayed low");
        $display("sound: %0d ADPCM-A reads, peak %0d, %0d ones on the I2S pin", adpcma_acks, snd_peak, dac_ones);
    endtask

    task automatic test_inputs();
        test = "test_inputs";
        key1 = 32'h0000_0010;   // face A
        wait_frames(1);
        check((p1_copy[15:8] & 8'h10) == 0, $sformatf("P1 pressed A, the program read %02x", p1_copy[15:8]));
        key1 = 32'd0;
        wait_frames(1);
        check((p1_copy[15:8] & 8'h10) != 0, $sformatf("P1 released, the program read %02x", p1_copy[15:8]));
    endtask

    task automatic test_reset_core();
        int rel = releases;
        test = "test_reset_core";
        mbox = 0;
        vbl_count = 0;
        bfm.write32(32'hF000_0100, 32'd1);
        while (nRESET) @(posedge clk74);
        wait_release(300.0);
        check(releases == rel + 1, "no release after Reset Core");
        check_masks("Reset Core");
        game_runs(1, "Reset Core");
        check_masks("game running after Reset Core");
    endtask

    task automatic relock(input bit to_mvs, input string when);
        int rel = releases;
        int n = dut.pll.relocks;
        mbox = 0;
        vbl_count = 0;
        bfm.write32(32'hF000_0108, 32'(to_mvs));
        wait (dut.pll.relocks == n + 1);
        while (nRESET) @(posedge clk74);
        wait_release(300.0);
        check(releases == rel + 1, {when, ": no release after the relock"});
        check(setup_rises == 1, {when, $sformatf(": setup done rose %0d times, each one tells the host ready to run", setup_rises)});
        check_masks(when);
        game_runs(1, when);
        check_masks({when, ", game running"});
    endtask

    task automatic test_relock();
        int init;
        test = "test_relock";
        init = mem_init_clks;
        relock(0, "MVS to AES");
        check(!dut.neogeo.SYSTEM_MVS, "not in AES mode");
        check(mem_init_clks > init, "the memories never saw MEM_INIT in the relock with running clocks");
        $display("relock: %0d clocks of MEM_INIT, the ROMs came through", mem_init_clks - init);
        relock(1, "AES to MVS");
        check(dut.neogeo.SYSTEM_MVS, "not in MVS mode");
    endtask

    task automatic test_saves();
        logic [31:0] data [$];
        test = "test_saves";
        bfm.write32(32'h6000_0000, 32'h1122_3344);
        bfm.write32(32'h6000_0004, 32'h5566_7788);
        bfm.read_file(32'h6000_0000, 2, data);
        check(data[0] == 32'h1122_3344 && data[1] == 32'h5566_7788, $sformatf("memory card read back %08x %08x", data[0], data[1]));
        bfm.write32(32'h7000_0000, 32'hA1B2_C3D4);
        bfm.read_file(32'h7000_0000, 1, data);
        check(data[0] == 32'hA1B2_C3D4, $sformatf("backup read back %08x", data[0]));
        // In the RAM the 68K's card port reads, not only somewhere the bridge can read back
        check(dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[0] == 8'h11 &&
              dut.neogeo.MEMCARD.MEMCARDU.altsyncram_component.mem[0] == 8'h22,
              $sformatf("card RAM word 0 holds %02x %02x", dut.neogeo.MEMCARD.MEMCARDU.altsyncram_component.mem[0],
                        dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[0]));
    endtask

`ifdef NEOGEO_WAIT_COUNTER
    // rtl/test/wait_counter.sv against this bench's own count, the same way the file reaches the SD card

    // The bench's arrival classes in the counter's code: 0 loader, 1 idle (a 68K read still running counts
    // as idle there, and the table shows if one ever happens), 2 fix, 3 Z80
    function automatic longint bench_reads(input int code);
        return code == 0 ? ar[A_LOADER].n : code == 1 ? ar[A_IDLE].n + ar[A_68K].n : code == 2 ? ar[A_FIX].n : ar[A_Z80].n;
    endfunction

    function automatic longint bench_lost(input int code);
        return code == 0 ? ar[A_LOADER].lost : code == 1 ? ar[A_IDLE].lost + ar[A_68K].lost : code == 2 ? ar[A_FIX].lost : ar[A_Z80].lost;
    endfunction

    function automatic longint file64(input logic [31:0] w[$], input int i);
        return longint'({w[i], w[i + 1]});
    endfunction

    // Words read, as the host would put them in the file
    function automatic void check_file(input logic [31:0] w[$], input longint total, input longint rd[4], input longint ls[4],
                                       input string how);
        check(w.size() == 64, $sformatf("%s: %0d words", how, w.size()));
        check(w[0] == 32'h4E47_5754, $sformatf("%s: magic %08x", how, w[0]));
        check(w[1][31:24] == dut.neogeo.SDRAM_MUX.RD_WAIT, $sformatf("%s: RD_WAIT %0d", how, w[1][31:24]));
        check(w[2] == w[22] && w[2] != 0, $sformatf("%s: frames %0d and %0d", how, w[2], w[22]));
        for (int i = 32; i < 64; i++) check(w[i] == (32'h5A00_0000 | i), $sformatf("%s: word %0d is %08x", how, i, w[i]));
        // The copy runs for 23 clocks after the tick, with a bus cycle maybe open
        check(file64(w, 4) >= total && file64(w, 4) - total <= 32, $sformatf("%s: total %0d, the bench had %0d", how, file64(w, 4), total));
        for (int c = 0; c < 4; c++) begin
            check(file64(w, 6 + 2 * c) >= rd[c] && file64(w, 6 + 2 * c) - rd[c] <= 3, $sformatf("%s: reads of code %0d: %0d, the bench had %0d", how, c, file64(w, 6 + 2 * c), rd[c]));
            check(file64(w, 14 + 2 * c) >= ls[c] && file64(w, 14 + 2 * c) - ls[c] <= 12, $sformatf("%s: lost of code %0d: %0d, the bench had %0d", how, c, file64(w, 14 + 2 * c), ls[c]));
        end
    endfunction

    // bridge_rd_data answers with the word of the read before: read twice
    task automatic target_reg(input logic [7:0] a, output logic [31:0] v);
        bfm.read32(32'hF800_1000 | a, v);
        bfm.read32(32'hF800_1000 | a, v);
    endtask

    task automatic test_wait_counter();
        logic [31:0] w [$], v;
        longint total, rd [4], ls [4];
        automatic int saves;
        test = "test_wait_counter";
        if ($test$plusargs("nowaittest")) return;   // the run to compare against one without the counter

        // The sums themselves: exact, on a clock with no cycle open
        do @(negedge clk48); while (!nAS || in_cycle || !nRESET);
        check(dut.wait_ctr.total == clk68k, $sformatf("total %0d, the bench counted %0d", dut.wait_ctr.total, clk68k));
        for (int c = 0; c < 4; c++) begin
            check(dut.wait_ctr.reads[c] == bench_reads(c), $sformatf("reads of code %0d: %0d, the bench counted %0d", c, dut.wait_ctr.reads[c], bench_reads(c)));
            check(dut.wait_ctr.lost[c] == bench_lost(c), $sformatf("lost of code %0d: %0d, the bench counted %0d", c, dut.wait_ctr.lost[c], bench_lost(c)));
        end
        check(rom_lost() != 0, "no lost clocks: this check saw nothing");

        // The file on exit: the copy of the last tick through the bridge
        @(posedge dut.core_vblank);
        total = clk68k;
        for (int c = 0; c < 4; c++) begin
            rd[c] = bench_reads(c);
            ls[c] = bench_lost(c);
        end
        repeat (30) @(posedge clk48);
        bfm.read_file(32'h8000_0000, 64, w);
        check_file(w, total, rd, ls, "file on exit");
        check(w[3] == dut.wait_ctr.worst, $sformatf("worst frame %0d in the file, %0d in the counter", w[3], dut.wait_ctr.worst));
        begin
            automatic int fd = $fopen("wait.sav", "wb");
            foreach (w[i]) $fwrite(fd, "%c%c%c%c", w[i][31:24], w[i][23:16], w[i][15:8], w[i][7:0]);
            $fclose(fd);
        end

        // The slot write: the command core_bridge_cmd puts in its target registers, answered as the host does
        saves = dut.wait_ctr.saves;
        dut.wait_ctr.timer = 29'h0FFF_FFF0;
        forever begin
            target_reg(8'h00, v);
            if (v == 32'h636D_0184) break;
            // Ready to run has waited for an answer since setup done, and the slot write waits behind it
            if (v == 32'h636D_0140) bfm.write32(32'hF800_1000, 32'h6F6B_0000);
        end
        target_reg(8'h20, v);
        check(v == 32'h103, $sformatf("slot write of slot %x", v));
        target_reg(8'h24, v);
        check(v == 0, $sformatf("slot write at offset %x", v));
        target_reg(8'h28, v);
        check(v == 32'h8000_0000, $sformatf("slot write from bridge address %x", v));
        target_reg(8'h2C, v);
        check(v == 256, $sformatf("slot write of %0d bytes", v));
        bfm.write32(32'hF800_1000, 32'h6275_0000);
        @(posedge dut.core_vblank);
        total = clk68k;
        for (int c = 0; c < 4; c++) begin
            rd[c] = bench_reads(c);
            ls[c] = bench_lost(c);
        end
        repeat (30) @(posedge clk48);
        bfm.read_file(32'h8000_0000, 64, w);
        bfm.write32(32'hF800_1000, 32'h6F6B_0000);
        check_file(w, total, rd, ls, "slot write");
        repeat (8) @(posedge clk74);
        check(dut.wait_ctr.saves == saves + 1 && dut.wait_ctr.last_err == 0,
              $sformatf("%0d saves, %0d expected, error %0d", dut.wait_ctr.saves, saves + 1, dut.wait_ctr.last_err));
        $display("wait counter: total %0d, frames %0d, worst frame %0d lost clocks, agrees with the bench", dut.wait_ctr.total, dut.wait_ctr.frames, dut.wait_ctr.worst);
    endtask
`endif

    function automatic longint rom_reads();
        longint n = 0;
        foreach (ar[i]) n += ar[i].n;
        return n;
    endfunction

    function automatic longint rom_waited();
        longint n = 0;
        foreach (ar[i]) n += ar[i].waited;
        return n;
    endfunction

    function automatic longint rom_lost();
        longint n = 0;
        foreach (ar[i]) n += ar[i].lost;
        return n;
    endfunction

    function automatic real lost_pct();
        return clk68k == 0 ? 0.0 : 100.0 * real'(rom_lost()) / real'(clk68k);
    endfunction

    function automatic void wait_report();
        $display("68K ROM zone reads: %0d, with a wait state %0d (%0.2f%%), lost %0d CLK_48M of %0d: %0.3f%% of all 68K clocks",
                 rom_reads(), rom_waited(), 100.0 * real'(rom_waited()) / real'(rom_reads() == 0 ? 1 : rom_reads()),
                 rom_lost(), clk68k, lost_pct());
        $display("  CRAM0 at arrival     reads   waited  of those   lost   no wait rdy  wait rdy (request to ready, CLK_96M)");
        for (int a = 0; a < A_N; a++) if (ar[a].n != 0)
            $display("  %-15s %10d %8d %8.2f%% %7d    %2d..%2d       %2d..%2d", aname[a], ar[a].n, ar[a].waited,
                     100.0 * real'(ar[a].waited) / real'(ar[a].n), ar[a].lost,
                     ar[a].rdy_ok_min, ar[a].rdy_ok_max, ar[a].rdy_wait_min, ar[a].rdy_wait_max);
    endfunction

    task automatic test_wait_budget();
        test = "test_wait_budget";
        check(rom_reads() != 0, "no ROM zone reads");
        check(lost_pct() <= WAIT_LOST_LIMIT_PCT, $sformatf("68K lost %0.3f%% of its clocks to ROM reads, limit %0.1f%%", lost_pct(), WAIT_LOST_LIMIT_PCT));
        check(ar[A_IDLE].waited == 0, $sformatf("%0d reads waited with CRAM0 idle", ar[A_IDLE].waited));
        check(ar[A_68K].n == 0, $sformatf("%0d 68K requests found an earlier 68K read still running", ar[A_68K].n));
    endtask

    function automatic void report();
        $display("68K bus, CLK_48M clocks unless stated. len: nAS low. ds: strobes low. dt: strobe fall to DTACK. latch: strobe fall to the last latch. stable: data unchanged before it. rdy: strobe to PROM_DATA_READY, CLK_96M");
        for (int k = 0; k < C_N; k++) if (st[k].n != 0) begin
            $display("  %-15s n=%0d len %0d..%0d avg %0.2f, ds %0d..%0d, as-ds %0d, dt %0d..%0d, latch %0d..%0d, stable %0d, rdy %0d..%0d",
                     cname[k], st[k].n, st[k].len_min, st[k].len_max, real'(st[k].len_sum) / real'(st[k].n),
                     st[k].ds_min, st[k].ds_max, st[k].as_ds_max, st[k].dt_min, st[k].dt_max,
                     st[k].latch_min, st[k].latch_max, st[k].stable_min, st[k].rdy_min, st[k].rdy_max);
        end
        $display("  Z80: %0d opcodes, %0d NMIs. sim time %0.1f ms", dut.neogeo.Z80CPU.cpu.opcode_count, dut.neogeo.Z80CPU.cpu.nmi_count, $realtime / 1e6);
        wait_report();
    endfunction

    // +stop=NAME ends the run after that test, for mutation runs: a whole run takes over 12 minutes
    string stop_after = "";
    initial void'($value$plusargs("stop=%s", stop_after));

    task automatic run(input string name);
        tests++;
        case (name)
            "test_power_up":   test_power_up();
            "test_masks":      test_masks();
            "test_picture":    if (!quick) test_picture();
            "test_sound":      if (!quick) test_sound();
            "test_inputs":     if (!quick) test_inputs();
            "test_reset_core": test_reset_core();
            "test_relock":     test_relock();
            "test_saves":      test_saves();
            "test_wait_budget": test_wait_budget();
`ifdef NEOGEO_WAIT_COUNTER
            "test_wait_counter": test_wait_counter();
`endif
            default: $fatal(1, "no test %s", name);
        endcase
        $display("%0s done at %0.1f ms, %0d failures so far", name, $realtime / 1e6, errors);
        $fflush();
        if (name == stop_after) begin
            report();
            if (errors != 0) $fatal(1, "%0d failures", errors);
            $finish;
        end
    endtask

    initial begin
        run("test_power_up");
`ifdef NEOGEO_WAIT_COUNTER
        run("test_wait_counter");   // early, so that +stop makes a short mutation run
`endif
        run("test_masks");
        run("test_picture");
        run("test_wait_budget");    // early too, so that +stop makes a short mutation run
        run("test_sound");
        run("test_inputs");
        run("test_reset_core");
        run("test_relock");
        run("test_saves");
        run("test_wait_budget");
`ifdef NEOGEO_WAIT_COUNTER
        run("test_wait_counter");
`endif
        report();
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("top: %0d tests passed", tests);
        $finish;
    end

    // Run the binary by hand with +progress to watch it: sim.py shows nothing until the end
    initial if ($test$plusargs("progress")) forever begin
        #(2.0e6);
        $display("t=%0.1f ms nRESET %b busy %b reset %b mbox %04x vbl %0d frames %0d A %06x nAS %b DS %b%b RW %b SROM %b DTACK %b rdy %b c0req %b own %0d pend %b FC %b%b%b cyc %0d",
                 $realtime / 1e6, nRESET, dut.neogeo.sram_busy, dut.apf_core_reset, mbox, vbl_count, frames, {CPU_A, 1'b0},
                 nAS, nUDS, nLDS, RW, nSROMOE, nDTACK, READY, dut.neogeo.SDRAM_MUX.c0_req, dut.neogeo.SDRAM_MUX.c0_owner,
                 dut.neogeo.SDRAM_MUX.m68k_pend, dut.neogeo.FC2, dut.neogeo.FC1, dut.neogeo.FC0, first_n);
        $fflush();
    end

    initial begin
        #(2.0e9);
        report();
        $fatal(1, "timeout");
    end
endmodule
