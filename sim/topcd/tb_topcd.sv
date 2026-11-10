// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// sim/top for the CD build: core_top with cd_sys and the real fx68k, against the models of the chips. The
// program is make_test_roms.py --cd, which needs no Neo Geo ROM or BIOS, and the host is host_bfm at its real rate
// and latency, with prepare.py's two discs of tools/make_test_disc.py. The first boot has no disc.
//
// test_cdd_tick    cdd_tick's poll intervals, on a clock of its own
// test_bios_short_holds_reset  a 4 KB BIOS: the core stays in reset. Runs first: a load that completes ends it
// test_power_up    the full BIOS, vectors from CRAM0 0xA00000, the program's steps 1 to 12
// test_picture     the fix tile on the APF video pins: what the program uploaded, as nothing else loads it
// test_dma_pcm     a DMA from PROG RAM into the PCM window: CRAM1 holds the source's bytes
// test_fix_uploads the FIX bytes the program uploads, by the 68K and by DMA: both strobes, and both land
// test_z80_from_ram the Z80's program uploaded to the block RAM, running from it, the handshake
// test_68k_cost    what PROG RAM in CRAM0 costs the 68K, per class, against Task 4's thresholds
// test_wait_counter (with NEOGEO_WAIT_COUNTER) the debug counter against this bench, and its save file: the commands the
//                  program really sent, oldest to newest, the 68K's samples, the fetch's and the DMA's counts
// test_saves_8k    the 8 KB card: its ends through the bridge and the 68K's port, plugged whatever the setting says
// test_mix_extremes the mix at the ends of its range, on the core's port and the I2S pins, each channel its own
// test_mount_on_boot the disc's slot in the table at a load: disc_present soon after dataslot_allcomplete, the TOC
// test_play_dma_to_prog program steps 13 and 14: sector 16 by PLAY and DMA in the PSRAM, a printed DMA word period, CDDA.
//                  The program waits for HEAD to read 00:02:16 mode 1: a file_lba or pregap slip stops it at 12
// test_read_after_dma_end the program's first read after a DMA is the last word the DMA wrote
// test_cdda_tone_on_i2s TRACK_PLAY 02 on the I2S pins: the disc's sine, halved, nearly the whole track, no slip
// test_cdda_underrun_is_silence_not_hang 60 ms of host latency: silence between sectors, the program runs, the tone resumes
// test_disc_swap_during_cdda a disc picked with a sector in the stream, then with one held at the sink: not streamed
// test_late_host_delays_but_delivers 20 ms of host latency: the same result, later
// test_disc_swap_invalidates_bank another disc picked with a data read under way, its size a table sweep after the request
// test_reset_core  Reset Core: the program runs again from the BIOS, with PROG RAM as it left it, the disc still in
// test_cd_settings CD/CDZ, Region and the lid as FF011C reads them, CD/CDZ taken only in reset and a change restarting the core; a held reset reads
//                  as STOP at LBA 0 in the drive's debug view, with the last status and command kept
//
// All along: every read on the 68K bus latches what the memory holds, a CD read never finds its word
// still in the CD write queue, each class of cycle is measured, no fix read goes to CRAM0 or past FIX_DEADLINE,
// and the drive asks for a sector only when the sink of that kind of sector has room.
`timescale 1ns/1ps
module tb_topcd;
    localparam real PERIOD_74 = 13.468;
    localparam int  HOLD = 2000;            // clk_74a clocks of apf_core_reset, shortened for the bench

    // Numbers of tools/make_test_roms.py
    localparam logic [23:1] MBOX_W = 23'h087F80, VBL_W = 23'h087F82;
    localparam int FIX_COL = 5, FIX_ROW = 10;
    localparam logic [15:0] DMA_PCM_WORDS [2] = '{16'hA1B2, 16'hC3D4};
    localparam int DMA_PCM_AT = 'h180;      // PCM RAM's byte address, bank 0, of its window's E00300
    localparam int FIX_DEADLINE = 23;       // sim/mem's: CLK_96M from PCK2's fall, so that neo_b1 samples it
    localparam logic [15:0] LAST_STEP = 16'd12;
    localparam logic [7:0] CARD_LAST = 8'h5A;
    localparam int FIX_CPU_BYTES = 32, FIX_DMA_BYTES = 32;      // the program's uploads, one write each
    localparam logic [22:0] PLAY_REQ_W = 23'h087FA2, SECTOR_WORDS_W = 23'h087FA3;
    localparam logic [22:0] DMA_TO_W = 23'h090000;              // 0x120000, the program's DMA of a sector, 1,024 words
    localparam logic [22:0] CARD_SAVE_W = 23'h087FA4;
    localparam logic [22:0] SYS_CONFIG_W = 23'h087FA8;          // 0x10FF50

    // tools/make_test_disc.py's sine, amplitude 16384, after the mix's halving: -12 dB. 48 I2S frames a period
    localparam int TONE_PEAK = 8192, I2S_KHZ = 48, TONE_PERIOD = 48;
    localparam int TRACK_FRAMES = 6400;     // 10 sectors of 588 at 44.1 kHz, in frames of 48 kHz
    localparam int HOST_LATE_60MS = 4_455_000;

    // The discs of prepare.py, in tools/make_test_disc.py's layout: data 0-31, INDEX 00 at 32 and 44, INDEX 01 at 34 and 46
    localparam string DISC_DIR = "/Assets/ngcd/common/disc/", OTHER_DIR = "/Assets/ngcd/common/other 'disc', 2/";
    localparam string OTHER_BIN = "Test Disc 'X', 1.bin";
    localparam logic [15:0] WORDS_16 = 16'h0010, OTHER_WORDS_16 = 16'hA510;     // sector 16's data words on each
    localparam int DISC_TRACKS = 3, DISC_END = 56;
    localparam real MOUNT_MS = 40.0;        // about 23 host commands of 1 ms each and the data, sim/cue's 25.7 ms
    localparam real SWAP_MS = 100.0;        // and the fetches ahead of it, one still at the late host's 20 ms
    localparam int  HOST_LATENCY = 74250;   // host_bfm's 1 ms

    // nAS low for a bus cycle with no wait state, CLK_48M, measured with the real fx68k. Another bus cycle
    // has another base: test_68k_cost fails if this one stops being the floor
    parameter int  ZERO_WAIT_LEN = 10;

    // Task 4's gate, in the units of this bench's table
    parameter real MAX_PROG_RD_LEN_AVG = 14.0;
    parameter int  MAX_PROG_RDY = 20;
    parameter real MAX_PROG_WR_LEN_AVG = 14.0;
    parameter int  MAX_PROG_WR_LEN = 20;
    parameter real MAX_LOST_PCT = 25.0;

    logic clk74 = 0;
    always #(PERIOD_74 / 2) clk74 = ~clk74;

    // ---- DUT and chips ----
    wire [31:0] bridge_addr, bridge_wr_data, bridge_rd_data;
    wire        bridge_wr, bridge_rd;

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

    host_bfm host (.clk(clk74), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
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
        .cont1_key(32'd0), .cont2_key(32'd0), .cont3_key(32'd0), .cont4_key(32'd0),
        .cont1_joy(32'd0), .cont2_joy(32'd0), .cont3_joy(32'd0), .cont4_joy(32'd0),
        .cont1_trig(16'd0), .cont2_trig(16'd0), .cont3_trig(16'd0), .cont4_trig(16'd0)
    );

    sdram_model mem_sd (
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_dq(dram_dq)
    );
    // As sim/top: the poll is what makes a whole core run in minutes, and SIM_DEFINES runs other configurations
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
    wire        nWWL = dut.neogeo.nWWL, nWWU = dut.neogeo.nWWU;
    wire        nROMOE = dut.neogeo.nROMOE, nSROMOE = dut.neogeo.nSROMOE;
    wire        CD_EXT_RD = dut.neogeo.CD_EXT_RD, CD_EXT_WR = dut.neogeo.CD_EXT_WR;
    wire        nDTACK = dut.neogeo.nDTACK_ADJ, READY = dut.neogeo.PROM_DATA_READY;
    wire        PHI2 = dut.neogeo.CLK_EN_68K_N;
    wire        LATCH = (dut.neogeo.M68KCPU.FX68K.excUnit.dataIo.xToIrc | dut.neogeo.M68KCPU.FX68K.excUnit.dataIo.xToDbin) & PHI2;

    int errors = 0, tests = 0, program_runs = 1;
    string test = "";

    // For mutation runs. +failfast stops at the first failure, +quick skips the 300 ms of the short BIOS
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

    // ---- The watchdog's 8 frames of reset, as sim/top ----
    bit nrst_d = 0;
    bit fast_first = $test$plusargs("fastwd");
    always @(posedge clk48) begin
        nrst_d <= dut.neogeo.nRESET_CORE;
        if (dut.neogeo.nRESET_CORE && !nrst_d && (releases != 0 || fast_first)) dut.neogeo.B1.WD.WDCNT = 4'hF;
    end

    // ---- Reset ----
    int  releases = 0;
    bit  nreset_d = 0;
    always @(posedge clk48) begin
        nreset_d <= nRESET;
        if (nRESET && !nreset_d) releases++;
    end

    // ---- BIOS words the loader emitted ----
    int bios_words = 0, bios_past_short = 0;
    bit ioctl_wr_d = 0;
    always @(posedge clk48) begin
        ioctl_wr_d <= dut.ioctl_wr;
        if (dut.ioctl_wr && !ioctl_wr_d && dut.ioctl_idx == 0) begin
            bios_words++;
            if (dut.ioctl_addr >= 27'h1000) bios_past_short++;
        end
    end

    // ---- The disc's path ----
    wire        disc_present_s = dut.neogeo.disc_present_s;
    wire        CDDA_WR = dut.neogeo.CDDA_WR;
    int         cdda_edges = 0, toc_writes = 0;
    bit         cdda_d = 0, dl_d = 0, swap_on = 0, swap_tray = 0, swap_stop = 0;

    always @(posedge clk48) begin
        cdda_d <= CDDA_WR;
        dl_d <= dut.neogeo.cd_dl_download;
        if (CDDA_WR && !cdda_d) cdda_edges++;
        if (dut.neogeo.cd_dl_download && !dl_d && !disc_present_s) fail("a sector stream began with no disc: the bank is cd_mount's");
        if (swap_on) begin
            if (dut.neogeo.dbg_cur_status == 4'hE) swap_tray = 1;
            if (dut.neogeo.dbg_cur_status == 4'h0 && swap_tray) swap_stop = 1;
            if (dut.neogeo.dbg_cur_status == 4'hB) fail("the drive reported no disc during a swap");
        end
    end

    // The drive asks for a sector only when that kind of sector's sink has room: what it sampled is a clock old here.
    // cdda_held: a tick that the audio sink's ready alone held back, as cd_fetch would hold a sector asked for anyway
    bit req_v_d = 0, rdy_data_d = 0, rdy_cdda_d = 0;
    int cdda_held = 0;
    always @(posedge clk48) begin
        req_v_d <= dut.neogeo.req_valid;
        rdy_data_d <= dut.neogeo.CD_DATA_WR_READY;
        rdy_cdda_d <= dut.neogeo.CDDA_WR_READY;
        if (nRESET && nreset_d && dut.neogeo.req_valid != req_v_d && !(dut.neogeo.req_audio ? rdy_cdda_d : rdy_data_d))
            fail($sformatf("the drive asked for a sector at %0d, audio %b, with no room for it", dut.neogeo.req_lba, dut.neogeo.req_audio));
        if (dut.neogeo.CDD_DRIVE.state == dut.neogeo.CDD_DRIVE.S_PLAY_B && dut.neogeo.req_audio && !dut.neogeo.CDDA_WR_READY) cdda_held++;
    end

    // ---- The I2S pins, as sim/audio's decoder: MCLK from the pin, each bit by its distance from the LRCK edge ----
    bit          i2s_on = 0, i2s_lrck_d = 0, i2s_have_l = 0;
    int          i2s_cnt = 1000, i2s_first = -1;    // i2s_first: the first frame in the queue that is not silence
    logic [15:0] i2s_sh = 0, i2s_l = 0, i2s_r = 0;
    logic [31:0] i2s_q [$];

    always @(negedge audio_mclk) begin
        i2s_lrck_d <= audio_lrck;
        i2s_cnt = audio_lrck != i2s_lrck_d ? 0 : i2s_cnt + 1;
        if (i2s_cnt >= 5 && i2s_cnt <= 65 && i2s_cnt % 4 == 1) begin
            i2s_sh = {i2s_sh[14:0], audio_dac};
            if (i2s_cnt == 65) begin
                if (!audio_lrck) begin
                    i2s_l = i2s_sh;
                    i2s_have_l = 1;
                end
                else if (i2s_have_l) begin
                    i2s_r = i2s_sh;
                    i2s_have_l = 0;
                    if (i2s_on) begin
                        if (i2s_first < 0 && {i2s_l, i2s_r} != 0) i2s_first = i2s_q.size();
                        i2s_q.push_back({i2s_l, i2s_r});
                    end
                end
            end
        end
    end

    task automatic i2s_start();
        i2s_q.delete();
        i2s_first = -1;
        i2s_on = 1;
    endtask

    // The TOC is rewritten only with the disc down, on both sides of the crossing
    always @(posedge clk74) if (dut.cdmount.toc_we) begin
        toc_writes++;
        // The last entry goes in as disc_present rises at clk_74a, ahead of this view of it by the crossing
        if (disc_present_s || (dut.neogeo.disc_present && dut.neogeo.disc_loading)) fail("the TOC is written with disc_present high");
    end

    // When the last PLAY went to the drive
    realtime t_play_cmd = 0;
    always @(posedge clk48) if (dut.neogeo.CDD_COMMAND_SEND && dut.neogeo.CDD_COMMAND_DATA[3:0] == 4'd3) t_play_cmd = $realtime;

    // FIX writes, by what made them. A DMA's word period, PROG RAM's writes in a run of them
    int     fix_cpu_n = 0, fix_dma_n = 0, dma_gap_min = 9999, dma_gap_max = 0, dma_gaps = 0;
    longint dma_gap_sum = 0, clk48_n = 0, dma_last = -1;
    bit     fix_wr_d = 0, dma_wr_d2 = 0;

    always @(posedge clk48) begin
        clk48_n++;
        fix_wr_d <= dut.neogeo.CD_TR_WR_FIX;
        dma_wr_d2 <= dut.neogeo.DMA_WR_OUT;
        if (dut.neogeo.CD_TR_WR_FIX && !fix_wr_d) begin
            if (dut.neogeo.DMA_RUNNING) fix_dma_n++;
            else fix_cpu_n++;
        end
        if (!dut.neogeo.DMA_RUNNING) dma_last = -1;
        else if (dut.neogeo.DMA_WR_OUT && !dma_wr_d2 && CD_EXT_WR) begin
            if (dma_last >= 0) begin
                automatic int gap = int'(clk48_n - dma_last);
                dma_gaps++;
                dma_gap_sum += gap;
                if (gap < dma_gap_min) dma_gap_min = gap;
                if (gap > dma_gap_max) dma_gap_max = gap;
            end
            dma_last = clk48_n;
        end
    end

    // ---- The 68K bus, one record per cycle ----
    // len: nAS low, CLK_48M. rdy: strobe fall to PROM_DATA_READY, CLK_96M.
    // lost is len - ZERO_WAIT_LEN. Each wait state adds 4.
    typedef enum int { C_BIOS, C_PROG_R, C_PROG_W, C_FIX_W, C_OTHER_R, C_OTHER_W, C_N } cycle_t;
    string cname [C_N] = '{"BIOS read", "PROG RAM read", "PROG RAM write", "FIX write", "other read", "other write"};

    typedef struct {
        longint n, len_sum, lost;
        int len_min, len_max;
        int rdy_min, rdy_max;
    } stat_t;
    stat_t st [C_N];

    initial foreach (st[i]) begin
        st[i].n = 0; st[i].len_sum = 0; st[i].lost = 0;
        st[i].len_min = 9999; st[i].len_max = 0; st[i].rdy_min = 9999; st[i].rdy_max = 0;
    end

    bit    in_cycle = 0;
    int    c_len = 0, c_latch = -1;
    bit    c_ds_seen = 0;
    cycle_t c_class = C_OTHER_R;
    logic [15:0] c_data = 0;
    logic [23:1] c_addr = 0;
    logic [22:0] c_word = 0;
    bit    c_rl = 0, c_ru = 0, wr_seen = 0;
    // First fetches
    logic [23:1] first_addr [8];
    logic [22:0] first_word [8];
    bit          first_bios [8];
    int          first_n = 0;

    // Progress of the program
    logic [15:0] mbox = 0, mbox_log [$];
    // The first PROG RAM read after a DMA ends
    bit          after_dma = 0, adma_seen = 0;
    logic [23:1] adma_addr = 0;
    logic [15:0] adma_data = 0;
    bit          dma_running_d3 = 0;
    logic [15:0] vbl_count = 0;

    // The gate's phase: the program's step 8, from its write of 7 to its write of 8
    bit     ph_on = 0, ph_done = 0;
    longint ph_clk = 0, ph_lost = 0;
    longint ph_fix = 0, all_fix = 0;        // fix reads, in the SRAM: the 68K is alone on CRAM0, as this Z80 has its own RAM
    int     fix_lat = 0, fix_lat_max = 0;   // CLK_96M edges from PCK2's fall to the one that updates SROM_DATA

    always @(posedge clk96) begin
        if (dut.neogeo.SDRAM_MUX.req_fix) begin
            all_fix++;
            if (ph_on) ph_fix++;
            fix_lat <= 1;
        end
        else if (fix_lat != 0) fix_lat <= fix_lat + 1;
        if (dut.neogeo.SDRAM_MUX.fx_done && dut.neogeo.SDRAM_MUX.fx_owner == dut.neogeo.SDRAM_MUX.FX_VIDEO && fix_lat != 0) begin
            if (fix_lat + 1 > fix_lat_max) fix_lat_max = fix_lat + 1;
            check(fix_lat + 1 <= FIX_DEADLINE, $sformatf("fix read took %0d clocks of CLK_96M", fix_lat + 1));
            fix_lat <= 0;
        end
        if (dut.neogeo.SDRAM_MUX.c0_req && dut.neogeo.SDRAM_MUX.c0_owner == dut.neogeo.SDRAM_MUX.C0_FIX) fail("a fix read on CRAM0");
    end

    // ---- What the gate counts: the BIOS and PROG RAM, counted by this bench's rules ----
    // The holds of FIX, SPR and PCM transfers are not in it. For rtl/test/wait_counter.sv's check, as sim/top's arrival classes. Arrival is what CRAM0 was doing when the
    // last 68K read request reached the mux, in the counter's code: 0 CD write queue, 1 idle, 2 fix, 3 Z80. A write
    // or a transfer makes no such request and keeps the code of the one before. In this build the only owners are
    // 0 and 1: the fix is in the SRAM and the Z80 has its own RAM
    longint clk68k = 0;                 // CLK_48M with the 68K out of reset
    longint mux_n [4], mux_lost [4];
    int     c_arrive = 1;
    bit     c_mux = 0, c_tas = 0;       // c_tas: a read-modify-write, two bus cycles in one nAS, 34 clocks on PROG RAM
    int     tas_n = 0;

    initial foreach (mux_n[i]) begin mux_n[i] = 0; mux_lost[i] = 0; end

    always @(posedge clk48) if (nRESET) clk68k++;

    wire mux_zone = !nSROMOE || !nROMOE || !dut.neogeo.nPORTOE || CD_EXT_RD || CD_EXT_WR;

    always @(posedge clk96) if (dut.neogeo.SDRAM_MUX.req_68k) begin
        automatic logic [1:0] own = dut.neogeo.SDRAM_MUX.c0_owner;
        if (!dut.neogeo.SDRAM_MUX.c0_req || dut.neogeo.SDRAM_MUX.c0_ack) c_arrive = 1;
        else c_arrive = own == dut.neogeo.SDRAM_MUX.C0_LOADER ? 0 : own == dut.neogeo.SDRAM_MUX.C0_FIX ? 2 :
                        own == dut.neogeo.SDRAM_MUX.C0_M1 ? 3 : 1;
    end

    // What the upload put on the bus for FIX RAM
    logic [7:0] fix_upload [32];
    int         fix_upload_n = 0;

    function automatic cycle_t classify();
        if (!RW) return CD_EXT_WR ? C_PROG_W : dut.neogeo.CD_TR_WR_FIX ? C_FIX_W : C_OTHER_W;
        if (!nSROMOE) return C_BIOS;
        // The low half of PROG RAM reads through nROMOE, as MiSTer
        if (CD_EXT_RD || !nROMOE) return C_PROG_R;
        return C_OTHER_R;
    endfunction

    wire ds_low = ~(nLDS & nUDS);

    always @(posedge clk48) begin
        if (ph_on) ph_clk++;
        dma_running_d3 <= dut.neogeo.DMA_RUNNING;
        if (dma_running_d3 && !dut.neogeo.DMA_RUNNING) begin
            after_dma <= 1;
            adma_seen <= 0;
        end
        if (!nRESET) begin
            in_cycle <= 0;
        end else if (!nAS && !in_cycle) begin
            in_cycle <= 1;
            c_len <= 1; c_latch <= -1; c_ds_seen <= 0;
            c_addr <= CPU_A;
            c_mux <= mux_zone;
            c_tas <= 0;
        end else if (in_cycle) begin
            c_len <= c_len + 1;
            c_mux <= c_mux | mux_zone;
            if (ds_low && !c_ds_seen) begin
                c_ds_seen <= 1;
                c_class <= classify();
                if (!RW && dut.neogeo.CD_TR_WR_FIX && fix_upload_n < 32) begin
                    fix_upload[CPU_A[5:1]] <= CPU_OUT[7:0];
                    fix_upload_n <= fix_upload_n + 1;
                end
            end
            // A read-modify-write, the 68K's TAS: its write ends in the one nAS. No read to compare at its
            // end, and not the cycle the write class measures
            if (ds_low && !RW && c_ds_seen && c_class == C_PROG_R) begin
                c_class <= C_OTHER_W;
                c_tas <= 1;
            end
            if (LATCH && c_ds_seen) begin
                c_latch  <= 1;
                c_data   <= CPU_IN;
                c_word   <= dut.neogeo.SDRAM_MUX.m68k_word;
                {c_rl, c_ru} <= {~nLDS, ~nUDS};
            end
            if (nAS) begin
                in_cycle <= 0;
                if (c_mux) begin
                    mux_n[c_arrive]++;
                    if (c_tas) tas_n++;
                    mux_lost[c_arrive] += c_len > ZERO_WAIT_LEN ? c_len - ZERO_WAIT_LEN : 0;
                end
                if (c_ds_seen) begin
                    automatic cycle_t k = c_class;
                    automatic int lost = c_len - ZERO_WAIT_LEN;
                    st[k].n++;
                    st[k].len_sum += c_len;
                    st[k].lost += lost;
                    if (c_len < st[k].len_min) st[k].len_min = c_len;
                    if (c_len > st[k].len_max) st[k].len_max = c_len;
                    if (ph_on) ph_lost += lost;
                    if (k == C_PROG_R && after_dma && !adma_seen && c_latch >= 0) begin
                        adma_seen <= 1;
                        adma_addr <= c_addr;
                        adma_data <= c_data;
                    end
                    // What the CPU took is what the PSRAM holds. A stale read fails here too
                    if ((k == C_BIOS || k == C_PROG_R) && c_latch >= 0) begin
                        automatic logic [15:0] want = mem_c0.mem.exists(c_word) ? mem_c0.mem[c_word] : 16'h0000;
                        if ((c_rl && c_data[7:0] != want[7:0]) || (c_ru && c_data[15:8] != want[15:8]))
                            fail($sformatf("%s at %06x latched %04x, the PSRAM holds %04x", cname[k], {c_addr, 1'b0}, c_data, want));
                    end
                    if (first_n < 8) begin
                        first_addr[first_n] = c_addr;
                        first_word[first_n] = c_word;
                        first_bios[first_n] = k == C_BIOS;
                        first_n++;
                    end
                end
            end
        end

        // Program's own results, on the falling edge of a write strobe to PROG RAM's work area
        if (nRESET && (!nWWL || !nWWU) && !wr_seen) begin
            wr_seen = 1;
            if (CPU_A == MBOX_W) begin
                mbox = CPU_OUT;
                mbox_log.push_back(CPU_OUT);
                if (CPU_OUT == 16'd7 && !ph_done) ph_on = 1;
                if (CPU_OUT == 16'd8 && ph_on) begin ph_on = 0; ph_done = 1; end
            end
            if (CPU_A == VBL_W) vbl_count = CPU_OUT;
        end
        if (nWWL && nWWU) wr_seen = 0;
    end

    // A read is ready 20 CLK_96M after the strobe at worst, so comparing data would not see a DTACK that
    // ignores ready: as sim/top, the protocol itself is checked.
    always @(posedge clk48)
        if (nRESET && !nAS && (!nROMOE || !nSROMOE || CD_EXT_RD) && !nDTACK && !READY) fail("DTACK low in a read zone before PROM_DATA_READY");

    // Mux: request to data ready, CLK_96M
    bit sd_d = 0;
    int rdy_cnt = -1;
    wire rd_sig = !nROMOE || !nSROMOE || CD_EXT_RD;
    always @(posedge clk96) begin
        sd_d <= rd_sig;
        if (rd_sig && !sd_d) rdy_cnt <= 0;
        else if (rdy_cnt >= 0) begin
            rdy_cnt <= rdy_cnt + 1;
            if (READY) begin
                automatic cycle_t k = !nSROMOE ? C_BIOS : C_PROG_R;
                if (rdy_cnt < st[k].rdy_min) st[k].rdy_min = rdy_cnt;
                if (rdy_cnt > st[k].rdy_max) st[k].rdy_max = rdy_cnt;
                rdy_cnt <= -1;
            end
        end
    end

    // ---- Stale read monitor ----
    // A CD read ranks above the CD write queue, so a read of a word still queued gets the old data: only
    // timing keeps that from happening, here with real instruction timing. A write's time runs from its
    // CD_EXT_WR edge to the clock the queue head starts on the chip.
    longint wq_clk = 0;
    longint wq_edge[$];
    int     wr_to_head_max = 0, wr_edges = 0;
    int     wr_to_rd_min = 9999;            // write edge to the next 68K read edge, on one word or not
    longint last_wr = -1;

    always @(posedge clk96) begin
        wq_clk++;
        if (dut.neogeo.SDRAM_MUX.cd_wr_edge && !dut.neogeo.SDRAM_MUX.cd_wq_full && dut.neogeo.SDRAM_MUX.cd_wr_chip == dut.neogeo.SDRAM_MUX.CHIP_C0) begin
            wq_edge.push_back(wq_clk);
            last_wr = wq_clk;
            wr_edges++;
        end
        if (dut.neogeo.SDRAM_MUX.req_68k && last_wr >= 0) begin
            if (wq_clk - last_wr < wr_to_rd_min) wr_to_rd_min = int'(wq_clk - last_wr);
            last_wr = -1;
        end
        if ((!dut.neogeo.SDRAM_MUX.c0_req || dut.neogeo.SDRAM_MUX.c0_ack) && !dut.neogeo.SDRAM_MUX.dl_c0) begin
            if (dut.neogeo.SDRAM_MUX.want_68k) begin
                for (int p = dut.neogeo.SDRAM_MUX.cd_wq_rp; p != int'(dut.neogeo.SDRAM_MUX.cd_wq_wp);
                     p = (p + 1) & (2 * (1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1))
                    if (dut.neogeo.SDRAM_MUX.cd_wq[p & ((1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1)][44:43] == dut.neogeo.SDRAM_MUX.CHIP_C0 &&
                        dut.neogeo.SDRAM_MUX.cd_wq[p & ((1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1)][40:18] == dut.neogeo.SDRAM_MUX.m68k_word)
                        fail($sformatf("stale read: word %06x granted while it is still queued", {dut.neogeo.SDRAM_MUX.m68k_word, 1'b0}));
            end
            else if (!dut.neogeo.SDRAM_MUX.want_fix && dut.neogeo.SDRAM_MUX.cd_wq_c0) begin
                automatic longint age = wq_clk - wq_edge.pop_front();
                if (age > wr_to_head_max) wr_to_head_max = int'(age);
            end
        end
        if (!nRESET) wq_edge.delete();
    end

    // The same on the SDRAM, for a SPR read and a SPR write still queued
    longint sd_edge[$];
    int     spr_to_head_max = 0, spr_writes = 0, spr_to_rd_min = 9999;
    longint last_spr = -1;

    always @(posedge clk96) begin
        if (dut.neogeo.SDRAM_MUX.cd_wr_edge && !dut.neogeo.SDRAM_MUX.cd_wq_full && dut.neogeo.SDRAM_MUX.cd_wr_chip == dut.neogeo.SDRAM_MUX.CHIP_SD) begin
            sd_edge.push_back(wq_clk);
            last_spr = wq_clk;
            spr_writes++;
        end
        if (dut.neogeo.SDRAM_MUX.req_tr_rd && dut.neogeo.SDRAM_MUX.tr_spr_sig && last_spr >= 0) begin
            if (wq_clk - last_spr < spr_to_rd_min) spr_to_rd_min = int'(wq_clk - last_spr);
            last_spr = -1;
        end
        if (dut.neogeo.SDRAM_MUX.sd_ready && !dut.neogeo.SDRAM_MUX.sd_rd && !dut.neogeo.SDRAM_MUX.sd_wr &&
            !(dut.neogeo.SDRAM_MUX.crom_pend | dut.neogeo.SDRAM_MUX.req_crom)) begin
            if (dut.neogeo.SDRAM_MUX.tr_spr_pend) begin
                for (int p = dut.neogeo.SDRAM_MUX.cd_wq_rp; p != int'(dut.neogeo.SDRAM_MUX.cd_wq_wp);
                     p = (p + 1) & (2 * (1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1))
                    if (dut.neogeo.SDRAM_MUX.cd_wq[p & ((1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1)][44:43] == dut.neogeo.SDRAM_MUX.CHIP_SD &&
                        dut.neogeo.SDRAM_MUX.cd_wq[p & ((1 << dut.neogeo.SDRAM_MUX.CD_WQ_AW) - 1)][42:18] == dut.neogeo.SDRAM_MUX.cd_spr_word)
                        fail($sformatf("stale SPR read: word %07x granted while it is still queued", dut.neogeo.SDRAM_MUX.cd_spr_word));
            end
            else if (!dut.neogeo.SDRAM_MUX.dl_sd && dut.neogeo.SDRAM_MUX.cd_wq_sd) begin
                automatic longint age = wq_clk - sd_edge.pop_front();
                if (age > spr_to_head_max) spr_to_head_max = int'(age);
            end
        end
        if (!nRESET) sd_edge.delete();
    end

    // ---- CDDA read enable ----
    longint cdda_n = 0, cdda_clk = 0;
    always @(posedge clk48) if (nRESET) begin
        cdda_clk++;
        if (dut.neogeo.CDDA_CLK) cdda_n++;
    end

    // ---- The picture, from the APF pins ----
    logic [23:0] fb [0:255][0:327];
    int   px = 0, py = 0, line_w = 0, frames = 0, last_lines = 0, last_w = 0;
    bit   de_d = 0;

    always @(posedge video_clk) begin
        de_d <= video_de;
        if (video_de) begin
            if (px < 328 && py < 256) fb[py][px] = video_rgb;
            px <= px + 1;
        end
        if (de_d && !video_de) begin
            line_w <= px;
            px <= 0;
            py <= py + 1;
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

    function automatic int picture_errors(input bit show);
        int bad = 0, shown = 0;
        int x0 = FIX_COL * 8, y0 = (FIX_ROW - 2) * 8;
        for (int y = 0; y < 8; y++)
            for (int x = 0; x < 16; x++) begin
                automatic logic [23:0] want = pal1(1 + (x & 7));
                if (fb[y0 + y][x0 + x] != want) begin
                    bad++;
                    if (show && shown < 4) $display("  fix (%0d,%0d) is %06x, expected %06x", x0 + x, y0 + y, fb[y0 + y][x0 + x], want);
                    if (show) shown++;     // not in the condition: Verilator 5.048 refuses ++ inside &&
                end
            end
        return bad;
    endfunction

    // ---- Host ----
    task automatic host_cmd(input logic [15:0] cmd, input logic [31:0] p0 = 0, input logic [31:0] p1 = 0, input logic [31:0] p2 = 0);
        host.bfm.write32(32'hF800_0020, p0);
        host.bfm.write32(32'hF800_0024, p1);
        host.bfm.write32(32'hF800_0028, p2);
        host.bfm.write32(32'hF800_0000, {16'h434D, cmd});
        wait (dut.icb.hstate == 0);
    endtask

    // The file with short set is a BIOS of 4 KB
    task automatic load_all(input bit short);
        int f = $fopen("loads.hex", "r");
        logic [31:0] a, d;
        int n = 0;
        if (f == 0) $fatal(1, "no loads.hex");
        while ($fscanf(f, "%h %h", a, d) == 2)
            if (!short || a < 32'h10A0_1000 || a >= 32'h10B0_0000) begin
                host.bfm.write32(a, d);
                n++;
            end
        $fclose(f);
        $display("loaded %0d bridge words", n);
    endtask

    task automatic host_load(input bit short);
        host_cmd(16'h0010);
        host.bfm.write32(32'hF000_020C, 32'd4);      // 320 wide, as the menu restores it
        load_all(short);
        host_cmd(16'h008F);
        host_cmd(16'h0090, 32'd0, 32'h2026_1101, 32'h0312_3456);
        host_cmd(16'h0011);
    endtask

    // ---- Waits ----
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

    function automatic void check_clean(input string when);
        check(dut.fifo_err == 0, {when, ": video FIFO error"});
        check(dut.dl_overflow == 0, {when, ": dl_overflow"});
        check(mem_c0.error_count == 0 && mem_c1.error_count == 0 && mem_s.error_count == 0 && mem_sd.error_count == 0,
              {when, ": chip model errors"});
    endfunction

    // ---- Tests ----

    // Scaled to 1 MHz: the counts are all there is. A clock of its own, stepped only here
    logic tk_clk = 0, tk_rst_n = 0, tk_fast = 0;
    logic [1:0] tk_speed = 0;
    wire tk_tick;
    cdd_tick #(.CLK_HZ(1_000_000)) tick_dut (.clk(tk_clk), .nRESET(tk_rst_n), .speed(tk_speed), .fast(tk_fast), .tick(tk_tick));

    task automatic tk_step();
        #1 tk_clk = 1;
        #1 tk_clk = 0;
    endtask

    task automatic test_cdd_tick();
        int want [5] = '{10000, 10000, 5000, 4000, 2000};   // not fast, then fast at speeds 0 to 3
        test = "test_cdd_tick";
        foreach (want[i]) begin
            int n = 0;
            tk_fast = i != 0;
            tk_speed = i == 0 ? 2'd3 : 2'(i - 1);
            tk_rst_n = 0;
            repeat (2) tk_step();
            tk_rst_n = 1;
            while (!tk_tick && n < 20000) begin tk_step(); n++; end
            n = 0;
            do begin tk_step(); n++; end while (!tk_tick && n < 20000);
            check(n == want[i], $sformatf("fast %b speed %0d: a tick per %0d clocks, expected %0d", tk_fast, tk_speed, n, want[i]));
        end
    endtask

    task automatic test_bios_short_holds_reset();
        realtime t0;
        test = "test_bios_short_holds_reset";
        wait (dut.status_setup_done);
        host_load(1);
        t0 = $realtime;
        while ($realtime - t0 < 300.0e6) @(posedge clk74);
        check(bios_words != 0, "no BIOS word reached the core");
        check(bios_past_short == 0, $sformatf("%0d BIOS words past 0x1000", bios_past_short));
        check(!nRESET && releases == 0, $sformatf("the core left reset on a short BIOS, %0d releases", releases));
        $display("short BIOS: %0d words emitted, in reset after %0.0f ms", bios_words, ($realtime - t0) / 1e6);
    endtask

    task automatic test_power_up();
        test = "test_power_up";
        wait (dut.status_setup_done);
        check(dut.pll.locked && !dut.pll.reconfiguring, "setup done with the PLL not settled");
        host_load(0);
        check(dut.neogeo.SYSTEM_CDx, "SYSTEM_CDx is low");
        wait_release(300.0);
        check(releases == 1, $sformatf("%0d releases of reset", releases));
        wait_mbox(16'h0001, 10.0);
        check(first_n >= 4 && first_bios[0] && first_addr[0] == 0 && first_addr[1] == 1,
              $sformatf("the first fetches are not the vectors from the BIOS: %06x %06x", {first_addr[0], 1'b0}, {first_addr[1], 1'b0}));
        check(first_word[0] == 23'h500000 && first_word[1] == 23'h500001,
              $sformatf("the vectors came from CRAM0 %06x %06x, not 0xA00000", {first_word[0], 1'b0}, {first_word[1], 1'b0}));
        wait_mbox(LAST_STEP, 200.0);
        check(mbox_log.size() == int'(LAST_STEP), $sformatf("%0d progress writes, %0d expected", mbox_log.size(), LAST_STEP));
        foreach (mbox_log[i]) check(mbox_log[i] == 16'(i + 1), $sformatf("progress write %0d is %04x", i, mbox_log[i]));
        check(fix_upload_n == 32, $sformatf("%0d writes reached FIX RAM's window, 32 expected", fix_upload_n));
        // 48,335,658 / 44,100 is 1096.05 clocks. Enough of them have gone by here
        check(cdda_n > 10 && cdda_clk / cdda_n == 1096, $sformatf("CDDA read enable: %0d in %0d clocks", cdda_n, cdda_clk));
        check_clean("power up");
        $display("power up: %0d words of the program's progress at t=%0.1f ms", mbox_log.size(), $realtime / 1e6);
    endtask

    task automatic test_picture();
        int bad;
        test = "test_picture";
        // Bytes of fix_rom: each row of a tile, four bytes at 0x10, 0x18, 0x00 and 0x08, low nibble on the left
        foreach (fix_upload[i]) begin
            automatic logic [7:0] want = i < 8 ? 8'h65 : i < 16 ? 8'h87 : i < 24 ? 8'h21 : 8'h43;
            check(fix_upload[i] == want, $sformatf("FIX byte %0d on the bus is %02x, expected %02x", i, fix_upload[i], want));
        end
        wait_vbl(2, 100.0);
        wait_frames(2);
        bad = picture_errors(1);
        check(bad == 0, $sformatf("%0d wrong pixels of the fix tile", bad));
        check(last_lines == 224 && last_w == 320, $sformatf("frame is %0d lines of %0d", last_lines, last_w));
    endtask

    int dma_runs = 0, dma_wrs = 0;
    bit dma_running_d = 0, dma_wr_d = 0;
    always @(posedge clk48) begin
        dma_running_d <= dut.neogeo.DMA_RUNNING;
        dma_wr_d <= dut.neogeo.CD_TR_WR_PCM;
        if (dut.neogeo.DMA_RUNNING && !dma_running_d) dma_runs++;
        if (dut.neogeo.DMA_RUNNING && dut.neogeo.CD_TR_WR_PCM && !dma_wr_d) dma_wrs++;
    end

    task automatic test_dma_pcm();
        test = "test_dma_pcm";
        check(dma_runs == 2 && dma_wrs == 4, $sformatf("%0d DMAs with %0d PCM writes, the FIX upload's and one with 4 expected", dma_runs, dma_wrs));
        // A byte copy takes each word's high byte first
        for (int i = 0; i < 4; i++) begin
            automatic int k = DMA_PCM_AT + i;
            automatic logic [15:0] w = mem_c1.mem.exists(23'(k >> 1)) ? mem_c1.mem[23'(k >> 1)] : 16'hDEAD;
            automatic logic [7:0] got = k & 1 ? w[15:8] : w[7:0];
            automatic logic [7:0] want = i & 1 ? DMA_PCM_WORDS[i / 2][7:0] : DMA_PCM_WORDS[i / 2][15:8];
            check(got == want, $sformatf("PCM byte %03x by DMA is %02x, the source's is %02x", k, got, want));
        end
    endtask

    // The program reads each of them back itself, through the 68K's window, and test_picture sees the 68K's on the screen.
    task automatic test_fix_uploads();
        test = "test_fix_uploads";
        check(fix_cpu_n == FIX_CPU_BYTES, $sformatf("%0d FIX writes by the 68K, %0d uploaded", fix_cpu_n, FIX_CPU_BYTES));
        check(fix_dma_n == FIX_DMA_BYTES, $sformatf("%0d FIX writes by DMA, %0d uploaded", fix_dma_n, FIX_DMA_BYTES));
    endtask

    task automatic test_z80_from_ram();
        test = "test_z80_from_ram";
        // LD SP,FFFC at 0, odd addresses in the other RAM
        check(dut.neogeo.WRAML.altsyncram_component.mem[0] == 8'h31 && dut.neogeo.WRAMU.altsyncram_component.mem[0] == 8'hFC,
              $sformatf("Z80 RAM word 0 holds %02x %02x", dut.neogeo.WRAML.altsyncram_component.mem[0], dut.neogeo.WRAMU.altsyncram_component.mem[0]));
        // Its own write to F800, from the program it runs
        check(dut.neogeo.WRAML.altsyncram_component.mem[15'h7C00] == 8'h5A, "the Z80's write to F800 is not in its RAM");
        check(dut.neogeo.Z80CPU.cpu.opcode_count > 10, $sformatf("%0d Z80 opcodes", dut.neogeo.Z80CPU.cpu.opcode_count));
        check(dut.neogeo.Z80CPU.cpu.nmi_count == 1, $sformatf("%0d NMIs, one expected", dut.neogeo.Z80CPU.cpu.nmi_count));
        check(dut.neogeo.z80rd_req == 0, "the Z80 read through the mux");
    endtask

    function automatic real lost_pct(input longint lost);
        return ph_clk == 0 ? 0.0 : 100.0 * real'(lost) / real'(ph_clk);
    endfunction

    task automatic test_68k_cost();
        automatic real avg = real'(st[C_PROG_R].len_sum) / real'(st[C_PROG_R].n == 0 ? 1 : st[C_PROG_R].n);
        automatic real wr_avg = real'(st[C_PROG_W].len_sum) / real'(st[C_PROG_W].n == 0 ? 1 : st[C_PROG_W].n);
        test = "test_68k_cost";
        check(ph_done && ph_clk != 0, "the program's PROG RAM phase was not seen");
        check(ph_fix != 0, "no fix read in the PROG RAM phase: the video must run for its numbers to count");
        check(st[C_PROG_R].n != 0 && st[C_PROG_W].n != 0, "no PROG RAM reads or writes");
        check(st[C_BIOS].len_min == ZERO_WAIT_LEN, $sformatf("the shortest bus cycle is %0d clocks, ZERO_WAIT_LEN is %0d", st[C_BIOS].len_min, ZERO_WAIT_LEN));
        check(wr_avg <= MAX_PROG_WR_LEN_AVG, $sformatf("PROG RAM writes len %0.2f on average, limit %0.2f", wr_avg, MAX_PROG_WR_LEN_AVG));
        check(st[C_PROG_W].len_max <= MAX_PROG_WR_LEN, $sformatf("PROG RAM writes len %0d at worst, limit %0d", st[C_PROG_W].len_max, MAX_PROG_WR_LEN));
        check(avg <= MAX_PROG_RD_LEN_AVG, $sformatf("PROG RAM reads len %0.2f on average, limit %0.2f", avg, MAX_PROG_RD_LEN_AVG));
        check(st[C_PROG_R].rdy_max <= MAX_PROG_RDY, $sformatf("PROG RAM reads rdy %0d at worst, limit %0d", st[C_PROG_R].rdy_max, MAX_PROG_RDY));
        check(lost_pct(ph_lost) <= MAX_LOST_PCT, $sformatf("the PROG phase lost %0.2f%% of its clocks, limit %0.1f%%", lost_pct(ph_lost), MAX_LOST_PCT));
        report();
    endtask

`ifdef NEOGEO_WAIT_COUNTER
    // rtl/test/wait_counter.sv against this bench's own count, the way sim/top does it, and the file as the
    // host would read it. In this build almost every cycle arrives on an idle CRAM0, so the split by code
    // says little; the sums and the lost clocks are what this checks, and the mutations in the report show it

    function automatic longint file64(input logic [31:0] w[$], input int i);
        return longint'({w[i], w[i + 1]});
    endfunction

    // Words 23 to 30, the CD side: counted here by rising edges of the same strobes, held values as they were at the tick
    int      cd_n [6];                  // CDD exchanges, then writes to FIX, SPR, PCM, Z80, then failed sectors
    bit [5:0] cd_seen = 0;
    initial foreach (cd_n[i]) cd_n[i] = 0;
    wire [5:0] cd_now = {dut.neogeo.fetch_err, dut.neogeo.CD_TR_WR_Z80, dut.neogeo.CD_TR_WR_PCM, dut.neogeo.CD_TR_WR_SPR,
                         dut.neogeo.CD_TR_WR_FIX, dut.neogeo.CDD_STATUS_LATCH};
    always @(posedge clk48) begin
        cd_seen <= cd_now;
        for (int i = 0; i < 6; i++) if (cd_now[i] && !cd_seen[i]) cd_n[i]++;
    end

    typedef struct {
        logic [39:0] cmd, st;
        logic [3:0]  cur_status;
        logic [23:0] cur_lba;
        int          n [6];
        int          cmds, dma [4], req [2];
    } cd_tick_t;

    // Layout 3. The commands other than IDLE and TOC as this bench sees them cross, in the ring's entry form
    logic [95:0] cmd_log [$];
    logic [95:0] cmd_e;
    bit cmd_due = 0;
    wire [39:0] cdd_cmd_now = dut.neogeo.CDD_COMMAND_DATA, cdd_st_now = dut.neogeo.CDD_STATUS;
    always @(posedge clk48) begin
        if (!nRESET) cmd_due = 0;
        else if (dut.neogeo.CDD_COMMAND_SEND) begin
            cmd_due = cdd_cmd_now[3:0] != 0 && cdd_cmd_now[3:0] != 4'h2;
            if (cmd_due) cmd_log.push_back({dut.wait_ctr.frames[15:0], cdd_cmd_now[39:32], 8'd0, cdd_cmd_now[31:0], 32'd0});
        end
        else if (dut.neogeo.CDD_STATUS_LATCH && cmd_due) begin
            cmd_due = 0;
            cmd_e = cmd_log[cmd_log.size() - 1];
            cmd_e[71:64] = cdd_st_now[39:32];
            cmd_e[31:0] = cdd_st_now[31:0];
            cmd_log[cmd_log.size() - 1] = cmd_e;
        end
    end

    // DMA words by target, requests by kind, the 68K at each VBlank, the frame of each release: by rising edges of the core's signals
    int dma_n [4], req_n [2], rel_frame = 0, f_cycles = 0;
    bit [3:0] dma_seen = 0;
    bit req_seen = 0, f_wrote = 0, nas_seen = 1, rel_seen = 0;
    logic [31:0] sample_log [$];
    initial begin
        foreach (dma_n[i]) dma_n[i] = 0;
        foreach (req_n[i]) req_n[i] = 0;
    end
    wire [3:0] dma_now = {dut.neogeo.CD_TR_WR_PCM, dut.neogeo.CD_TR_WR_SPR, dut.neogeo.CD_TR_WR_FIX, dut.neogeo.CD_EXT_WR} & {4{dut.neogeo.DMA_RUNNING}};
    always @(posedge clk48) begin
        dma_seen <= dma_now;
        for (int i = 0; i < 4; i++) if (dma_now[i] && !dma_seen[i]) dma_n[i]++;
        req_seen <= dut.neogeo.req_valid;
        if (nRESET && dut.neogeo.req_valid != req_seen && dut.neogeo.req_valid != dut.neogeo.req_done) req_n[dut.neogeo.req_audio]++;
        rel_seen <= nRESET;
        if (nRESET && !rel_seen) rel_frame = dut.wait_ctr.frames;
        nas_seen <= nAS;
        if (dut.wait_ctr.tick) begin
            if (nRESET) sample_log.push_back({f_wrote, 8'(f_cycles >> 8), CPU_A});
            f_cycles = 0;
            f_wrote = 0;
        end
        else begin
            if (nRESET && !nAS && nas_seen) f_cycles++;
            if (!nAS && !RW) f_wrote = 1;
        end
    end

    function automatic cd_tick_t cd_at_tick();
        cd_tick_t t;
        t.cmds = cmd_log.size();
        foreach (t.dma[i]) t.dma[i] = dma_n[i];
        foreach (t.req[i]) t.req[i] = req_n[i];
        t.cmd = dut.neogeo.CDD_COMMAND_DATA;
        t.st = dut.neogeo.CDD_STATUS;
        t.cur_status = dut.neogeo.dbg_cur_status;
        t.cur_lba = dut.neogeo.dbg_cur_lba;
        foreach (t.n[i]) t.n[i] = cd_n[i];
        return t;
    endfunction

    // Where the current run's record of the wait counter's file is on the bridge
    function automatic logic [31:0] run_record();
        return 32'h8000_0000 + 32'(dut.wait_ctr.run_no[2:0]) * 512;
    endfunction

    function automatic void check_cd_words(input logic [31:0] w[$], input cd_tick_t t, input string how);
        check(w[23][7:0] == t.cmd[39:32] && w[24] == t.cmd[31:0], $sformatf("%s: last CDD command %08x %08x, the drive's %010x", how, w[23], w[24], t.cmd));
        check(w[25][7:0] == t.st[39:32] && w[26] == t.st[31:0], $sformatf("%s: last CDD status %08x %08x, the drive's %010x", how, w[25], w[26], t.st));
        check(w[27] == {dut.disc_reason, t.cur_status, t.cur_lba}, $sformatf("%s: drive state word %08x, the drive's %x %0d, mount %0d", how, w[27], t.cur_status, t.cur_lba, dut.disc_reason));
        check(w[30] == dut.disc_bin_size, $sformatf("%s: disc_bin_size %0d in the file, %0d in the loader", how, w[30], dut.disc_bin_size));
        // The counts keep running in the 31 clocks after the tick: a few more are fine, fewer are not
        for (int i = 0; i < 6; i++) begin
            automatic int got = i == 0 ? w[29][15:0] : i == 1 ? w[23][31:8] : i == 2 ? w[25][31:8] : i == 3 ? w[28][31:8] :
                                i == 4 ? w[29][31:16] : w[28][7:0];
            automatic int mask = i == 0 || i == 4 ? 16'hFFFF : i == 5 ? 255 : 24'hFFFFFF;
            check(((got - t.n[i]) & mask) <= 3, $sformatf("%s: count %0d is %0d in the file, the bench had %0d", how, i, got, t.n[i] & mask));
        end
    endfunction

    // Words 32 to 47 and 64 to 104, the file of layout 3. Read with no DMA running and few sectors: small slack on the moving counts
    function automatic void check_layout3(input logic [31:0] w[$], input cd_tick_t t, input string how);
        check(w[33] == {8'(releases), 24'(rel_frame)}, $sformatf("%s: resets word %08x, the bench has %0d at frame %0d", how, w[33], releases, rel_frame));
        check(w[34] == sample_log[sample_log.size() - 1] || (w[34][31] == sample_log[sample_log.size() - 1][31] && w[34][22:0] == sample_log[sample_log.size() - 1][22:0] &&
              8'(w[34][30:23] - sample_log[sample_log.size() - 1][30:23] + 8'd1) <= 8'd2),
              $sformatf("%s: 68K sample %08x, the bench has %08x", how, w[34], sample_log[sample_log.size() - 1]));
        check(w[35][22:0] == sample_log[sample_log.size() - 2][22:0], $sformatf("%s: the sample before %08x, the bench has %08x", how, w[35], sample_log[sample_log.size() - 2]));
        check(w[38] - 32'(t.req[0]) <= 2, $sformatf("%s: %0d data sectors, the bench had %0d", how, w[38], t.req[0]));
        check(w[39] - 32'(t.req[1]) <= 2, $sformatf("%s: %0d audio sectors, the bench had %0d", how, w[39], t.req[1]));
        check((w[28][7:0] != 0) == w[46][31], $sformatf("%s: %0d failed sectors, first failed word %08x", how, w[28][7:0], w[46]));
        check((w[44] != 0) == w[47][31], $sformatf("%s: %0d late polls, first late word %08x", how, w[44], w[47]));
        for (int i = 0; i < 4; i++) begin
            check(w[66 + i] == 32'(t.dma[i]), $sformatf("%s: DMA words of target %0d: %0d, the bench had %0d", how, i, w[66 + i], t.dma[i]));
            check((w[70 + i] != 0) == (t.dma[i] != 0), $sformatf("%s: target %0d: %0d words, worst stall %0d", how, i, w[66 + i], w[70 + i]));
        end
        check(w[75] == 0 && w[76] == 0, $sformatf("%s: a DMA found the queue full %0d times, %0d writes lost: the engine waits on DMA_SDRAM_BUSY", how, w[75], w[76]));
        check(w[78] == 0, $sformatf("%s: %0d DMA writes reached no memory, and the program's all do", how, w[78]));
        check(w[80] == 32'(t.cmds), $sformatf("%s: %0d commands in the file, the bench saw %0d", how, w[80], t.cmds));
        for (int e = 0; e < 8; e++) begin
            automatic logic [95:0] want = e < t.cmds ? cmd_log[t.cmds - 1 - e] : 96'd0;
            check({w[81 + 3 * e], w[82 + 3 * e], w[83 + 3 * e]} == want,
                  $sformatf("%s: ring entry %0d of the newest: %08x %08x %08x, the bench has %024x", how, e, w[81 + 3 * e], w[82 + 3 * e], w[83 + 3 * e], want));
        end
    endfunction

    // A command word of tools/make_test_roms.py's cdd_cmd: nibble 0, the sub-command in nibble 3, the check in nibble 9
    function automatic logic [39:0] cdd_word(input logic [3:0] code, input logic [3:0] sub);
        logic [3:0] sum = 4'd5 + code + sub;
        return {~sum, 20'd0, sub, 8'd0, code};
    endfunction

    function automatic logic [39:0] log_cmd(input int i);
        return {cmd_log[i][79:72], cmd_log[i][63:32]};
    endfunction

    // Words read, as the host would put them in the file
    function automatic void check_file(input logic [31:0] w[$], input longint total, input longint rd[4], input longint ls[4],
                                       input string how);
        check(w.size() == 128, $sformatf("%s: %0d words", how, w.size()));
        check(w[0] == 32'h4E47_5754, $sformatf("%s: magic %08x", how, w[0]));
        check(w[1][31:24] == dut.neogeo.SDRAM_MUX.RD_WAIT, $sformatf("%s: RD_WAIT %0d", how, w[1][31:24]));
        check(w[1][15:0] == 16'd3, $sformatf("%s: layout %0d, the CD core is 3", how, w[1][15:0]));
        check(w[2] == w[22] && w[2] != 0, $sformatf("%s: frames %0d and %0d", how, w[2], w[22]));
        for (int i = 48; i < 64; i++) check(w[i] == (32'h5A00_0000 | i), $sformatf("%s: word %0d is %08x", how, i, w[i]));
        check(w[127] == 32'h5A00_007F, $sformatf("%s: word 127 is %08x", how, w[127]));
        // These sums are in the copy's first 23 clocks after the tick, with a bus cycle maybe open
        check(file64(w, 4) >= total && file64(w, 4) - total <= 32, $sformatf("%s: total %0d, the bench had %0d", how, file64(w, 4), total));
        for (int c = 0; c < 4; c++) begin
            check(file64(w, 6 + 2 * c) >= rd[c] && file64(w, 6 + 2 * c) - rd[c] <= 3, $sformatf("%s: cycles of code %0d: %0d, the bench had %0d", how, c, file64(w, 6 + 2 * c), rd[c]));
            check(file64(w, 14 + 2 * c) >= ls[c] && file64(w, 14 + 2 * c) - ls[c] <= 12, $sformatf("%s: lost of code %0d: %0d, the bench had %0d", how, c, file64(w, 14 + 2 * c), ls[c]));
        end
    endfunction

    int wait_runs = 0;

    task automatic test_wait_counter();
        logic [31:0] w [$];
        longint total, rd [4], ls [4], n_all, lost_all;
        cd_tick_t cdt;
        automatic int saves, logged, at;
        test = "test_wait_counter";

        // The sums themselves: exact, on a clock with no cycle open
        do @(negedge clk48); while (!nAS || in_cycle || !nRESET);
        check(dut.wait_ctr.total == clk68k, $sformatf("total %0d, the bench counted %0d", dut.wait_ctr.total, clk68k));
        n_all = 0;
        lost_all = 0;
        for (int c = 0; c < 4; c++) begin
            check(dut.wait_ctr.reads[c] == mux_n[c], $sformatf("cycles of code %0d: %0d, the bench counted %0d", c, dut.wait_ctr.reads[c], mux_n[c]));
            check(dut.wait_ctr.lost[c] == mux_lost[c], $sformatf("lost of code %0d: %0d, the bench counted %0d", c, dut.wait_ctr.lost[c], mux_lost[c]));
            n_all += mux_n[c];
            lost_all += mux_lost[c];
        end
        // PROG RAM writes are in it, and the cart's three ROM zones alone would miss them. Few cycles lose a clock
        // in this program, so a check that sums to zero would pass for any zone: the BIOS and PROG RAM reads must
        // be there, and the lost clocks are what the next lines mutate
        // A TAS on PROG RAM is two bus cycles in one nAS, 34 clocks: the counter has no way to tell it from a wait, and
        // counts 24 lost clocks for each. The bench class for it is "other write"
        check(tas_n != 0 && n_all == st[C_BIOS].n + st[C_PROG_R].n + st[C_PROG_W].n + tas_n,
              $sformatf("%0d counted cycles, the BIOS, PROG RAM read and write classes have %0d and %0d TAS", n_all, st[C_BIOS].n + st[C_PROG_R].n + st[C_PROG_W].n, tas_n));
        // The CD side: every count exact here, and the program has done each of them by now
        check(dut.wait_ctr.n_exch == 16'(cd_n[0]) && dut.wait_ctr.n_fix == 24'(cd_n[1]) && dut.wait_ctr.n_spr == 24'(cd_n[2]) &&
              dut.wait_ctr.n_pcm == 24'(cd_n[3]) && dut.wait_ctr.n_z80 == 16'(cd_n[4]) && dut.wait_ctr.n_ferr == 8'(cd_n[5]),
              $sformatf("CD counts %0d %0d %0d %0d %0d, the bench counted %0d %0d %0d %0d %0d", dut.wait_ctr.n_exch, dut.wait_ctr.n_fix,
                        dut.wait_ctr.n_spr, dut.wait_ctr.n_pcm, dut.wait_ctr.n_z80, cd_n[0], cd_n[1], cd_n[2], cd_n[3], cd_n[4]));
        check(cd_n[0] != 0 && cd_n[1] >= 32 && cd_n[2] != 0 && cd_n[3] != 0 && cd_n[4] != 0,
              $sformatf("a count of the CD side is zero: %0d %0d %0d %0d %0d", cd_n[0], cd_n[1], cd_n[2], cd_n[3], cd_n[4]));
        // What the program uploaded, by the 68K and by DMA, whole runs of it
        check(dut.wait_ctr.n_fix == 24'(program_runs * (FIX_CPU_BYTES + FIX_DMA_BYTES)),
              $sformatf("the counter has %0d FIX writes, %0d runs of the program made %0d by the 68K and %0d by DMA",
                        dut.wait_ctr.n_fix, program_runs, program_runs * FIX_CPU_BYTES, program_runs * FIX_DMA_BYTES));

        // The file on exit: the copy of the last tick through the bridge
        @(posedge dut.core_vblank);
        cdt = cd_at_tick();
        total = clk68k;
        for (int c = 0; c < 4; c++) begin
            rd[c] = mux_n[c];
            ls[c] = mux_lost[c];
        end
        repeat (140) @(posedge clk48);
        host.bfm.read_file(run_record(), 128, w);
        check(w[105] == dut.wait_ctr.run_no, $sformatf("run %0d in the file, %0d in the counter", w[105], dut.wait_ctr.run_no));
        check_file(w, total, rd, ls, "file on exit");
        check_cd_words(w, cdt, "file on exit");
        check_layout3(w, cdt, "file on exit");
        check(w[32] == settings_word(0, 0, 0, 0, 0), $sformatf("the settings word %08x with all at their defaults, want %08x", w[32], settings_word(0, 0, 0, 0, 0)));
        // What the program really sent, less TOC. tools/make_test_roms.py: on the first boot TRAY CLOSE, with no disc. By
        // the end, its last run with the disc in, after Reset Core: TRAY CLOSE, STOP, PLAY, TRACK PLAY
        if (wait_runs == 0) begin
            check(cdt.cmds == 1 && log_cmd(0) == cdd_word(4'hC, 4'd0),
                  $sformatf("%0d commands on the first boot, want TRAY CLOSE; TOC 4 stays out", cdt.cmds));
            check(w[82] == cdd_word(4'hC, 4'd0)[31:0], $sformatf("the entry is %08x, the program's TRAY CLOSE %08x", w[82], cdd_word(4'hC, 4'd0)[31:0]));
            check(w[81][15:8] == cdd_word(4'hC, 4'd0)[39:32], $sformatf("the entry's check is %02x", w[81][15:8]));
            // An answer is 40 bits, its check nibble in the entry's first word: TRAY CLOSE's STOP is A0_00000000
            check({w[81][7:0], w[83]} != 0, "a command with no answer in the ring");
            check(w[85] == 0, $sformatf("a second entry %08x: TOC took a place in the ring", w[85]));
            check(w[66 + 1] == 32'(FIX_DMA_BYTES), $sformatf("%0d DMA words to FIX, the program's DMA is %0d", w[66 + 1], FIX_DMA_BYTES));
        end
        else begin
            automatic logic [3:0] codes [4] = '{4'hC, 4'h1, 4'h3, 4'hB};
            check(cdt.cmds >= 4, $sformatf("%0d commands", cdt.cmds));
            for (int i = 0; i < 4; i++) check(w[81 + 3 * (3 - i) + 1][3:0] == codes[i], $sformatf("ring entry %0d of the newest is command %x, the program's %x", 3 - i, w[81 + 3 * (3 - i) + 1][3:0], codes[i]));
            // The disc was read, and the bench's slow hosts made sectors late; 60 ms is about 2,900,000 clocks
            check(w[38] != 0 && w[39] != 0 && w[40] != 0 && w[41] != 0, $sformatf("sectors %0d data %0d audio, %0d hits %0d misses", w[38], w[39], w[40], w[41]));
            check(w[42] > 32'd2_800_000, $sformatf("worst host read %0d clocks, the bench had a host of 60 ms", w[42]));
            check(w[44] != 0 && w[47][31], $sformatf("%0d late polls with a host of 60 ms, first late %08x", w[44], w[47]));
            check(w[66] != 0, "no DMA word to PROG, and the program DMAs a sector there");
            // cd.sv's sectors: the program's DMA took one from the cache
            check(w[1][23:19] == 5'd6 && w[108] != 0, $sformatf("revision %0d, %0d sectors DMA'd", w[1][23:19], w[108]));
            $display("sectors: %0d DMA'd, the last offered %08x; %0d BIOS read changes, the newest %08x", w[108], w[109], w[107], w[110]);
            check(w[109] != 0, "no header of a sector offered");
        end
        wait_runs++;
        check(w[3] == dut.wait_ctr.worst, $sformatf("worst frame %0d in the file, %0d in the counter", w[3], dut.wait_ctr.worst));
        begin
            automatic int fd = $fopen("wait.sav", "wb");
            foreach (w[i]) $fwrite(fd, "%c%c%c%c", w[i][31:24], w[i][23:16], w[i][15:8], w[i][7:0]);
            $fclose(fd);
        end

        // The slot write, right after a frame's copy: the host answers it inside the frame, from the file of this tick
        @(posedge dut.core_vblank);
        cdt = cd_at_tick();
        total = clk68k;
        for (int i = 0; i < 4; i++) begin
            rd[i] = mux_n[i];
            ls[i] = mux_lost[i];
        end
        repeat (140) @(posedge clk48);
        saves = dut.wait_ctr.saves;
        logged = host.log_q.size();
        dut.wait_ctr.timer = 29'h0FFF_FFF0;
        begin
            automatic bit found = 0;
            while (!found) begin
                @(posedge clk74);
                while (logged < host.log_q.size()) begin
                    if (host.log_q[logged].cmd == 16'h0184) begin
                        found = 1;
                        at = logged;
                    end
                    logged++;
                end
            end
        end
        check(host.log_q[at].id == 16'h103, $sformatf("slot write of slot %x", host.log_q[at].id));
        check(host.log_q[at].offset == 0, $sformatf("slot write at offset %x", host.log_q[at].offset));
        check(host.log_q[at].addr == 32'h8000_0000, $sformatf("slot write from bridge address %x", host.log_q[at].addr));
        check(host.log_q[at].len == 8192, $sformatf("slot write of %0d bytes", host.log_q[at].len));
        begin
            automatic int first = 128 * int'(dut.wait_ctr.run_no[2:0]);
            w = host.wlog[first:first + 127];
        end
        check_file(w, total, rd, ls, "slot write");
        check_cd_words(w, cdt, "slot write");
        check_layout3(w, cdt, "slot write");
        repeat (3000) @(posedge clk74);
        // The host's load of the file reaches the counter's RAM through core_top.v, and the numbering sees it. The record
        // of the next run: that run overwrites it. The number is not taken now, as this run has started
        begin
            automatic logic [31:0] other [$];
            automatic logic [31:0] addr = 32'h8000_0000 + 32'((int'(dut.wait_ctr.run_no[2:0]) + 1) % 8) * 512;
            automatic logic [31:0] loaded = dut.wait_ctr.run_no + 32'd100;
            host.bfm.write32(addr + 105 * 4, loaded);
            repeat (20) @(posedge clk74);
            host.bfm.read_file(addr, 128, other);
            check(other[105] == loaded, $sformatf("loaded %0d into another record, it reads %0d", loaded, other[105]));
            check(dut.wait_ctr.loaded_run == loaded, $sformatf("loaded %0d, the counter has %0d as the highest", loaded, dut.wait_ctr.loaded_run));
        end
        check(dut.wait_ctr.saves == saves + 1 && dut.wait_ctr.last_err == 0,
              $sformatf("%0d saves, %0d expected, error %0d", dut.wait_ctr.saves, saves + 1, dut.wait_ctr.last_err));
        $display("wait counter: total %0d, frames %0d, worst frame %0d lost clocks, %0d mux cycles, %0d lost: agrees with the bench",
                 dut.wait_ctr.total, dut.wait_ctr.frames, dut.wait_ctr.worst, n_all, lost_all);
    endtask
`endif

    task automatic test_saves_8k();
        logic [31:0] data [$];
        logic [15:0] w0, w1;
        test = "test_saves_8k";
        // The program's own byte, from the 68K's side, in the last word of the card
        check(dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[12'hFFF] == CARD_LAST,
              $sformatf("the 68K wrote %02x at the card's end, it holds %02x", CARD_LAST, dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[12'hFFF]));
        host.bfm.write32(32'h6000_0000, 32'h1122_3344);
        host.bfm.write32(32'h6000_1FFC, 32'hAABB_CCDD);
        host.bfm.read_file(32'h6000_0000, 1, data);
        check(data[0] == 32'h1122_3344, $sformatf("memory card word 0 read back %08x", data[0]));
        host.bfm.read_file(32'h6000_1FFC, 1, data);
        check(data[0] == 32'hAABB_CCDD, $sformatf("memory card's last word read back %08x", data[0]));
        // In the RAM the 68K's card port reads, not only somewhere the bridge can read back
        check(dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[0] == 8'h11 &&
              dut.neogeo.MEMCARD.MEMCARDU.altsyncram_component.mem[0] == 8'h22 &&
              dut.neogeo.MEMCARD.MEMCARDL.altsyncram_component.mem[12'hFFF] == 8'hCC &&
              dut.neogeo.MEMCARD.MEMCARDU.altsyncram_component.mem[12'hFFF] == 8'hDD, "card RAM does not hold the bridge's words");
        // What the 68K reads of them through its port: a byte per word of its zone, CDA[0] picking the RAM
        bus_idle();
        mem_c0.mem[PLAY_REQ_W] = 16'd3;
        wait_mbox(16'd16, 20.0);
        w0 = mem_c0.mem[CARD_SAVE_W];
        w1 = mem_c0.mem[CARD_SAVE_W + 23'd1];
        check({w0, w1} == 32'h2211_DDCC, $sformatf("the 68K read the card's ends as %04x %04x", w0, w1));
        // Plugged, whatever the setting that unplugs the cart's
        check(!dut.neogeo.nCD1 && !dut.neogeo.nCD2, "the card is not plugged");
        host.bfm.write32(32'hF000_010C, 32'd1);
        repeat (2000) @(posedge clk48);
        check(dut.neogeo.status[4], "the setting did not reach status[4]");
        check(!dut.neogeo.nCD1 && !dut.neogeo.nCD2, "status[4] unplugged the CD's card");
        host.bfm.write32(32'hF000_010C, 32'd0);
    endtask

    // The ends of the range, where a sum kept in 16 bits or not sign-extended shows, L and R told apart at the pins.
    // The 17-bit sum, halved, always fits: this is the saturation the plan asks for, and no logic does it
    task automatic test_mix_extremes();
        logic [15:0] t [5][3] = '{'{16'h7FFF, 16'h7FFF, 16'h7FFF}, '{16'h8000, 16'h8000, 16'h8000}, '{16'h7FFF, 16'h8000, 16'hFFFF},
                                  '{16'hFFFF, 16'h0001, 16'h0000}, '{16'h7FFF, 16'h0001, 16'h4000}};
        test = "test_mix_extremes";
        foreach (t[i]) begin
            force dut.neogeo.ym_left = t[i][0];
            force dut.neogeo.CD_AUDIO_L = t[i][1];
            force dut.neogeo.ym_right = t[i][1];
            force dut.neogeo.CD_AUDIO_R = t[i][0];
            repeat (2) @(posedge clk48);
            check(dut.neogeo.snd_left == t[i][2] && dut.neogeo.snd_right == t[i][2],
                  $sformatf("%04x and %04x mix to %04x and %04x, expected %04x", t[i][0], t[i][1], dut.neogeo.snd_left, dut.neogeo.snd_right, t[i][2]));
        end
        force dut.neogeo.ym_left = 16'h7FFF;
        force dut.neogeo.CD_AUDIO_L = 16'h7FFF;
        force dut.neogeo.ym_right = 16'h8000;
        force dut.neogeo.CD_AUDIO_R = 16'h8000;
        repeat (3) @(negedge audio_lrck);
        @(posedge audio_lrck);
        repeat (80) @(posedge audio_mclk);
        check({i2s_l, i2s_r} == 32'h7FFF_8000, $sformatf("the pins have L %04x R %04x, expected 7fff 8000", i2s_l, i2s_r));
        release dut.neogeo.ym_left;
        release dut.neogeo.CD_AUDIO_L;
        release dut.neogeo.ym_right;
        release dut.neogeo.CD_AUDIO_R;
    endtask

    // n frames of the queue from from: 1 kHz within 2%, every period about right, as a sector dropped or repeated slips the
    // phase by a third of one, and each side's peak within 10% of the disc's after the halving. Both channels
    function automatic void check_tone(input int from, input int n, input string how);
        for (int ch = 0; ch < 2; ch++) begin
            automatic int first = -1, last = -1, cycles = 0, hi = -40000, lo = 40000, prev = 0, gap_bad = 0, gap_at = 0;
            automatic real khz;
            for (int i = from; i < from + n; i++) begin
                automatic int s = int'($signed(ch == 0 ? i2s_q[i][31:16] : i2s_q[i][15:0]));
                if (s > hi) hi = s;
                if (s < lo) lo = s;
                if (i != from && prev < 0 && s >= 0) begin
                    if (last >= 0) begin
                        if (i - last < TONE_PERIOD - 2 || i - last > TONE_PERIOD + 2) begin
                            gap_bad++;
                            gap_at = i - from;
                        end
                        cycles++;
                    end
                    else first = i;
                    last = i;
                end
                prev = s;
            end
            khz = cycles == 0 ? 0.0 : real'(I2S_KHZ) * real'(cycles) / real'(last - first);
            check(khz >= 0.98 && khz <= 1.02, $sformatf("%s, channel %0d: %0.3f kHz over %0d periods", how, ch, khz, cycles));
            check(gap_bad == 0, $sformatf("%s, channel %0d: %0d periods off, the last at frame %0d of %0d", how, ch, gap_bad, gap_at, n));
            check(real'(hi) >= 0.9 * TONE_PEAK && real'(hi) <= 1.1 * TONE_PEAK && real'(-lo) >= 0.9 * TONE_PEAK && real'(-lo) <= 1.1 * TONE_PEAK,
                  $sformatf("%s, channel %0d: from %0d to %0d, the peak should be %0d", how, ch, lo, hi, TONE_PEAK));
            $display("%s, channel %0d: %0.3f kHz, %0d to %0d, %0d frames", how, ch, khz, lo, hi, n);
        end
    endfunction

    // ---- A disc ----

    // The data table's entry of a slot, as the host fills it: the id, then the file's size
    task automatic table_slot(input int index, input logic [31:0] id, input logic [31:0] size);
        host.bfm.write32(32'hF800_2000 + 32'(8 * index), id);
        host.bfm.write32(32'hF800_2004 + 32'(8 * index), size);
    endtask

    // When no 68K cycle is open, so that no read of a word meets its changing under it
    task automatic bus_idle();
        do @(negedge clk48); while (!nAS || in_cycle);
    endtask

    // Asks the program for a PLAY, expecting these words: what it finds in PROG RAM is not what was there
    task automatic request_play(input logic [15:0] words);
        bus_idle();
        for (int i = 0; i < 1024; i++) mem_c0.mem[DMA_TO_W + 23'(i)] = 16'hDEAD;
        mem_c0.mem[SECTOR_WORDS_W] = words;
        mem_c0.mem[PLAY_REQ_W] = 16'd1;
    endtask

    function automatic void check_dma_words(input logic [15:0] words, input string how);
        int bad = 0;
        for (int i = 0; i < 1024; i++) if (mem_c0.mem[DMA_TO_W + 23'(i)] != words) bad++;
        check(bad == 0, $sformatf("%s: %0d of 1,024 words at 0x120000 are not %04x, word 0 is %04x", how, bad, words, mem_c0.mem[DMA_TO_W]));
    endfunction

    function automatic void check_toc(input logic [79:0] e, input logic audio, input int start, input int stop, input int file_lba, input string how);
        automatic logic [79:0] want = {audio, 7'd1, 24'(start), 24'(stop), 24'(file_lba)};
        check(e == want, $sformatf("%s: TOC entry %020x, expected %020x", how, e, want));
    endfunction

    function automatic void check_mounted(input string how);
        check(dut.neogeo.disc_present && !dut.neogeo.disc_loading, $sformatf("%s: present %b loading %b, mount's reason %0d", how, dut.neogeo.disc_present, dut.neogeo.disc_loading, dut.disc_reason));
        check(dut.neogeo.track_count_s == DISC_TRACKS && dut.neogeo.disc_end_s == DISC_END,
              $sformatf("%s: %0d tracks to the end at %0d, the drive's view", how, dut.neogeo.track_count_s, dut.neogeo.disc_end_s));
        check_toc(dut.cdmount.toc[0], 0, 0, 32, 0, how);
        check_toc(dut.cdmount.toc[1], 1, 34, 44, 34, how);
    endfunction

    realtime t_play_fast = 0;

    task automatic test_mount_on_boot();
        realtime t_all, limit;
        automatic int rel = releases;
        automatic int writes = toc_writes;
        test = "test_mount_on_boot";
        mbox = 0;
        vbl_count = 0;
        bus_idle();
        mem_c0.mem[SECTOR_WORDS_W] = WORDS_16;
        host.slot_file[2] = {DISC_DIR, "disc.cue"};
        host_cmd(16'h0010);
        table_slot(2, 32'd2, 32'(host.file_size({DISC_DIR, "disc.cue"})));
        table_slot(3, 32'd3, 32'd0);
        host_cmd(16'h0080);     // a load begins: dataslot_allcomplete falls
        check(!dut.dataslot_allcomplete, "dataslot_allcomplete did not fall for the load");
        host_cmd(16'h008F);
        t_all = $realtime;
        host_cmd(16'h0090, 32'd0, 32'h2026_1101, 32'h0312_3456);
        limit = t_all + MOUNT_MS * 1e6;
        while (!disc_present_s && $realtime < limit) @(posedge clk74);
        // The core leaves reset after the mount: on the Pocket the hold is 0.5 s and the mount takes tens of ms, where
        // this bench's hold is 27 us. A swap has the other order, a core running through the mount
        check(!nRESET, "the core left reset before the mount's end");
        host_cmd(16'h0011);
        check(disc_present_s, $sformatf("no disc %0.0f ms after dataslot_allcomplete: loading %b, mount's reason %0d", MOUNT_MS, dut.neogeo.disc_loading, dut.disc_reason));
        $display("mounted %0.1f ms after dataslot_allcomplete, %0d TOC writes, %0d host commands", ($realtime - t_all) / 1e6, toc_writes - writes, host.log_q.size());
        check(toc_writes - writes == DISC_TRACKS, $sformatf("%0d TOC writes for %0d tracks", toc_writes - writes, DISC_TRACKS));
        check_mounted("on boot");
        wait_release(300.0);
        check(releases == rel + 1, "no release of reset for the load");
    endtask

    task automatic test_play_dma_to_prog();
        automatic int edges, logged;
        automatic bit track2 = 0;
        test = "test_play_dma_to_prog";
        wait_mbox(16'd12, 300.0);
        wait_mbox(16'd13, 600.0);
        t_play_fast = $realtime - t_play_cmd;
        $display("PLAY to mailbox 13, a host of 1 ms: %0.1f ms", t_play_fast / 1e6);
        check_dma_words(WORDS_16, "first PLAY");
        $display("DMA, a word of the sector to PROG RAM: %0d to %0d CLK_48M, %0.1f on average, %0d words", dma_gap_min, dma_gap_max,
                 real'(dma_gap_sum) / real'(dma_gaps == 0 ? 1 : dma_gaps), dma_gaps + 1);
        check(dma_gaps != 0, "no DMA word to PROG RAM was seen");
        test_read_after_dma_end();
        test = "test_play_dma_to_prog";
        i2s_start();
        edges = cdda_edges;
        logged = host.log_q.size();
        wait_mbox(16'd14, 500.0);
        for (int i = logged; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0180 && host.log_q[i].id == 16'd3 && host.log_q[i].err == 0 && host.log_q[i].offset == 32'(34 * 2352)) track2 = 1;
        check(track2, "TRACK_PLAY 02 did not read track 2's first sector, 34 in the BIN");
        check(cdda_edges - edges >= 3 * 1176 && cdda_edges % 1176 == 0,
              $sformatf("%0d CDDA words in TRACK_PLAY, total %0d: whole sectors of 1,176 expected", cdda_edges - edges, cdda_edges));
        $display("CDDA: %0d sectors streamed by mailbox 14", cdda_edges / 1176);
    endtask

    task automatic test_read_after_dma_end();
        test = "test_read_after_dma_end";
        tests++;
        check(adma_seen && {adma_addr, 1'b0} == 24'h1207FE, $sformatf("the first PROG RAM read after the DMA is of %06x", {adma_addr, 1'b0}));
        check(adma_data == WORDS_16, $sformatf("the first read after the DMA took %04x", adma_data));
    endtask

    // The whole of track 2 but the last sector's end, from the frame the tone starts, which test_play_dma_to_prog's capture has
    task automatic test_cdda_tone_on_i2s();
        realtime limit = $realtime + 200.0e6;
        int n = TRACK_FRAMES - 400;
        test = "test_cdda_tone_on_i2s";
        while ((i2s_first < 0 || i2s_q.size() < i2s_first + n) && $realtime < limit) @(posedge clk74);
        check(i2s_first >= 0 && i2s_q.size() >= i2s_first + n, $sformatf("%0d frames from the start of the tone at %0d, %0d expected", i2s_q.size() - i2s_first, i2s_first, n));
        if (i2s_first >= 0 && i2s_q.size() >= i2s_first + n) check_tone(i2s_first, n, "track 2");
        check(cdda_held != 0, "no tick found the audio sink full: its ready was never what held the drive back");
        $display("CDDA: %0d ticks held back by the audio sink's ready", cdda_held);
    endtask

    // A host slower than the disc: sectors with silence between them, not a stall, and the tone when the host catches up
    task automatic test_cdda_underrun_is_silence_not_hang();
        realtime t0, limit;
        automatic int v0, run = 0, gaps = 0, n;
        test = "test_cdda_underrun_is_silence_not_hang";
        host.latency_clks = HOST_LATE_60MS;
        mbox = 0;
        bus_idle();
        mem_c0.mem[PLAY_REQ_W] = 16'd2;
        wait_mbox(16'd15, 100.0);
        // The seek's silence is not this test's: from the first request at the track's start, the FIFO long empty
        limit = $realtime + 300.0e6;
        while (dut.neogeo.req_lba != 34 && $realtime < limit) @(posedge clk74);
        check(dut.neogeo.req_lba == 34 && dut.neogeo.req_audio, $sformatf("no request of sector 34, at %0d", dut.neogeo.req_lba));
        i2s_start();
        t0 = $realtime;
        v0 = vbl_count;
        // Two sectors' tone and the silence after each at 13 ms in 60 ms
        limit = $realtime + 400.0e6;
        while ((i2s_first < 0 || i2s_q.size() < i2s_first + 100 * I2S_KHZ) && $realtime < limit) @(posedge clk74);
        check(i2s_first >= 0 && i2s_q.size() >= i2s_first + 100 * I2S_KHZ, "no audio in 400 ms of a 60 ms host");
        for (int i = i2s_first < 0 ? 0 : i2s_first; i < i2s_q.size(); i++)
            if (i2s_q[i] == 0) run++;
            else begin
                if (run >= 30 * I2S_KHZ) gaps++;
                run = 0;
            end
        check(gaps != 0, "no 30 ms of exact silence with sound after it: the underrun did not read as silence");
        check_tone(i2s_first, 12 * I2S_KHZ, "the first sector of an underrun");
        // The program ran all along, frame by frame
        check(vbl_count - v0 >= int'(($realtime - t0) / 17.0e6) - 1, $sformatf("%0d VBlanks in %0.1f ms", vbl_count - v0, ($realtime - t0) / 1e6));
        $display("underrun: %0d gaps of silence in %0.1f ms of audio, %0d VBlanks in %0.1f ms", gaps, real'(i2s_q.size() - i2s_first) / I2S_KHZ, vbl_count - v0, ($realtime - t0) / 1e6);
        // The host catches up: the read in flight lands, and what is left of the track plays through
        host.latency_clks = HOST_LATENCY;
        n = i2s_q.size() + 80 * I2S_KHZ;
        limit = $realtime + 200.0e6;
        while (i2s_q.size() < n + 30 * I2S_KHZ && $realtime < limit) @(posedge clk74);
        check(i2s_q.size() >= n + 30 * I2S_KHZ, "the I2S frames stopped");
        check_tone(n, 30 * I2S_KHZ, "after the underrun");
        check(!dut.neogeo.fetch_err, "a sector failed");
        i2s_on = 0;
    endtask

    task automatic test_late_host_delays_but_delivers();
        automatic int reads = host.n_read;
        test = "test_late_host_delays_but_delivers";
        host.latency_clks = 1_485_000;      // 20 ms
        mbox = 0;
        request_play(WORDS_16);
        wait_mbox(16'd13, 1000.0);
        host.latency_clks = HOST_LATENCY;
        $display("PLAY to mailbox 13, a host of 20 ms: %0.1f ms; of 1 ms: %0.1f ms", ($realtime - t_play_cmd) / 1e6, t_play_fast / 1e6);
        check(host.n_read != reads, "no host read for the sector: nothing was late");
        check($realtime - t_play_cmd > t_play_fast, "the late host was no later");
        check_dma_words(WORDS_16, "late host");
    endtask

    // A disc picked with a game running. This assumes the Pocket keeps dataslot_allcomplete up over
    // the pick, which only hardware shows (hardware test 3, h). If it falls, apf_loader.sv:251 resets the core and a pick
    // is a boot, which test_mount_on_boot covers. Ends with the drive stopped, the new disc in.
    task automatic swap_disc(input string cue, input string bin);
        realtime t0, limit;
        automatic int writes = toc_writes;
        automatic int logged = host.log_q.size();
        automatic bit opened = 0;
        automatic longint size = host.file_size(cue);
        swap_on = 1;
        swap_tray = 0;
        swap_stop = 0;
        host.slot_file[2] = cue;
        t0 = $realtime;
        host_cmd(16'h008A, 32'd2, 32'(size));
        host.bfm.write32(32'hF800_2014, 32'(size));     // the size, a table sweep after the request
        check(dut.neogeo.disc_loading && !dut.neogeo.disc_present, "disc_present is up after the request");
        limit = $realtime + SWAP_MS * 1e6;
        while (dut.neogeo.disc_loading && $realtime < limit) @(posedge clk74);
        check(!dut.neogeo.disc_loading, $sformatf("mount not done in %0.0f ms", SWAP_MS));
        repeat (8) @(posedge clk48);
        $display("swap: mounted in %0.1f ms, mount's reason %0d", ($realtime - t0) / 1e6, dut.disc_reason);
        check_mounted("swap");
        check(toc_writes - writes == DISC_TRACKS, $sformatf("%0d TOC writes for %0d tracks", toc_writes - writes, DISC_TRACKS));
        for (int i = logged; i < host.log_q.size(); i++)
            if (host.log_q[i].cmd == 16'h0192 && host.log_q[i].err == 0 && host.log_q[i].path == bin) opened = 1;
        check(opened, {"no openfile of ", bin});
        check(dut.neogeo.CD_FETCH.valid == 0, "a bank slot is valid right after the mount, with nothing read");
        limit = $realtime + 200.0e6;
        while (!swap_stop && $realtime < limit) @(posedge clk74);
        check(swap_tray && swap_stop, $sformatf("the drive's status through the swap: tray %b, then stop %b", swap_tray, swap_stop));
        swap_on = 0;
    endtask

    task automatic test_disc_swap_invalidates_bank();
        automatic int rel = releases;
        logic [23:0] lba;
        test = "test_disc_swap_invalidates_bank";
        check(host.file_size({OTHER_DIR, "disc.cue"}) != host.file_size({DISC_DIR, "disc.cue"}), "the two CUEs are one size: this would not see a stale size");
        check(dut.neogeo.CD_FETCH.fbusy, "no host read in flight, the late host's: this swap is what covers one");
        mbox = 0;
        swap_disc({OTHER_DIR, "disc.cue"}, {OTHER_DIR, OTHER_BIN});
        request_play(OTHER_WORDS_16);
        wait_mbox(16'd13, 600.0);
        check_dma_words(OTHER_WORDS_16, "new disc");
        check(releases == rel, "a reset in the swap");
        // In the data track still: the data sink's ready alone holds the drive, as the audio's in test_cdda_tone_on_i2s,
        // and the monitor at the top sees a request that ignores it
        check(dut.neogeo.dbg_cur_status == 4'h1 && !dut.neogeo.req_audio, $sformatf("not playing data: status %x", dut.neogeo.dbg_cur_status));
        while (dut.neogeo.req_valid != dut.neogeo.req_done) @(posedge clk48);
        force dut.neogeo.CD_DATA_WR_READY = 1'b0;
        lba = dut.neogeo.dbg_cur_lba;
        repeat (1_500_000) @(posedge clk48);    // 31 ms, three ticks
        check(dut.neogeo.dbg_cur_lba == lba, $sformatf("the position moved from %0d to %0d with the data sink full", lba, dut.neogeo.dbg_cur_lba));
        release dut.neogeo.CD_DATA_WR_READY;
    endtask

    // TRACK_PLAY 02, up to the tone on the pins
    task automatic cdda_playing();
        realtime limit;
        i2s_start();
        mbox = 0;
        bus_idle();
        mem_c0.mem[PLAY_REQ_W] = 16'd2;
        wait_mbox(16'd15, 100.0);
        limit = $realtime + 300.0e6;
        while (i2s_first < 0 && $realtime < limit) @(posedge clk74);
        check(i2s_first >= 0, "no tone on the pins");
        i2s_on = 0;
    endtask

    // The disc goes with CDDA running, two ways. A sector in the stream, where nothing is forced: it ends whole. A sector
    // held at the sink, which takes cd_fetch's ready forced low, as the drive's own gate lets it get there only in the
    // one clock from S_DECIDE: that is what S_SINK's no-disc branch is for. Let go after the mount, it must not stream, as
    // the bank is the mount's. The new disc's words at the end
    task automatic test_disc_swap_during_cdda();
        realtime limit;
        automatic int edges, rel = releases;
        test = "test_disc_swap_during_cdda";
        cdda_playing();
        limit = $realtime + 100.0e6;
        while (!(dut.neogeo.cd_dl_download && dut.neogeo.cd_dl_audio) && $realtime < limit) @(posedge clk48);
        check(dut.neogeo.cd_dl_download && dut.neogeo.cd_dl_audio, "no audio sector in the stream");
        swap_disc({DISC_DIR, "disc.cue"}, {DISC_DIR, "disc.bin"});
        check(cdda_edges % 1176 == 0, $sformatf("%0d CDDA words: the stream the disc went under did not end whole", cdda_edges));

        cdda_playing();
        force dut.neogeo.CD_FETCH.cdda_ready = 1'b0;
        limit = $realtime + 100.0e6;
        while (!(dut.neogeo.CD_FETCH.state == dut.neogeo.CD_FETCH.S_SINK && dut.neogeo.CD_FETCH.cur_audio) && $realtime < limit) @(posedge clk48);
        check(dut.neogeo.CD_FETCH.state == dut.neogeo.CD_FETCH.S_SINK && dut.neogeo.CD_FETCH.cur_audio, $sformatf("no sector held at the sink, fetch state %0d", dut.neogeo.CD_FETCH.state));
        edges = cdda_edges;
        swap_disc({OTHER_DIR, "disc.cue"}, {OTHER_DIR, OTHER_BIN});
        release dut.neogeo.CD_FETCH.cdda_ready;
        repeat (100000) @(posedge clk48);       // 2 ms, four streams
        check(cdda_edges == edges, $sformatf("%0d CDDA words after the swap: the sector held at the sink was streamed", cdda_edges - edges));

        request_play(OTHER_WORDS_16);
        wait_mbox(16'd13, 600.0);
        check_dma_words(OTHER_WORDS_16, "after the swaps in CDDA");
        check(releases == rel, "a reset in the swaps");
    endtask

    task automatic test_reset_core();
        int rel = releases;
        int bad, frames_then;
        test = "test_reset_core";
        mbox = 0;
        vbl_count = 0;
        host.bfm.write32(32'hF000_0100, 32'd1);
        while (nRESET) @(posedge clk74);
        wait_release(300.0);
        check(releases == rel + 1, "no release after Reset Core");
        wait_mbox(16'd12, 300.0);
        // VBL_COUNT is in PROG RAM, which a reset leaves alone: the program clears it, and three counts
        // from there take frames. Without that clear the first VBlank alone would pass
        frames_then = frames;
        wait_vbl(3, 100.0);
        check(frames - frames_then >= 2, $sformatf("Reset Core: VBlank count %0d after %0d frames", vbl_count, frames - frames_then));
        // The disc is still in: the program's PLAY and DMA, with the drive and the fetch out of reset
        wait_mbox(16'd14, 800.0);
        wait_frames(2);
        bad = picture_errors(1);
        check(bad == 0, $sformatf("Reset Core: %0d wrong pixels of the fix tile", bad));
        check_clean("Reset Core");
    endtask

    // Word 32 of the wait counter's file for these settings, also with the counter out of the build
    function automatic logic [31:0] settings_word(input bit cdz, input bit lid_open, input logic [1:0] speed, input logic [1:0] region, input bit in_reset);
        logic [1:0] jumper = region == 2'd0 ? 2'b10 : region == 2'd1 ? 2'b01 : region == 2'd2 ? 2'b11 : 2'b00;
        return {24'd0, in_reset, lid_open, jumper, speed, ~lid_open ^ cdz, cdz};
    endfunction

    // FF011C as cd.sv answers it: {110, CD_LID, the jumpers 11 and the region}, CD_LID = ~lid ^ CDZ (neogeo.sv:773)
    function automatic logic [15:0] sys_config(input bit cdz, input bit lid_open, input logic [1:0] region);
        logic [1:0] jumper = region == 2'd0 ? 2'b10 : region == 2'd1 ? 2'b01 : region == 2'd2 ? 2'b11 : 2'b00;
        return {3'b110, ~lid_open ^ cdz, 2'b11, jumper, 8'h00};
    endfunction

    // The program's read of FF011C, after a setting has had time to cross
    task automatic read_sys_config(output logic [15:0] v, input real ms = 50.0);
        repeat (2000) @(posedge clk48);
        bus_idle();
        mem_c0.mem[SYS_CONFIG_W] = 16'h0000;
        mem_c0.mem[PLAY_REQ_W] = 16'd4;
        wait_mbox(16'd17, ms);
        repeat (500) @(posedge clk48);      // the word's write, posted ahead of the mailbox's
        v = mem_c0.mem[SYS_CONFIG_W];
        mbox = 0;
    endtask

    // The CD settings of interact.json as the BIOS sees them, and what a held core reset shows in the drive's debug
    // view. Region and lid act at once; CD/CDZ is SYSTEM_CD_TYPE, taken only while the core is in reset, as MiSTer, and
    // a change restarts the core.
    // The host restores persistent settings before Reset Exit, so it writes them here while Reset Enter holds the
    // core. While held, the drive reads STOP at LBA 0 and keeps its last status and command words, and the video
    // keeps its frames, while the wait counter's record stays at the run's last frame
    task automatic check_settings_file(input logic [15:0] ff011c, input logic [31:0] want, input string how);
`ifdef NEOGEO_WAIT_COUNTER
        logic [31:0] w [$];
        @(posedge dut.core_vblank);
        repeat (140) @(posedge clk48);
        host.bfm.read_file(run_record(), 128, w);
        check(w[32] == want, $sformatf("%s: the settings word %08x, want %08x", how, w[32], want));
        check(w[32][1] == ff011c[12], $sformatf("%s: bit 12 is %b in the file, %b as the 68K read FF011C", how, w[32][1], ff011c[12]));
        check(w[32][5:4] == ff011c[9:8], $sformatf("%s: the region is %b in the file, %b as the 68K read FF011C", how, w[32][5:4], ff011c[9:8]));
        check(w[33] == {8'(releases), 24'(rel_frame)}, $sformatf("%s: resets word %08x, the bench has %0d at frame %0d", how, w[33], releases, rel_frame));
`endif
    endtask

    task automatic test_cd_settings();
        logic [15:0] v;
        logic [39:0] st_was, cmd_was;
        int rel = releases, vb = 0;
        bit vb_d = 0;
        test = "test_cd_settings";
        read_sys_config(v);
        check(v == sys_config(0, 0, 2'd0), $sformatf("CD, lid closed, US: FF011C %04x, want %04x", v, sys_config(0, 0, 2'd0)));
        check_settings_file(v, settings_word(0, 0, 0, 0, 0), "defaults");
        check(dut.neogeo.dbg_cur_status != 4'h0 || dut.neogeo.dbg_cur_lba != 0, "the drive is at STOP, LBA 0 already: the reset check below would prove nothing");
        st_was = dut.neogeo.CDD_STATUS;
        cmd_was = dut.neogeo.CDD_COMMAND_DATA;
        $display("before the reset: drive status %x at LBA %0d, last status %010x, last command %010x",
                 dut.neogeo.dbg_cur_status, dut.neogeo.dbg_cur_lba, st_was, cmd_was);
        host_cmd(16'h0010);
        while (nRESET) @(posedge clk74);
        host.bfm.write32(32'hF000_0600, 32'd1);     // CD/CDZ on
        host.bfm.write32(32'hF000_0604, 32'd2);     // Region JP
        // Two frames in reset
        repeat (2) begin
            while (!dut.core_vblank) @(posedge clk48);
            while (dut.core_vblank) @(posedge clk48);
            vb++;
            check(!nRESET, "the core left reset during Reset Enter");
            check(dut.neogeo.dbg_cur_status == 4'h0 && dut.neogeo.dbg_cur_lba == 0,
                  $sformatf("in reset the drive reads %x at LBA %0d, not STOP at 0", dut.neogeo.dbg_cur_status, dut.neogeo.dbg_cur_lba));
            check(dut.neogeo.CDD_STATUS == st_was, $sformatf("in reset the last status is %010x, was %010x", dut.neogeo.CDD_STATUS, st_was));
            check(dut.neogeo.CDD_COMMAND_DATA == cmd_was, $sformatf("in reset the last command is %010x, was %010x", dut.neogeo.CDD_COMMAND_DATA, cmd_was));
        end
        check(vb == 2, "no VBlank while the core is in reset");
        // The new values, taken while held as the host restores them, wait for the next run's record
        check_settings_file(sys_config(0, 0, 2'd0), settings_word(0, 0, 0, 0, 0), "held in reset");
        host_cmd(16'h0011);
        wait_release(300.0);
        check(releases == rel + 1, "no release after Reset Exit");
        check(dut.neogeo.SYSTEM_CDZ, "CD/CDZ written during Reset Enter was not taken");
`ifndef NEOGEO_WAIT_COUNTER
        check(dut.neogeo.cd_speed == 2'd1, $sformatf("a release with CD/CDZ on reads at speed %0d", dut.neogeo.cd_speed));
`endif
        wait_mbox(16'd12, 300.0);
        read_sys_config(v, 800.0);          // the program's steps 13 and 14 with the disc come first
        check(v == sys_config(1, 0, 2'd2), $sformatf("CDZ, lid closed, JP: FF011C %04x, want %04x", v, sys_config(1, 0, 2'd2)));
        check_settings_file(v, settings_word(1, 0, 0, 2, 0), "CDZ, JP");
        host.bfm.write32(32'hF000_0608, 32'd3);     // CD Speed 4x, and back
        check_settings_file(v, settings_word(1, 0, 3, 2, 0), "CDZ, JP, 4x");
        host.bfm.write32(32'hF000_0608, 32'd0);
        // The lid: FF011C at once, and the drive holds OPEN. A CDZ reads 1 for open
        host.bfm.write32(32'hF000_060C, 32'd1);
        read_sys_config(v);
        check(v == sys_config(1, 1, 2'd2), $sformatf("CDZ, lid open, JP: FF011C %04x, want %04x", v, sys_config(1, 1, 2'd2)));
        check_settings_file(v, settings_word(1, 1, 0, 2, 0), "CDZ, lid open, JP");
        check(dut.neogeo.dbg_cur_status == 4'h5, $sformatf("lid open: the drive reads %x, not OPEN", dut.neogeo.dbg_cur_status));
        host.bfm.write32(32'hF000_060C, 32'd0);
        // Region US at once, and CD/CDZ written again unchanged, as the host may do: no reset
        rel = releases;
        host.bfm.write32(32'hF000_0600, 32'd1);
        host.bfm.write32(32'hF000_0604, 32'd0);
        read_sys_config(v);
        check(v == sys_config(1, 0, 2'd0), $sformatf("region US: FF011C %04x, want %04x", v, sys_config(1, 0, 2'd0)));
        check(nRESET && releases == rel, "CD/CDZ written unchanged reset the core");
        // CD/CDZ off, a change: the core restarts by itself, with no Reset Enter, and comes back as a CD
        host.bfm.write32(32'hF000_0600, 32'd0);
        while (nRESET) @(posedge clk74);
        wait_release(300.0);
        check(releases == rel + 1, "changing CD/CDZ did not restart the core");
        check(dut.neogeo.status[2] == 0 && !dut.neogeo.SYSTEM_CDZ, "status[2] or SYSTEM_CDZ after the restart");
`ifndef NEOGEO_WAIT_COUNTER
        check(dut.neogeo.cd_speed == 2'd0, $sformatf("a release with CD/CDZ off reads at speed %0d", dut.neogeo.cd_speed));
`endif
        check_clean("CD settings");
    endtask

    function automatic void report();
        $display("drive: status %x at LBA %0d, track %0d, request %b done %b, ready data %b audio %b, fetch state %0d, fetch_err %b, disc %b loading %b, mount's reason %0d",
                 dut.neogeo.dbg_cur_status, dut.neogeo.dbg_cur_lba, dut.neogeo.CDD_DRIVE.index, dut.neogeo.req_valid, dut.neogeo.req_done,
                 dut.neogeo.CD_DATA_WR_READY, dut.neogeo.CDDA_WR_READY, dut.neogeo.CD_FETCH.state, dut.neogeo.fetch_err, disc_present_s,
                 dut.neogeo.disc_loading, dut.disc_reason);
        $display("68K bus by class. len: nAS low, CLK_48M. rdy: strobe to PROM_DATA_READY, CLK_96M. lost: the sum of len - %0d", ZERO_WAIT_LEN);
        for (int k = 0; k < C_N; k++) if (st[k].n != 0)
            $display("  %-15s n=%0d len %0d..%0d avg %0.2f, rdy %0d..%0d, lost %0d", cname[k], st[k].n, st[k].len_min, st[k].len_max,
                     real'(st[k].len_sum) / real'(st[k].n), st[k].rdy_min, st[k].rdy_max, st[k].lost);
        $display("mux cycles by arrival code 0, 1, 2, 3 (0 is the CD write queue, 1 idle): %0d, %0d, %0d, %0d; lost clocks %0d, %0d, %0d, %0d",
                 mux_n[0], mux_n[1], mux_n[2], mux_n[3], mux_lost[0], mux_lost[1], mux_lost[2], mux_lost[3]);
        $display("PROG phase: %0d CLK_48M, %0d fix reads, lost %0d, %0.2f%%. All run: %0d fix reads",
                 ph_clk, ph_fix, ph_lost, lost_pct(ph_lost), all_fix);
        $display("fix: %0d reads in the SRAM, %0d CLK_96M at worst from PCK2's fall, deadline %0d", all_fix, fix_lat_max, FIX_DEADLINE);
        $display("stale read margin: %0d CD writes, write edge to queue head at worst %0d CLK_96M, write edge to the next 68K read edge at least %0d",
                 wr_edges, wr_to_head_max, wr_to_rd_min);
        $display("SPR stale read margin: %0d SPR writes, write edge to queue head at worst %0d CLK_96M, write edge to the next SPR read edge at least %0d",
                 spr_writes, spr_to_head_max, spr_to_rd_min);
        $display("Z80: %0d opcodes, %0d NMIs. sim time %0.1f ms", dut.neogeo.Z80CPU.cpu.opcode_count, dut.neogeo.Z80CPU.cpu.nmi_count, $realtime / 1e6);
    endfunction

    // +stop=NAME ends the run after that test, for shorter runs
    string stop_after = "";
    initial void'($value$plusargs("stop=%s", stop_after));

    task automatic run(input string name);
        tests++;
        case (name)
            "test_cdd_tick":   test_cdd_tick();
            "test_bios_short_holds_reset": if (!quick) test_bios_short_holds_reset();
            "test_power_up":   test_power_up();
            "test_picture":    test_picture();
            "test_dma_pcm":    test_dma_pcm();
            "test_fix_uploads": test_fix_uploads();
            "test_z80_from_ram": test_z80_from_ram();
            "test_68k_cost":   test_68k_cost();
`ifdef NEOGEO_WAIT_COUNTER
            "test_wait_counter": test_wait_counter();
`endif
            "test_saves_8k":   test_saves_8k();
            "test_mix_extremes": test_mix_extremes();
            "test_mount_on_boot": test_mount_on_boot();
            "test_play_dma_to_prog": test_play_dma_to_prog();
            "test_cdda_tone_on_i2s": test_cdda_tone_on_i2s();
            "test_cdda_underrun_is_silence_not_hang": test_cdda_underrun_is_silence_not_hang();
            "test_late_host_delays_but_delivers": test_late_host_delays_but_delivers();
            "test_disc_swap_invalidates_bank": test_disc_swap_invalidates_bank();
            "test_disc_swap_during_cdda": test_disc_swap_during_cdda();
            "test_reset_core": test_reset_core();
            "test_cd_settings": test_cd_settings();
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
        automatic string files [] = '{{DISC_DIR, "disc.cue"}, {DISC_DIR, "disc.bin"}, {OTHER_DIR, "disc.cue"}, {OTHER_DIR, OTHER_BIN}};
        fork host.serve_forever(files); join_none
        run("test_cdd_tick");
        run("test_bios_short_holds_reset");
        run("test_power_up");
`ifdef NEOGEO_WAIT_COUNTER
        run("test_wait_counter");   // early, so that +stop makes a short mutation run
`endif
        run("test_dma_pcm");
        run("test_fix_uploads");
        run("test_z80_from_ram");
        run("test_picture");
        run("test_saves_8k");
        run("test_mix_extremes");
        run("test_mount_on_boot");
        program_runs = 2;
        run("test_play_dma_to_prog");
        run("test_cdda_tone_on_i2s");
        run("test_cdda_underrun_is_silence_not_hang");
        run("test_late_host_delays_but_delivers");
        run("test_disc_swap_invalidates_bank");
        run("test_disc_swap_during_cdda");
        run("test_68k_cost");       // here, so that a mount and a DMA are in its run
        program_runs = 3;
        run("test_reset_core");
`ifdef NEOGEO_WAIT_COUNTER
        run("test_wait_counter");
`endif
        run("test_cd_settings");    // last: it leaves the core latched as a CDZ
        report();
        if (errors != 0) $fatal(1, "%0d failures", errors);
        $display("topcd: %0d tests passed", tests);
        $finish;
    end

    // Run the binary by hand with +progress to watch it: sim.py shows nothing until the end
    initial if ($test$plusargs("progress")) forever begin
        #(2.0e6);
        $display("t=%0.1f ms nRESET %b mbox %04x vbl %0d frames %0d A %06x nAS %b DS %b%b RW %b DTACK %b rdy %b cyc %0d",
                 $realtime / 1e6, nRESET, mbox, vbl_count, frames, {CPU_A, 1'b0}, nAS, nUDS, nLDS, RW, nDTACK, READY, first_n);
        $fflush();
    end

    initial begin
        #(4.0e9);
        report();
        $fatal(1, "timeout");
    end
endmodule
