//============================================================================
//  Memory mux of the Neo Geo core for the Analogue Pocket.
//
//  Port of sdram_mux.sv and the client side of ddram.sv from NeoGeo_MiSTer onto the Pocket's
//  SDRAM and two PSRAM chips.
//
//  sdram_mux.sv: Copyright (C) 2018 Sean 'Furrtek' Gonsalves
//  ddram.sv:     Copyright (c) 2017 Sorgelig
//  Arbitration policy and ADPCM/Z80 mapping after cram_16bit.v and cram_8bit.v of Mazamars312's
//  Neo Geo Overdrive for Pocket ("Free of use"), reimplemented with no code copied.
//
//  This program is free software; you can redistribute it and/or modify it under the terms of
//  the GNU General Public License as published by the Free Software Foundation; either version
//  3 of the License, or (at your option) any later version. sdram_mux.sv is GPL-2-or-later,
//  ddram.sv GPL-3-or-later; the combined work is distributed under GPL-3.
//============================================================================

// All clocks are CLK_96M. Each chip has one registered master:
//   CRAM0  loader > 68K > fix (cart) > CD write > Z80, and a Z80 access starts only in the window after PCK2 falls
//   CRAM1  loader > CD write > ADPCM-A > ADPCM-B
//   SDRAM  sprite > CD read > loader > CD write; refresh is a toggle the controller takes first, spaced apart
//          here, and a slot that finds a CD write waiting passes to it, as sdram_mux ranks them
//   SRAM   fix (CD) > CD read > CD write, through cd_fix_sram
//
// Requests stay pending until served, so clients arriving together are all served in order, and
// no path relies on the CPUs being in reset. With nRESET low no CPU or ADPCM read reaches a CRAM
// (their toggles are answered at once), so a load under reset is a pure write stream.
//
// Top word of a PSRAM die (3FFFFFh): no guard. The loader writes ascending from 512 KB aligned
// bases, and the write to a top word follows the write below it. The CD never writes a top word:
// PROG RAM ends at 0x1FFFFF and PCM RAM at 0xFFFFF, below both tops.
//
// Loader: DL_ADDR is the byte offset within the file, DL_WR is one clock per word. Words go
// through a small FIFO, as the bridge has no back-pressure. Sustained limit: one word per 10
// clocks on CRAM, per 9 on SDRAM, and a burst of 4 beyond that; a word arriving at a full FIFO
// is dropped and sets dl_overflow until MEM_INIT. Do not start before the SDRAM has left its
// 125 us startup after MEM_INIT.
//
// CD: PROG RAM is in CRAM0. A rising CD_EXT_RD is a 68K read, answered on PROM_DATA. A rising CD_EXT_WR,
// CD_TR_WR_SPR, CD_TR_WR_PCM or CD_TR_WR_FIX is posted to one queue, as the 68K's own writes may arrive
// behind other traffic. A read ranks above the queue, as sdram_mux: a read of a word still queued would be
// stale, and it cannot happen at the 68K's 32 clocks per bus cycle, as the head has started before the next
// one. A faster 68K must check this again (the bench's WR_TO_RD). DMA_SDRAM_BUSY stalls the DMA engine per
// access, so only the 68K can find the queue full. PCM and FIX writes hold the 68K's DTACK until they are in
// the chip (CD_PCM_DTACK), so a FF0149 cannot overtake a FIX write in flight.
//
// The remaps are sdram_mux.sv:120,123 with the chip changed: SPR RAM is at the SDRAM's 0 (4 MB), FIX RAM
// at the SRAM's word 0 (nSYSTEM_G is always 1 in the CD build, so the fix always reads it), and PCM RAM at
// CRAM1's 0, whose byte address is {CD_BANK_PCM, A[19:1]}, as neogeo.sv:1693 and the ADPCM-A read side.
// A video fix read happens with CD_USE_FIX low only and a transfer needs it high, so the two do not meet; if
// one were to find the other in flight it waits, as the SRAM has one master here.
// cd.sv's TR_ZONE looks at DMA_ADDR_OUT alone, so a DMA from PROG RAM to the window raises CD_TR_RD_* with
// CD_EXT_RD. That read is PROG RAM's, as the casez of sdram_mux.sv:112. A CD_* signal with SYSTEM_CDx=0 has
// no effect.
module pocket_mem_mux #(
    parameter RFSH_MAX = 720,   // clocks after a refresh toggle before the watchdog fires; with the
                                // controller's 8 clock busy window, 728 x 10.417 ns < 7.8 us
    parameter RFSH_MIN = 10,    // no refresh toggles closer than this: two in one busy window cancel
    // A Z80 access starts only this many clocks after PCK2 falls (Mazamars312's value, a 64 clock
    // period), so that none is in flight when the next fix request lands. 127 turns it off.
    parameter [6:0] Z80_WINDOW = 53,
    parameter RD_WAIT = 8,      // of cram_ctrl; the core builds 8 (neogeo.qsf), Mazamars312's core samples at 6
    // PROM_DATA and PROM_DATA_READY in the ack clock, a clock sooner, as Mazamars312's cram_16bit.v
    parameter bit READY_COMB = 0,
    // Keep the last M1 word: the Z80's read of its other byte takes no CRAM0 access
    parameter bit Z80_WORD_BUF = 0,
    // Posted CD writes queued. 2 for the 68K's one per 32 clocks; a faster 68K may want more.
    parameter CD_WQ_DEPTH = 2,
    // The CD paths exist. SYSTEM_CDx turns them on at run time
    parameter bit CD_BUILD = 0,
    // Memory test only: loader index 14 writes CRAM0 linearly, as the indices above leave holes
    parameter bit RAW_CRAM0 = 0
) (
    input             CLK,
    input             MEM_INIT,     // resets the memory controllers (PLL not locked)
    input             nRESET,
    input             nSYSTEM_G,
    input             SYSTEM_CDx,

    input      [20:1] M68K_ADDR,
    input      [15:0] M68K_DATA,
    input             nAS,
    input             nLDS,
    input             nUDS,
    input             nROMOE,
    input             nPORTOE,
    input             nSROMOE,
    input      [26:0] P2ROM_ADDR,
    output     [15:0] PROM_DATA,
    output            PROM_DATA_READY,

    input             PCK2,
    input      [15:0] S_LATCH,
    input       [1:0] FIX_BANK,
    input             FIX_EN,
    output reg [15:0] SROM_DATA = 0,

    input             PCK1,
    input      [26:0] CROM_ADDR,
    input             SPR_EN,
    output reg [63:0] CR_DOUBLE = 0,

    input             REFRESH_EN,

    input             DL_EN,
    input      [15:0] DL_DATA,
    input      [26:0] DL_ADDR,
    input             DL_WR,
    input       [7:0] DL_INDEX,
    output reg        dl_overflow = 0,  // sticky: DL_WR arrived with the FIFO full, a word was lost
    output     [27:0] dbg_c0,           // for the memory test only: {req, owner, 68K pending, fix pending, word}
`ifdef NEOGEO_WAIT_COUNTER
    output reg  [1:0] dbg_at_req = 1,   // CRAM0 when the 68K's last request arrived: owner code, C0_68K for idle
    output    [383:0] dbg_dma,          // wait_counter.sv, words in the order of the assign below
`endif

    input       [2:0] CD_TR_AREA,
    input             CD_EXT_WR,
    input             CD_EXT_RD,
    output            CD_EXT_WR_READY,  // 0 while a CD write waits on a full queue: the top holds nDTACK
    input             CD_USE_FIX,
    input             CD_TR_RD_FIX,
    input             CD_TR_WR_FIX,
    input       [1:0] CD_BANK_SPR,
    input             CD_USE_SPR,
    input             CD_TR_RD_SPR,
    input             CD_TR_WR_SPR,
    input             CD_TR_WR_PCM,
    input             CD_BANK_PCM,
    output reg        CD_PCM_DTACK = 0, // a CPU PCM or FIX write is in the chip, until nAS rises
    input      [23:0] DMA_ADDR_OUT,
    input      [23:0] DMA_ADDR_IN,
    input      [15:0] DMA_DATA_OUT,
    input             DMA_RUNNING,
    output            DMA_SDRAM_BUSY,

    input      [24:0] adpcma_addr,
    output reg  [7:0] adpcma_dout = 0,
    input             adpcma_req,
    output reg        adpcma_ack = 0,
    input      [24:0] adpcmb_addr,
    output reg  [7:0] adpcmb_dout = 0,
    input             adpcmb_req,
    output reg        adpcmb_ack = 0,
    input      [23:0] v2_offset,    // CRAM1 byte address of an ADPCM-B address with bit 24 set
    input      [18:0] m1_addr,
    output reg  [7:0] m1_dout = 0,
    input             m1_req,
    output reg        m1_ack = 0,

    // FIX RAM of the CD build: cd_fix_sram, on the related CLK_48M. Unused in the cart build
    output reg        fx_req = 0,       // toggle
    output reg        fx_we = 0,
    output reg [15:0] fx_word = 0,
    output reg  [1:0] fx_be = 2'b11,
    output reg [15:0] fx_wdata = 0,
    input             fx_ack,
    input      [15:0] fx_rdata,

    // SDRAM pins
    inout      [15:0] dram_dq,
    output     [12:0] dram_a,
    output      [1:0] dram_dqm,
    output      [1:0] dram_ba,
    output            dram_we_n,
    output            dram_ras_n,
    output            dram_cas_n,
    output            dram_cke,
    output            dram_clk,

    // CRAM0 pins
    output    [21:16] cram0_a,
    inout      [15:0] cram0_dq,
    input             cram0_wait,
    output            cram0_clk,
    output            cram0_adv_n,
    output            cram0_cre,
    output            cram0_ce0_n,
    output            cram0_ce1_n,
    output            cram0_oe_n,
    output            cram0_we_n,
    output            cram0_ub_n,
    output            cram0_lb_n,

    // CRAM1 pins
    output    [21:16] cram1_a,
    inout      [15:0] cram1_dq,
    input             cram1_wait,
    output            cram1_clk,
    output            cram1_adv_n,
    output            cram1_cre,
    output            cram1_ce0_n,
    output            cram1_ce1_n,
    output            cram1_oe_n,
    output            cram1_we_n,
    output            cram1_ub_n,
    output            cram1_lb_n
);

`include "mem_map.svh"

// The cart build gets no CD logic at all. A condition on CD_BUILD goes at elaboration, before FSM extraction and
// mux restructuring; through SYSTEM_CDx, a constant only once the port is looked through, CD paths survive them.
wire cd = CD_BUILD & SYSTEM_CDx;

// ---- Memory controllers ----

reg         c0_req = 0, c0_we = 0;
reg  [23:1] c0_addr = 0;
reg  [15:0] c0_wdata = 0;
reg   [1:0] c0_be = 2'b11;
wire [15:0] c0_rdata;
wire        c0_ack;

reg         c1_req = 0, c1_we = 0;
reg  [23:1] c1_addr = 0;
reg  [15:0] c1_wdata = 0;
reg   [1:0] c1_be = 2'b11;
wire [15:0] c1_rdata;
wire        c1_ack;

reg         sd_rd = 0, sd_wr = 0, sd_refresh = 0;
reg  [25:1] sd_addr = 0;
reg  [15:0] sd_din = 0;
reg   [1:0] sd_bs = 2'b11;
wire [15:0] sd_dout;
wire        sd_ready;

// Writes are only the loader and CD: WR_WAIT 7 trades a clock for margin on tCW
cram_ctrl #(.RD_WAIT(RD_WAIT), .WR_WAIT(7)) u_cram0 (
    .clk(CLK), .rst(MEM_INIT),
    .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(cram0_clk),
    .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n),
    .cram_oe_n(cram0_oe_n), .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n),
    .req(c0_req), .we(c0_we), .addr(c0_addr), .wdata(c0_wdata), .be(c0_be), .rdata(c0_rdata), .ack(c0_ack)
);

cram_ctrl #(.RD_WAIT(RD_WAIT), .WR_WAIT(7)) u_cram1 (
    .clk(CLK), .rst(MEM_INIT),
    .cram_a(cram1_a), .cram_dq(cram1_dq), .cram_wait(cram1_wait), .cram_clk(cram1_clk),
    .cram_adv_n(cram1_adv_n), .cram_cre(cram1_cre), .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n),
    .cram_oe_n(cram1_oe_n), .cram_we_n(cram1_we_n), .cram_ub_n(cram1_ub_n), .cram_lb_n(cram1_lb_n),
    .req(c1_req), .we(c1_we), .addr(c1_addr), .wdata(c1_wdata), .be(c1_be), .rdata(c1_rdata), .ack(c1_ack)
);

sdram_ctrl u_sdram (
    .init(MEM_INIT), .clk(CLK),
    .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
    .addr(sd_addr), .dout(sd_dout), .din(sd_din), .bs(sd_bs), .wr(sd_wr), .rd(sd_rd),
    .refresh(sd_refresh), .ready(sd_ready)
);

// ---- Loader: file offset to chip address, then a FIFO ----

localparam [1:0] CHIP_C0 = 0, CHIP_C1 = 1, CHIP_SD = 2, CHIP_FX = 3;     // the loader never has CHIP_FX

reg         dl_hit;
reg   [1:0] dl_chip;
reg  [25:1] dl_word;

// Upper bits only: the bases are 1 MB or 512 KB aligned, so the low bits pass through
wire  [6:0] dl_p_mb = DL_ADDR[26:20] + (DL_INDEX == 8'd6 ? 7'(MAP_P2 >> 20) : 7'(MAP_P1 >> 20));
wire  [7:0] dl_v_512k = DL_ADDR[26:19] + (DL_INDEX - 8'd16);

always_comb begin
    dl_hit  = 1;
    dl_chip = CHIP_C0;
    dl_word = 0;
    case (DL_INDEX)
        8'd0:  dl_word = {2'b00, MAP_BIOS[23:19], DL_ADDR[18:1]};
        8'd2:  dl_word = {2'b00, MAP_SFIX[23:17], DL_ADDR[16:1]};
        8'd4,
        8'd6: begin
            dl_word = {2'b00, dl_p_mb[3:0], DL_ADDR[19:1]};
            dl_hit  = dl_p_mb < 7'(MAP_BIOS >> 20);     // a bad file must not reach the BIOS
        end
        8'd5:  dl_word = {2'b00, 5'b00001, DL_ADDR[18:1]};  // P1ROM_B_OFFSET - P1ROM_A_OFFSET
        8'd8:  dl_word = {2'b00, MAP_SROM[23:19], DL_ADDR[18:1]};
        8'd9:  dl_word = {2'b00, MAP_M1[23:19], DL_ADDR[18:1]};
        8'd15: begin
            dl_chip = CHIP_SD;
            dl_word = DL_ADDR[25:1];
            dl_hit  = ~DL_ADDR[26];
        end
        default: begin
            dl_chip = CHIP_C1;
            dl_word = {2'b00, dl_v_512k[4:0], DL_ADDR[18:1]};
            dl_hit  = DL_INDEX >= 8'd16 && DL_INDEX < 8'd64 && dl_v_512k[7:5] == 0;
        end
    endcase
    if (RAW_CRAM0 && DL_INDEX == 8'd14) begin
        dl_hit  = 1;
        dl_chip = CHIP_C0;
        dl_word = {2'b00, DL_ADDR[23:1]};
    end
end

localparam DL_AW = 2;       // 4 words: the bridge sends a 32-bit word per 114 clocks at best

reg  [42:0] dl_fifo [1 << DL_AW];
reg [DL_AW:0] dl_wp = 0, dl_rp = 0;

wire        dl_full  = dl_wp == (dl_rp ^ (1'b1 << DL_AW));
wire [42:0] dl_head  = dl_fifo[dl_rp[DL_AW-1:0]];
wire        dl_valid = dl_wp != dl_rp;
wire  [1:0] dl_head_chip = dl_head[42:41];
wire [25:1] dl_head_word = dl_head[40:16];
wire [15:0] dl_head_data = dl_head[15:0];

wire dl_c0 = dl_valid && dl_head_chip == CHIP_C0;
wire dl_c1 = dl_valid && dl_head_chip == CHIP_C1;
wire dl_sd = dl_valid && dl_head_chip == CHIP_SD;

// ---- CD write queue ----

localparam CD_WQ_AW = CD_WQ_DEPTH > 2 ? $clog2(CD_WQ_DEPTH) : 1;

(* ramstyle = "logic" *) reg [44:0] cd_wq [1 << CD_WQ_AW];   // registers: 41 bits are wider than an M10K, for 2 words
reg [CD_WQ_AW:0] cd_wq_wp = 0, cd_wq_rp = 0;
reg         cd_wr_sr = 0;

wire [CD_WQ_AW:0] cd_wq_used = cd_wq_wp - cd_wq_rp;
wire        cd_wq_full  = cd_wq_used == CD_WQ_DEPTH;
wire        cd_wq_valid = cd & (cd_wq_wp != cd_wq_rp);
wire [44:0] cd_wq_head  = cd_wq[cd_wq_rp[CD_WQ_AW-1:0]];
wire [25:1] cd_wq_head_word = cd_wq_head[42:18];
wire [15:0] cd_wq_head_data = cd_wq_head[17:2];
wire  [1:0] cd_wq_head_be   = cd_wq_head[1:0];
wire        cd_wq_c0    = cd_wq_valid && cd_wq_head[44:43] == CHIP_C0;
wire        cd_wq_c1    = cd_wq_valid && cd_wq_head[44:43] == CHIP_C1;
wire        cd_wq_sd    = cd_wq_valid && cd_wq_head[44:43] == CHIP_SD;
wire        cd_wq_fx    = cd_wq_valid && cd_wq_head[44:43] == CHIP_FX;

// A write that finds the queue full stays an edge until there is room. The top holds nDTACK for it,
// so the 68K keeps the strobes, the address and the data up.
wire cd_wr_sig  = CD_EXT_WR | CD_TR_WR_SPR | CD_TR_WR_PCM | CD_TR_WR_FIX;
wire cd_wr_edge = cd & nRESET & cd_wr_sig & ~cd_wr_sr;
assign CD_EXT_WR_READY = ~(cd_wr_edge & cd_wq_full);

// In a DMA nLDS and nUDS are both high, and the writes are whole words
wire [20:1] cd_a        = DMA_RUNNING ? DMA_ADDR_OUT[20:1] : M68K_ADDR[20:1];
wire [15:0] cd_d        = DMA_RUNNING ? DMA_DATA_OUT : M68K_DATA;
wire  [1:0] cd_word_be  = DMA_RUNNING ? 2'b11 : {~nUDS, ~nLDS};
wire [15:0] cd_fix_word = {cd_a[17:6], cd_a[3:1], ~cd_a[5]};
wire [25:1] cd_spr_word = {4'b0000, CD_BANK_SPR, cd_a[19:7], cd_a[5:2], ~cd_a[6], ~cd_a[1]};

reg   [1:0] cd_wr_chip;
reg  [25:1] cd_wr_word;
reg  [15:0] cd_wr_data;
reg   [1:0] cd_wr_be;

always_comb begin
    cd_wr_chip = CHIP_C0;
    cd_wr_word = {2'b00, MAP_PROG[23:21], cd_a[20:1]};
    cd_wr_data = cd_d;
    cd_wr_be   = cd_word_be;
    if (CD_TR_WR_SPR) begin
        cd_wr_chip = CHIP_SD;
        cd_wr_word = cd_spr_word;
    end
    // These two are bytes on an 8-bit bus: the low lane of the data, on both lanes of the chip
    if (CD_TR_WR_PCM) begin
        cd_wr_chip = CHIP_C1;
        cd_wr_word = {2'b00, MAP_PCM[23:20], CD_BANK_PCM, cd_a[19:2]};
        cd_wr_data = {2{cd_d[7:0]}};
        cd_wr_be   = {cd_a[1], ~cd_a[1]};
    end
    if (CD_TR_WR_FIX) begin
        cd_wr_chip = CHIP_FX;
        cd_wr_word = {9'd0, cd_fix_word};
        cd_wr_data = {2{cd_d[7:0]}};
        cd_wr_be   = {cd_a[4], ~cd_a[4]};
    end
end

// ---- Request detection, as sdram_mux ----

reg pck1_sr = 1, pck2_sr = 1, m68k_sr = 0, nas_sr = 1;

wire use_cd_fix = cd & CD_USE_FIX;
wire use_cd_spr = cd & CD_USE_SPR;

wire cd_rd_sig = cd & CD_EXT_RD;
wire m68k_sig  = ~&{nSROMOE, nROMOE, nPORTOE} | cd_rd_sig;
wire pck1_fall = pck1_sr & ~PCK1;
wire req_68k   = nRESET & m68k_sig & ~m68k_sr;
wire req_crom  = nRESET & pck1_fall & SPR_EN & ~use_cd_spr & ~REFRESH_EN;
wire req_fix   = nRESET & pck2_sr & ~PCK2 & FIX_EN & ~use_cd_fix & ~REFRESH_EN;

// The 68K's, or the DMA's, reads in the window, that are not PROG RAM's
wire tr_fix_sig = cd & CD_TR_RD_FIX & ~CD_EXT_RD;
wire tr_spr_sig = cd & CD_TR_RD_SPR & ~CD_EXT_RD;
reg  tr_rd_sr = 0;
wire req_tr_rd = nRESET & (tr_fix_sig | tr_spr_sig) & ~tr_rd_sr;

reg  m68k_pend = 0, fix_pend = 0, crom_pend = 0, tr_fix_pend = 0, tr_spr_pend = 0;

localparam [1:0] C0_LOADER = 0, C0_68K = 1, C0_FIX = 2, C0_M1 = 3;
localparam [1:0] C1_LOADER = 0, C1_A = 1, C1_B = 2;
localparam [1:0] FX_VIDEO = 0, FX_RD = 1, FX_WR = 2;

reg  [1:0] c0_owner = C0_LOADER, c1_owner = C1_LOADER;
reg        c1_cd_wr = 0;     // CRAM1's write is the CD's. A flag, as a fourth owner would be a fourth FSM state
reg  [6:0] z80_wait = 0;

// A toggle request stays different from its ack until the clock after the access ends
wire want_68k = m68k_pend | req_68k;
wire want_fix = (fix_pend | req_fix) & ~cd;
reg         m1_buf_valid = 0;
reg  [18:1] m1_buf_addr = 0;
reg  [15:0] m1_buf_data = 0;
wire        m1_hit = Z80_WORD_BUF & m1_buf_valid & (m1_addr[18:1] == m1_buf_addr);

wire want_m1  = nRESET & (m1_req != m1_ack) & ~(c0_req & c0_owner == C0_M1) & ~m1_hit & (z80_wait <= Z80_WINDOW);
wire want_a   = nRESET & (adpcma_req != adpcma_ack) & ~(c1_req & c1_owner == C1_A);
wire want_b   = nRESET & (adpcmb_req != adpcmb_ack) & ~(c1_req & c1_owner == C1_B);

// ---- Chip addresses of the clients (word addresses) ----

wire [23:1] m68k_word = cd_rd_sig  ? {MAP_PROG[23:21], DMA_RUNNING ? DMA_ADDR_IN[20:1] : M68K_ADDR[20:1]} :
                        ~nROMOE    ? {MAP_P1[23:20], M68K_ADDR[19:1]} :
                        ~nPORTOE   ? MAP_P2[23:1] + P2ROM_ADDR[23:1] :
                        cd ? {MAP_BIOS[23:19], M68K_ADDR[18:1]} :
                                     {MAP_BIOS[23:17], M68K_ADDR[16:1]};

// See dev_notes.txt of MiSTer about why one read covers both S2H1 phases
wire [15:0] fix_tile = {S_LATCH[15:4], S_LATCH[2:0], ~S_LATCH[3]};
wire [23:1] fix_word = nSYSTEM_G ? {MAP_SROM[23:19], FIX_BANK, fix_tile} : {MAP_SFIX[23:17], fix_tile};

wire [23:1] m1_word  = {MAP_M1[23:19], m1_addr[18:1]};

wire [23:0] adpcmb_byte = adpcmb_addr[24] ? v2_offset + adpcmb_addr[23:0] : adpcmb_addr[23:0];

assign dbg_c0 = {c0_req, c0_owner, m68k_pend, fix_pend, c0_addr};

// ---- 68K read data ----

reg  [15:0] prom_data_r = 0;
reg         prom_ready_r = 0;
wire        prom_now = READY_COMB & c0_req & c0_ack & (c0_owner == C0_68K);

assign PROM_DATA       = prom_now ? c0_rdata : prom_data_r;
assign PROM_DATA_READY = prom_now | prom_ready_r;

// ---- FIX RAM's arbiter: cd_fix_sram answers on its clock, the related CLK_48M ----

reg        fx_run = 0;
reg  [1:0] fx_owner = FX_VIDEO;
wire       fx_done = cd & fx_run & (fx_req == fx_ack);

reg        spr_rd_run = 0, spr_wr_run = 0;

// As sdram_mux. In a DMA only a CD read has owner C0_68K, and a loader word in flight costs one stall.
assign DMA_SDRAM_BUSY = cd & DMA_RUNNING & (m68k_pend | cd_wq_valid | (c0_req & (c0_we | c0_owner == C0_68K)) |
                                                    tr_fix_pend | tr_spr_pend | (c1_req & c1_we) | spr_rd_run | spr_wr_run |
                                                    (fx_run & (fx_owner != FX_VIDEO)));

`ifdef NEOGEO_WAIT_COUNTER
// An access in its ack clock is over: the chip goes to the 68K on this edge
always @(posedge CLK) if (req_68k) dbg_at_req <= (!c0_req || c0_ack) ? C0_68K : c0_owner;

// What a DMA does to the memory path, for wait_counter.sv's file: if a CD Speed corrupts, is a DMA's data lost? It
// only watches. A word counts when the queue takes it, by CHIP_*: C0 PROG, C1 PCM, SD SPR, FX FIX. Its stall is the
// CLK_96M with DMA_SDRAM_BUSY up from there on: the queue, then the chip, while the engine holds its strobe.
// Once queued a write is never lost but to a reset, which empties the queue. Before that only one thing can lose it:
// a strobe that falls while the queue is full. The 68K's is held by nDTACK and a DMA's by DMA_SDRAM_BUSY, which
// holds the engine while anything is queued, so both counts should stay 0: they are here to prove it on the Pocket.
reg [3:0][23:0] dbg_n = 0;
reg [3:0][15:0] dbg_stall = 0;
reg [15:0]      dbg_now = 0, dbg_full_cpu = 0, dbg_full_dma = 0, dbg_lost_strobe = 0, dbg_lost_reset = 0;
reg  [1:0]      dbg_chip = 0;
reg             dbg_held = 0, dbg_waited = 0;

wire dbg_taken = cd_wr_edge & ~cd_wq_full & DMA_RUNNING;
wire dbg_wait  = cd_wr_edge & cd_wq_full;

always @(posedge CLK) begin
    if (dbg_taken) begin
        dbg_held <= 1;
        dbg_chip <= cd_wr_chip;
        dbg_now  <= 0;
    end
    else if (dbg_held) begin
        if (!DMA_SDRAM_BUSY) dbg_held <= 0;
        else if (!(&dbg_now)) dbg_now <= dbg_now + 1'd1;
    end
    // As in wait_counter.sv: dbg_n[cd_wr_chip] would make a RAM of it
    for (int i = 0; i < 4; i++) begin
        if (dbg_taken && cd_wr_chip == 2'(i)) dbg_n[i] <= dbg_n[i] + 1'd1;
        if (dbg_held && dbg_chip == 2'(i) && dbg_now > dbg_stall[i]) dbg_stall[i] <= dbg_now;
    end

    dbg_waited <= dbg_wait;
    if (dbg_wait && !dbg_waited) begin
        if (DMA_RUNNING) dbg_full_dma <= dbg_full_dma + 1'd1;
        else             dbg_full_cpu <= dbg_full_cpu + 1'd1;
    end
    if (dbg_waited && !cd_wr_sig && nRESET) dbg_lost_strobe <= dbg_lost_strobe + 1'd1;
    if (!nRESET && cd_wq_used != 0)         dbg_lost_reset  <= dbg_lost_reset + 1'd1;
end

assign dbg_dma = {32'(dbg_n[CHIP_C0]), 32'(dbg_n[CHIP_FX]), 32'(dbg_n[CHIP_SD]), 32'(dbg_n[CHIP_C1]),
                  32'(dbg_stall[CHIP_C0]), 32'(dbg_stall[CHIP_FX]), 32'(dbg_stall[CHIP_SD]), 32'(dbg_stall[CHIP_C1]),
                  32'(dbg_full_cpu), 32'(dbg_full_dma), 32'(dbg_lost_strobe), 32'(dbg_lost_reset)};
`endif

// ---- Refresh watchdog ----

reg [9:0] rfsh_since = 0;
wire rfsh_slot = pck1_fall & REFRESH_EN & ~(CD_BUILD && cd_wq_sd);

// ---- SDRAM burst capture, as sdram_mux ----

reg       crom_run = 0;
reg [1:0] cr_shift = 2'b11;

always @(posedge CLK) begin
    pck1_sr <= PCK1;
    pck2_sr <= PCK2;
    m68k_sr <= m68k_sig & nRESET;
    nas_sr  <= nAS;
    cd_wr_sr <= cd_wr_sig & nRESET & (cd_wr_sr | ~cd_wq_full);
    tr_rd_sr <= (tr_fix_sig | tr_spr_sig) & nRESET;
    z80_wait <= (pck2_sr & ~PCK2) ? 7'd0 : z80_wait + 1'd1;

    if (DL_EN && DL_WR && dl_full) dl_overflow <= 1;
    if (MEM_INIT) dl_overflow <= 0;

    if (DL_EN && DL_WR && dl_hit && !dl_full) begin
        dl_fifo[dl_wp[DL_AW-1:0]] <= {dl_chip, dl_word, DL_DATA};
        dl_wp <= dl_wp + 1'd1;
    end

    if (cd_wr_edge && !cd_wq_full) begin
        cd_wq[cd_wq_wp[CD_WQ_AW-1:0]] <= {cd_wr_chip, cd_wr_word, cd_wr_data, cd_wr_be};
        cd_wq_wp <= cd_wq_wp + 1'd1;
    end

    if (req_68k)  m68k_pend <= 1;
    if (req_fix)  fix_pend  <= 1;
    if (req_crom) crom_pend <= 1;
    if (CD_BUILD && req_tr_rd) begin
        if (tr_fix_sig) tr_fix_pend <= 1;
        else            tr_spr_pend <= 1;
    end

    // In a DMA nAS stays high, so ready is one clock
    if ((~nas_sr & nAS) | (cd & DMA_RUNNING)) prom_ready_r <= 0;
    if (CD_BUILD && nAS) CD_PCM_DTACK <= 0;

    // ---- CRAM0 ----
    if (c0_req && c0_ack) begin
        c0_req <= 0;
        case (c0_owner)
            C0_68K: begin
                prom_data_r  <= c0_rdata;
                prom_ready_r <= 1;
            end
            C0_FIX: SROM_DATA <= c0_rdata;
            C0_M1: begin
                m1_dout <= m1_addr[0] ? c0_rdata[15:8] : c0_rdata[7:0];
                m1_ack  <= m1_req;
                m1_buf_valid <= 1;
                m1_buf_addr  <= m1_addr[18:1];
                m1_buf_data  <= c0_rdata;
            end
            default: ;
        endcase
    end
    if (m1_hit && m1_req != m1_ack && !(c0_req && c0_owner == C0_M1)) begin
        m1_dout <= m1_addr[0] ? m1_buf_data[15:8] : m1_buf_data[7:0];
        m1_ack  <= m1_req;
    end
    // The loader may write the buffered word. CD writes cannot: SYSTEM_CDx is 0 in every build that
    // turns the buffer on, and the CD Z80 does not read CRAM0.
    if (dl_c0) m1_buf_valid <= 0;
    // The master changes req on the edge it sees ack: cram_ctrl looks at it again a clock later
    if (!c0_req || c0_ack) begin
        c0_we <= 0;
        c0_be <= 2'b11;
        if (dl_c0) begin
            c0_req   <= 1;
            c0_we    <= 1;
            c0_owner <= C0_LOADER;
            c0_addr  <= dl_head_word[23:1];
            c0_wdata <= dl_head_data;
            dl_rp    <= dl_rp + 1'd1;
        end
        else if (want_68k) begin
            c0_req    <= 1;
            c0_owner  <= C0_68K;
            c0_addr   <= m68k_word;
            m68k_pend <= 0;
        end
        else if (want_fix) begin
            c0_req   <= 1;
            c0_owner <= C0_FIX;
            c0_addr  <= fix_word;
            fix_pend <= 0;
        end
        else if (cd_wq_c0) begin
            c0_req   <= 1;
            c0_we    <= 1;
            c0_owner <= C0_LOADER;      // a write answers nobody
            c0_addr  <= cd_wq_head_word[23:1];
            c0_wdata <= cd_wq_head_data;
            c0_be    <= cd_wq_head_be;
            cd_wq_rp <= cd_wq_rp + 1'd1;
        end
        else if (want_m1) begin
            c0_req   <= 1;
            c0_owner <= C0_M1;
            c0_addr  <= m1_word;
        end
    end

    // ---- CRAM1 ----
    if (c1_req && c1_ack) begin
        c1_req <= 0;
        case (c1_owner)
            C1_A: begin
                adpcma_dout <= adpcma_addr[0] ? c1_rdata[15:8] : c1_rdata[7:0];
                adpcma_ack  <= adpcma_req;
            end
            C1_B: begin
                adpcmb_dout <= adpcmb_byte[0] ? c1_rdata[15:8] : c1_rdata[7:0];
                adpcmb_ack  <= adpcmb_req;
            end
            default: ;
        endcase
        if (CD_BUILD && c1_cd_wr) CD_PCM_DTACK <= 1;
    end
    if (!c1_req || c1_ack) begin
        c1_we <= 0;
        c1_be <= 2'b11;
        if (CD_BUILD) c1_cd_wr <= 0;
        if (dl_c1) begin
            c1_req   <= 1;
            c1_we    <= 1;
            c1_owner <= C1_LOADER;
            c1_addr  <= dl_head_word[23:1];
            c1_wdata <= dl_head_data;
            dl_rp    <= dl_rp + 1'd1;
        end
        else if (CD_BUILD && cd_wq_c1) begin
            c1_req   <= 1;
            c1_we    <= 1;
            c1_owner <= C1_LOADER;      // a write answers nobody
            c1_cd_wr <= 1;
            c1_addr  <= cd_wq_head_word[23:1];
            c1_wdata <= cd_wq_head_data;
            c1_be    <= cd_wq_head_be;
            cd_wq_rp <= cd_wq_rp + 1'd1;
        end
        else if (want_a) begin
            c1_req   <= 1;
            c1_owner <= C1_A;
            c1_addr  <= adpcma_addr[23:1];
        end
        else if (want_b) begin
            c1_req   <= 1;
            c1_owner <= C1_B;
            c1_addr  <= adpcmb_byte[23:1];
        end
    end

    // ---- SDRAM ----
    // rd and wr are levels until the request is accepted, which is when ready falls
    if (!sd_ready) begin
        sd_rd <= 0;
        sd_wr <= 0;
    end
    // Word 0 is in dout on the first clock ready is seen high; the other three follow
    if (~&cr_shift) begin
        CR_DOUBLE[cr_shift*16 +:16] <= sd_dout;
        cr_shift <= cr_shift - 1'd1;
    end
    if (sd_ready && !sd_rd && !sd_wr) begin
        if (crom_run) begin
            CR_DOUBLE[63:48] <= sd_dout;
            crom_run <= 0;
            cr_shift <= 2;
        end
        if (CD_BUILD && spr_rd_run) begin       // word 0 of the burst; the other three pass
            prom_data_r  <= sd_dout;
            prom_ready_r <= 1;
            spr_rd_run   <= 0;
        end
        if (CD_BUILD) spr_wr_run <= 0;
        if (crom_pend | req_crom) begin
            crom_pend <= 0;
            crom_run  <= 1;
            sd_rd     <= 1;
            sd_addr   <= CROM_ADDR[25:1];
        end
        else if (CD_BUILD && tr_spr_pend) begin
            tr_spr_pend <= 0;
            spr_rd_run  <= 1;
            sd_rd       <= 1;
            sd_addr     <= cd_spr_word;
        end
        else if (dl_sd) begin
            sd_wr   <= 1;
            sd_addr <= dl_head_word;
            sd_din  <= dl_head_data;
            sd_bs   <= 2'b11;
            dl_rp   <= dl_rp + 1'd1;
        end
        else if (CD_BUILD && cd_wq_sd) begin
            spr_wr_run <= 1;
            sd_wr      <= 1;
            sd_addr    <= cd_wq_head_word;
            sd_din     <= cd_wq_head_data;
            sd_bs      <= cd_wq_head_be;
            cd_wq_rp   <= cd_wq_rp + 1'd1;
        end
    end

    // ---- SRAM, CD build ----
    if (CD_BUILD && fx_done) begin
        fx_run <= 0;
        case (fx_owner)
            FX_VIDEO: SROM_DATA <= fx_rdata;
            FX_RD: begin
                prom_data_r  <= fx_rdata;
                prom_ready_r <= 1;
            end
            default: CD_PCM_DTACK <= 1;
        endcase
    end
    if (CD_BUILD && cd && (!fx_run || fx_done)) begin
        if (fix_pend | req_fix) begin
            fix_pend <= 0;
            fx_run   <= 1;
            fx_req   <= ~fx_req;
            fx_owner <= FX_VIDEO;
            fx_we    <= 0;
            fx_word  <= fix_tile;
        end
        else if (tr_fix_pend) begin
            tr_fix_pend <= 0;
            fx_run   <= 1;
            fx_req   <= ~fx_req;
            fx_owner <= FX_RD;
            fx_we    <= 0;
            fx_word  <= cd_fix_word;
        end
        else if (cd_wq_fx) begin
            fx_run   <= 1;
            fx_req   <= ~fx_req;
            fx_owner <= FX_WR;
            fx_we    <= 1;
            fx_word  <= cd_wq_head_word[16:1];
            fx_wdata <= cd_wq_head_data;
            fx_be    <= cd_wq_head_be;
            cd_wq_rp <= cd_wq_rp + 1'd1;
        end
    end

    rfsh_since <= rfsh_since + 1'd1;
    if ((rfsh_slot && rfsh_since >= RFSH_MIN) || rfsh_since >= RFSH_MAX) begin
        sd_refresh <= ~sd_refresh;
        rfsh_since <= 0;
    end

    if (!nRESET) begin
        m68k_pend <= 0;
        fix_pend  <= 0;
        crom_pend <= 0;
        tr_fix_pend <= 0;
        tr_spr_pend <= 0;
        prom_ready_r <= 0;
        CD_PCM_DTACK <= 0;
        m1_ack     <= m1_req;
        adpcma_ack <= adpcma_req;
        adpcmb_ack <= adpcmb_req;
        m1_buf_valid <= 0;
        cd_wq_wp <= 0;
        cd_wq_rp <= 0;
    end
end

endmodule
