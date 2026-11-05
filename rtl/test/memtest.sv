// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Memory self-test of the Pocket layer. It needs no ROMs and no PC to read its verdict, and it uses
// the memories only through the client ports of the real pocket_mem_mux: writes through the loader
// port (with the raw CRAM0 index, as the normal indices leave holes), CRAM0 reads through the 68K
// port (P2 window), CRAM1 reads through ADPCM-A (two byte reads per word), SDRAM reads through the
// sprite port. After the file check it loops forever, counts passes and errors and latches the
// first failure of each row.
//
//   Row  On screen  What                                          res_addr[31:28] of a failure
//   0    1          CRAM walking and random, both dies, full size 0/1 CRAM0 walk/random, 2/3 CRAM1
//   1    2          SDRAM random 64 MB in 4-word bursts, then     0 bursts, 1 retention, 2 refresh gap
//                   retention: bank 0 written, seconds of traffic
//                   in bank 2, bank 0 read back. Throughout, the
//                   gap between AUTO REFRESH commands at the
//                   controller's outputs must stay under 7.8 us
//   2    3          Mixed traffic at the real rates, data and     0 fix, 1 sprite, 2 68K, 3 Z80
//                   the fix (23) and sprite (27) deadlines
//   3    4          3FFFFFh: READ, READ top, READ other, WRITE    0/1 CRAM0 die, 2/3 CRAM1 die: the
//                   0002h (DIDR) top, READ top. 0002h back means  word after it does not read back.
//                   another address aborts the sequence, anything 4: the dies disagree, or the answer
//                   else that it survives and Task 5's guard is   changed between loops
//                   required. Both are answers, not failures
//   4    5          The test file, loaded by the host through the 0 CRAM0, 1 CRAM1, 2 SDRAM
//                   bridge and DL_*, once, before anything else
//
// Row 0 never reads the top word of a die twice between writes to it, in any pattern: READ, READ,
// WRITE there would select a chip register on a chip where the sequence survives. On CRAM1, whose
// client reads bytes, the top word gets one byte per pattern: low in walk, high in random.
//
// Row 2 also keeps its last 8 failures whole, for memtest_bridge to read out, see the layout there.
//
// res_addr[27:0] is the byte address in the chip. For row 3 with no failure, res_addr, res_got and
// res_exp hold the last die that answered "survives" and what it returned. lat holds the worst clocks of the mixed clients,
// {fix, sprite, 68K, Z80}, counted as sim/mem counts them: from the drive to the data visible.
// Generators: xorshift32, low 16 bits per word, as tools/make_memtest_file.py.
module memtest #(
    parameter RD_WAIT   = 8,
    parameter SPAN_BITS = 0,        // 0: full size. n, in simulation: low and high 2^n words of each die
    parameter RET_BITS  = 29,       // retention wait, 2^29 clocks = 5.6 s at 96.67 MHz
    parameter RFSH_GAP_LIMIT = 754, // largest gap between refreshes in clocks, 7.8 us at 96.67 MHz
    parameter RET_REGION_BITS = 22, // words of the retention region: all of bank 0 with col[9] = 0
    parameter MIX_BITS  = 27,       // mixed traffic length, 2^27 clocks = 1.4 s
    parameter FILE_BITS = 16,       // words in the test file, 128 KB
    parameter FILL_BITS = 16,       // words in each region of the mixed test
    parameter TICKS_PER_SECOND = 96671316
) (
    input              clk,         // CLK_96M
    input              mem_init,    // PLL not locked: memory controllers and test restart
    input              start,       // the host has finished loading; any clock domain

    // Bridge writes from memtest_bridge: bw_tog changes per word, the others are stable around it
    input              bw_tog,
    input       [31:0] bw_addr,
    input       [31:0] bw_data,

    output reg  [4:0][31:0] res_err  = 0,
    output reg  [4:0][31:0] res_addr = 0,
    output reg  [4:0][15:0] res_pass = 0,
    output reg  [4:0][15:0] res_got  = 0,
    output reg  [4:0][15:0] res_exp  = 0,
    output      [31:0] lat,
    output reg  [15:0] loops   = 0,
    output reg  [31:0] seconds = 0,
    output reg   [2:0] running = 5, // row under test, 5: waiting for the host
    output reg  [31:0] rfsh_count = 0,  // AUTO REFRESH commands at the SDRAM outputs since start
    output reg  [15:0] rfsh_max = 0,    // largest gap between them, in clocks
    output reg   [1:0] seq_answer = 0,  // row 3: 0 not run, 1 aborted, 2 survives, 3 inconsistent
    output reg   [3:0] seq_mask = 0,    // row 3: dies that answered "survives", bit = die
    output reg         diag_we = 0,     // row 2 failure record, to memtest_bridge
    output reg   [2:0] diag_ptr = 0,
    output reg [255:0] diag_data = 0,
    output reg  [31:0] last_addr = 0,   // row 2's most recent failure
    output reg  [15:0] last_got = 0,
    output reg  [15:0] last_exp = 0,
    output reg  [15:0] last_sec = 0,
    output             dl_overflow,

    inout       [15:0] dram_dq,
    output      [12:0] dram_a,
    output       [1:0] dram_dqm,
    output       [1:0] dram_ba,
    output             dram_we_n,
    output             dram_ras_n,
    output             dram_cas_n,
    output             dram_cke,
    output             dram_clk,

    output     [21:16] cram0_a,
    inout       [15:0] cram0_dq,
    input              cram0_wait,
    output             cram0_clk,
    output             cram0_adv_n,
    output             cram0_cre,
    output             cram0_ce0_n,
    output             cram0_ce1_n,
    output             cram0_oe_n,
    output             cram0_we_n,
    output             cram0_ub_n,
    output             cram0_lb_n,

    output     [21:16] cram1_a,
    inout       [15:0] cram1_dq,
    input              cram1_wait,
    output             cram1_clk,
    output             cram1_adv_n,
    output             cram1_cre,
    output             cram1_ce0_n,
    output             cram1_ce1_n,
    output             cram1_oe_n,
    output             cram1_we_n,
    output             cram1_ub_n,
    output             cram1_lb_n
);

`include "../pocket/mem_map.svh"

localparam [31:0] FILE_SEED = 32'h4E47_4D54;
localparam [3:0]  WR_PERIOD = 12;   // clocks per loader word: contract is 10 on CRAM, 9 on SDRAM

function automatic [31:0] xs32(input [31:0] v);
    reg [31:0] x;
    begin
        x = v ^ (v << 13);
        x = x ^ (x >> 17);
        xs32 = x ^ (x << 5);
    end
endfunction

// Pattern of the regions the mixed test reads at random: a function of the word address
function automatic [15:0] hash(input [22:0] w);
    hash = w[15:0] ^ {w[6:0], w[15:7]} ^ {w[22:16], 9'h155};
endfunction

// ---- Mux ----

reg         nRESET = 0;
reg  [20:1] M68K_ADDR = 0;
reg         nPORTOE = 1;
reg         rd_nas = 1, m_nas = 1, m_rom_n = 1;
wire        nAS = rd_nas & m_nas;
wire        nROMOE = m_rom_n;
reg  [26:0] P2ROM_ADDR = 0, CROM_ADDR = 0, DL_ADDR = 0;
reg         PCK1 = 1, PCK2 = 1, DL_WR = 0;
reg  [15:0] S_LATCH = 0, DL_DATA = 0;
reg   [7:0] DL_INDEX = 0;
reg  [24:0] adpcma_addr = 0;
reg         adpcma_req = 0, m1_req = 0;
reg  [18:0] m1_addr = 0;
wire [15:0] PROM_DATA, SROM_DATA;
wire [27:0] dbg_c0;
wire        PROM_DATA_READY, adpcma_ack, m1_ack;
wire [63:0] CR_DOUBLE;
wire  [7:0] adpcma_dout, m1_dout;

pocket_mem_mux #(.RD_WAIT(RD_WAIT), .RAW_CRAM0(1)) u_mux (
    .CLK(clk), .MEM_INIT(mem_init), .nRESET(nRESET), .nSYSTEM_G(1'b1), .SYSTEM_CDx(1'b0),
    .M68K_ADDR(M68K_ADDR), .M68K_DATA(16'h0), .nAS(nAS), .nLDS(1'b1), .nUDS(1'b1),
    .nROMOE(nROMOE), .nPORTOE(nPORTOE), .nSROMOE(1'b1), .P2ROM_ADDR(P2ROM_ADDR),
    .PROM_DATA(PROM_DATA), .PROM_DATA_READY(PROM_DATA_READY),
    .PCK2(PCK2), .S_LATCH(S_LATCH), .FIX_BANK(2'b00), .FIX_EN(1'b1), .SROM_DATA(SROM_DATA),
    .PCK1(PCK1), .CROM_ADDR(CROM_ADDR), .SPR_EN(1'b1), .CR_DOUBLE(CR_DOUBLE), .REFRESH_EN(1'b0),
    .DL_EN(1'b1), .DL_DATA(DL_DATA), .DL_ADDR(DL_ADDR), .DL_WR(DL_WR), .DL_INDEX(DL_INDEX), .dl_overflow(dl_overflow),
    .dbg_c0(dbg_c0),
    .CD_TR_AREA(3'd0), .CD_EXT_WR(1'b0), .CD_EXT_RD(1'b0), .CD_USE_FIX(1'b0),
    .CD_TR_RD_FIX(1'b0), .CD_TR_WR_FIX(1'b0), .CD_BANK_SPR(2'd0),
    .CD_USE_SPR(1'b0), .CD_TR_RD_SPR(1'b0), .CD_TR_WR_SPR(1'b0),
    .CD_TR_WR_PCM(1'b0), .CD_BANK_PCM(1'b0), .CD_PCM_DTACK(),
    .fx_req(), .fx_we(), .fx_word(), .fx_be(), .fx_wdata(), .fx_ack(1'b0), .fx_rdata(16'h0),
    .DMA_ADDR_OUT(24'h0), .DMA_ADDR_IN(24'h0), .DMA_DATA_OUT(16'h0), .DMA_RUNNING(1'b0),
    .DMA_SDRAM_BUSY(),
    .adpcma_addr(adpcma_addr), .adpcma_dout(adpcma_dout), .adpcma_req(adpcma_req), .adpcma_ack(adpcma_ack),
    .adpcmb_addr(25'd0), .adpcmb_dout(), .adpcmb_req(1'b0), .adpcmb_ack(),
    .v2_offset(24'd0),
    .m1_addr(m1_addr), .m1_dout(m1_dout), .m1_req(m1_req), .m1_ack(m1_ack),
    .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
    .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
    .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
    .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
    .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_wait(cram1_wait), .cram1_clk(cram1_clk),
    .cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
    .cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
);

// ---- The program: one step per sweep ----

localparam [1:0] CHIP_C0 = 0, CHIP_C1 = 1, CHIP_SD = 2;
localparam [1:0] PAT_WALK = 0, PAT_RND = 1, PAT_FILE = 2, PAT_HASH = 3;
localparam [2:0] K_WR = 0, K_RD = 1, K_RDSD = 2, K_WAIT = 3, K_MIX = 4, K_SEQ = 5;

localparam [4:0] STEP_FILE_C0 = 0, STEP_FILE_C1 = 1, STEP_FILE_SD = 2,
                 STEP_C0_WALK_WR = 3, STEP_C0_WALK_RD = 4, STEP_C0_RND_WR = 5, STEP_C0_RND_RD = 6,
                 STEP_C1_WALK_WR = 7, STEP_C1_WALK_RD = 8, STEP_C1_RND_WR = 9, STEP_C1_RND_RD = 10,
                 STEP_SD_WR = 11, STEP_SD_RD = 12, STEP_RET_WR = 13, STEP_RET_WAIT = 14, STEP_RET_RD = 15,
                 STEP_FILL_P = 16, STEP_FILL_S = 17, STEP_FILL_M1 = 18, STEP_FILL_C = 19, STEP_MIX = 20,
                 STEP_SEQ = 21;

localparam FULL_C = SPAN_BITS != 0 ? SPAN_BITS + 2 : 23;
localparam FULL_S = SPAN_BITS != 0 ? SPAN_BITS + 2 : 25;

reg   [2:0] p_kind;
reg   [1:0] p_chip, p_pat;
reg   [2:0] p_row;
reg   [3:0] p_sub;
reg  [24:0] p_base;     // word address
reg   [4:0] p_bits;     // log2 words
reg         p_full, p_pass;

always_comb begin
    p_kind = K_WR; p_chip = CHIP_C0; p_pat = PAT_RND; p_row = 0; p_sub = 0; p_base = 0; p_full = 0; p_pass = 0;
    p_bits = 5'(FULL_C);
    case (step)
        STEP_FILE_C0:    begin p_kind = K_RD;   p_pat = PAT_FILE; p_row = 4; p_bits = 5'(FILE_BITS); end
        STEP_FILE_C1:    begin p_kind = K_RD;   p_pat = PAT_FILE; p_row = 4; p_bits = 5'(FILE_BITS); p_chip = CHIP_C1; p_sub = 1; end
        STEP_FILE_SD:    begin p_kind = K_RDSD; p_pat = PAT_FILE; p_row = 4; p_bits = 5'(FILE_BITS); p_chip = CHIP_SD; p_sub = 2; p_pass = 1; end
        STEP_C0_WALK_WR: begin p_pat = PAT_WALK; p_full = 1; end
        STEP_C0_WALK_RD: begin p_kind = K_RD; p_pat = PAT_WALK; p_full = 1; end
        STEP_C0_RND_WR:  begin p_full = 1; end
        STEP_C0_RND_RD:  begin p_kind = K_RD; p_full = 1; p_sub = 1; end
        STEP_C1_WALK_WR: begin p_chip = CHIP_C1; p_pat = PAT_WALK; p_full = 1; end
        STEP_C1_WALK_RD: begin p_kind = K_RD; p_chip = CHIP_C1; p_pat = PAT_WALK; p_full = 1; p_sub = 2; end
        STEP_C1_RND_WR:  begin p_chip = CHIP_C1; p_full = 1; end
        STEP_C1_RND_RD:  begin p_kind = K_RD; p_chip = CHIP_C1; p_full = 1; p_sub = 3; p_pass = 1; end
        STEP_SD_WR:      begin p_chip = CHIP_SD; p_full = 1; p_bits = 5'(FULL_S); p_row = 1; end
        STEP_SD_RD:      begin p_kind = K_RDSD; p_chip = CHIP_SD; p_full = 1; p_bits = 5'(FULL_S); p_row = 1; end
        STEP_RET_WR:     begin p_chip = CHIP_SD; p_bits = 5'(RET_REGION_BITS); p_row = 1; end
        STEP_RET_WAIT:   begin p_kind = K_WAIT; p_row = 1; end
        STEP_RET_RD:     begin p_kind = K_RDSD; p_chip = CHIP_SD; p_bits = 5'(RET_REGION_BITS); p_row = 1; p_sub = 1; p_pass = 1; end
        STEP_FILL_P:     begin p_pat = PAT_HASH; p_bits = 5'(FILL_BITS); p_row = 2; p_base = 25'(MAP_P1 >> 1); end
        STEP_FILL_S:     begin p_pat = PAT_HASH; p_bits = 5'(FILL_BITS); p_row = 2; p_base = 25'(MAP_SROM >> 1); end
        STEP_FILL_M1:    begin p_pat = PAT_HASH; p_bits = 5'(FILL_BITS); p_row = 2; p_base = 25'(MAP_M1 >> 1); end
        STEP_FILL_C:     begin p_pat = PAT_HASH; p_bits = 5'(FILL_BITS); p_row = 2; p_chip = CHIP_SD; end
        STEP_MIX:        begin p_kind = K_MIX; p_row = 2; p_pass = 1; end
        default:         begin p_kind = K_SEQ; p_row = 3; p_pass = 1; end
    endcase
end

// Word address of a sweep position. In simulation the top bit stays the die and the rest of the
// upper bits move together, so the sweep covers the low and high ends of each die.
function automatic [24:0] span(input [24:0] c, input integer w);
    integer i;
    begin
        span = c;
        if (SPAN_BITS != 0) begin
            for (i = SPAN_BITS; i < w - 1; i = i + 1) span[i] = c[SPAN_BITS];
            span[w-1] = c[SPAN_BITS+1];
        end
    end
endfunction

// ---- Generators ----

reg  [31:0] x = 1;
reg  [15:0] walk = 1;
reg         walk_inv = 0;
reg   [4:0] step = 0;
reg  [24:0] cnt = 0;

wire [24:0] span_c = span(cnt, 23);
wire [24:0] span_s = span(cnt, 25);
wire [24:0] word  = p_base + (p_full ? (p_chip == CHIP_SD ? span_s : span_c) : cnt);
wire [15:0] gen_w = p_pat == PAT_WALK ? walk ^ {16{walk_inv}} : x[15:0];
wire [15:0] gen   = p_pat == PAT_HASH ? hash(word[22:0]) : gen_w;
wire        last  = (cnt | (~25'd0 << p_bits)) == ~25'd0;

// ---- Read helper: a word from a CRAM, one access; CRAM1 two, or with rd_single one byte ----

reg         rd_go = 0, rd_single = 0, rd_high = 0, rd_chip = 0, rd_done = 0;
reg  [22:0] rd_word = 0;
reg  [15:0] rd_data = 0;
reg   [2:0] rd_st = 0;

always @(posedge clk) begin
    rd_done <= 0;
    case (rd_st)
        0: if (rd_go) begin
            if (rd_chip) begin
                adpcma_addr <= {1'b0, rd_word, rd_single & rd_high};
                adpcma_req  <= ~adpcma_req;
                rd_data <= 0;
                rd_st <= 3;
            end else begin
                // The mux adds MAP_P2 to P2ROM_ADDR, modulo the chip
                P2ROM_ADDR[23:1] <= rd_word - MAP_P2[23:1];
                nPORTOE <= 0;
                rd_nas  <= 0;
                rd_st   <= 1;
            end
        end
        1: if (PROM_DATA_READY) begin
            rd_data <= PROM_DATA;
            rd_done <= 1;
            nPORTOE <= 1;
            rd_nas  <= 1;
            rd_st   <= 2;
        end
        2: if (!PROM_DATA_READY) rd_st <= 0;    // READY falls after nAS rises
        3: if (adpcma_req == adpcma_ack) begin
            if (rd_single && rd_high) rd_data[15:8] <= adpcma_dout;
            else rd_data[7:0] <= adpcma_dout;
            if (rd_single) begin
                rd_done <= 1;
                rd_st   <= 0;
            end else begin
                adpcma_addr[0] <= 1;
                adpcma_req  <= ~adpcma_req;
                rd_st <= 4;
            end
        end
        4: if (adpcma_req == adpcma_ack) begin
            rd_data[15:8] <= adpcma_dout;
            rd_done <= 1;
            rd_st   <= 0;
        end
        default: rd_st <= 0;
    endcase
    if (mem_init) begin
        rd_st   <= 0;
        nPORTOE <= 1;
        rd_nas  <= 1;
    end
end

// ---- Failure recording: one per clock, two stages to keep it off the critical paths ----

reg         cmp_v = 0, bad = 0;
reg   [2:0] cmp_row = 0, bad_row = 0;
reg  [27:0] cmp_snap = 0, bad_snap = 0;     // CRAM0 state when a fix or sprite fetch was requested
reg  [31:0] cmp_addr = 0, bad_addr = 0;
reg  [15:0] cmp_got = 0, cmp_exp = 0, bad_got = 0, bad_exp = 0;

always @(posedge clk) begin
    bad      <= cmp_v && cmp_got != cmp_exp;
    bad_row  <= cmp_row;
    bad_addr <= cmp_addr;
    bad_got  <= cmp_got;
    bad_exp  <= cmp_exp;
    bad_snap <= cmp_snap;
end

// ---- Main ----

localparam [2:0] S_WAIT = 0, S_STEP = 1, S_RUN = 2, S_NEXT = 3;

reg   [2:0] st = S_WAIT;
reg   [7:0] t = 0;
reg  [29:0] mt = 0;         // mixed and retention traffic counter
reg   [2:0] start_s = 0;
reg   [2:0] tog_s = 0;
reg   [1:0] bw_half = 0;    // bridge word in progress: 2 first half, 1 second half
reg   [3:0] bw_t = 0;

// Mixed clients
reg         fix_on = 0, fix_seen = 0, spr_on = 0, spr_seen = 0;
reg   [5:0] fix_t = 0, spr_t = 0;
reg  [15:0] fix_exp = 0;
reg  [22:0] fix_cur = 0;    // the word being fetched: fix_tile has already moved on
reg  [27:0] fix_snap = 0, spr_snap = 0;
reg  [24:0] prev_grant = 0, this_grant = 0;
reg  [63:0] spr_exp = 0;
reg  [15:0] fix_tile = 0;
reg  [22:0] spr_word = 0;
reg   [7:0] lat_fix = 0, lat_spr = 0, lat_68k = 0, lat_z80 = 0;
reg   [7:0] m_t = 0, z_t = 0, m_lat = 0, z_lat = 0;
reg  [15:0] m_idx = 0;
reg  [16:0] z_idx = 0;      // bytes
reg         m_on = 0, z_on = 0;
reg   [2:0] dither = 0;
wire [22:0] m_word = 23'(m_idx & 16'((1 << FILL_BITS) - 1));
wire [22:0] z_word = {MAP_M1[23:19], 2'b00, z_idx[16:1] & 16'((1 << FILL_BITS) - 1)};
wire [15:0] z_data = hash(z_word);
wire  [7:0] z_byte = m1_addr[0] ? z_data[15:8] : z_data[7:0];
wire [15:0] tile_m = fix_tile & 16'((1 << FILL_BITS) - 1);
wire [22:0] fix_w  = {MAP_SROM[23:19], 2'b00, tile_m};
wire [22:0] spr_m  = spr_word & 23'((1 << FILL_BITS) - 1);

// Sequence test
reg   [1:0] sq_die = 0;
reg   [3:0] sq_step = 0;
reg         seq_seen = 0;
wire [22:0] sq_top = {sq_die[0], 22'h3FFFFF};
wire [15:0] sq_check = sq_die[1] ? 16'h00A5 : 16'h5AA5;     // CRAM1 reads back the low byte

// Refresh, seen where it leaves the controller: AUTO REFRESH is RAS#, CAS# low and WE# high. The
// gap counts from the first command after the core starts, so an idle SDRAM startup is not in it,
// and reaching the limit is a failure at once: with refresh dead no command ever closes the gap.
wire        rf_cmd = !dram_ras_n && !dram_cas_n && dram_we_n;
reg         rf_on = 0, rf_late = 0;
reg  [15:0] rf_gap = 0;

// The top word of a CRAM1 die gets one read per sweep, see the header
wire        c1_top = p_chip == CHIP_C1 && word[21:0] == 22'h3FFFFF;
wire [15:0] c1_top_mask = p_sub[0] ? 16'hFF00 : 16'h00FF;

assign lat = {lat_fix, lat_spr, lat_68k, lat_z80};

always @(posedge clk) begin
    reg [26:0] sec_cnt = 0;

    DL_WR <= 0;
    rd_go <= 0;
    cmp_v <= 0;

    diag_we <= 0;
    // CRAM0 grants, to know the one before the current one
    if (dbg_c0[27] && dbg_c0[26:25] != this_grant[24:23] || dbg_c0[27] && dbg_c0[22:0] != this_grant[22:0]) begin
        this_grant <= {dbg_c0[26:25], dbg_c0[22:0]};
        prev_grant <= this_grant;
    end

    if (bad && bad_row == 2) begin
        last_addr <= bad_addr;
        last_got  <= bad_got;
        last_exp  <= bad_exp;
        last_sec  <= seconds[15:0];
        diag_we   <= 1;
        diag_data <= {{loops, mt[27:12]},                       // where in the run
                      {4'd0, bad_snap},                         // CRAM0 when the fetch was requested
                      {7'd0, prev_grant},                       // the grant before the current one
                      {m_on, z_on, mt[5:0], dbg_c0[27:23], 19'd0},           // clients and CRAM0 now
                      {m_word[15:0], z_word[15:0]},             // their addresses now
                      seconds,
                      {bad_got, bad_exp},
                      bad_addr};
    end
    if (diag_we) diag_ptr <= diag_ptr + 1'd1;

    if (bad) begin
        if (res_err[bad_row] == 0) begin
            res_addr[bad_row] <= bad_addr;
            res_got[bad_row]  <= bad_got;
            res_exp[bad_row]  <= bad_exp;
        end
        if (~&res_err[bad_row]) res_err[bad_row] <= res_err[bad_row] + 1'd1;
    end

    if (rf_cmd) begin
        rfsh_count <= rfsh_count + 1'd1;
        rf_on  <= nRESET;
        rf_gap <= 1;
    end else if (rf_on && ~&rf_gap) rf_gap <= rf_gap + 1'd1;
    if (rf_on && rf_gap > rfsh_max) rfsh_max <= rf_gap;
    rf_late <= rf_on && rf_gap == RFSH_GAP_LIMIT && !rf_cmd;

    if (st != S_WAIT) begin
        sec_cnt <= sec_cnt + 1'd1;
        if (sec_cnt == 27'(TICKS_PER_SECOND - 1)) begin
            sec_cnt <= 0;
            seconds <= seconds + 1'd1;
        end
    end

    case (st)
        // The host writes the slots while the core is held in reset: the mux sees a pure write
        // stream, in bridge order. A word goes out as two loader words, first half first.
        S_WAIT: begin
            start_s <= {start_s[1:0], start};
            tog_s   <= {tog_s[1:0], bw_tog};
            if (tog_s[2] != tog_s[1]) begin
                bw_half <= 2;
                bw_t    <= 0;
            end else if (bw_half != 0) begin
                bw_t <= bw_t + 1'd1;
                if (bw_t == 0) begin
                    case (bw_addr[31:28])
                        4'h2:    DL_INDEX <= 8'd16;
                        4'h4:    DL_INDEX <= 8'd15;
                        default: DL_INDEX <= 8'd14;
                    endcase
                    DL_ADDR <= {bw_addr[26:2], bw_half == 2 ? 2'b00 : 2'b10};
                    // First byte of the file is in [31:24], and is the low byte of its word
                    DL_DATA <= bw_half == 2 ? {bw_data[23:16], bw_data[31:24]} : {bw_data[7:0], bw_data[15:8]};
                    DL_WR   <= 1;
                end
                if (bw_t == WR_PERIOD - 1) begin
                    bw_t    <= 0;
                    bw_half <= bw_half - 1'd1;
                end
            end
            if (start_s[2] && tog_s[2] == tog_s[1] && bw_half == 0) begin
                nRESET <= 1;
                step   <= STEP_FILE_C0;
                st     <= S_STEP;
            end
        end

        S_STEP: begin
            running  <= p_row;
            cnt      <= 0;
            t        <= 0;
            mt       <= 0;
            sq_die   <= 0;
            sq_step  <= 0;
            x        <= p_pat == PAT_FILE ? FILE_SEED : FILE_SEED ^ {16'h5A5A, loops};
            walk     <= 16'd1 << loops[3:0];
            walk_inv <= loops[4];
            st       <= S_RUN;
        end

        S_RUN: case (p_kind)
            K_WR: begin
                t <= t + 1'd1;
                if (t == 0) begin
                    DL_WR    <= 1;
                    DL_DATA  <= gen;
                    DL_INDEX <= p_chip == CHIP_C0 ? 8'd14 : p_chip == CHIP_C1 ? 8'd16 : 8'd15;
                    DL_ADDR  <= {1'b0, word, 1'b0};
                end
                if (t == WR_PERIOD - 1) begin
                    t    <= 0;
                    cnt  <= cnt + 1'd1;
                    x    <= xs32(x);
                    walk <= {walk[14:0], walk[15]};
                    if (last) st <= S_NEXT;
                end
            end

            K_RD: begin
                if (t == 0 && rd_st == 0 && !rd_go) begin
                    t         <= 1;
                    rd_go     <= 1;
                    rd_chip   <= p_chip == CHIP_C1;
                    rd_single <= c1_top;
                    rd_high   <= p_sub[0];
                    rd_word   <= word[22:0];
                end
                if (rd_done) begin
                    cmp_v    <= 1;
                    cmp_row  <= p_row;
                    cmp_addr <= {p_sub, 4'd0, word[22:0], 1'b0};
                    cmp_got  <= rd_data;
                    cmp_exp  <= c1_top ? gen & c1_top_mask : gen;
                    t        <= 0;
                    cnt      <= cnt + 1'd1;
                    x        <= xs32(x);
                    walk     <= {walk[14:0], walk[15]};
                    if (last) st <= S_NEXT;
                end
            end

            // One burst: the data is due at the deadline of the sprite client, 28 clocks after the
            // edge that makes PCK1 fall, then the four words are checked in order
            K_RDSD: begin
                t <= t + 1'd1;
                if (t == 0) begin
                    PCK1      <= 0;
                    CROM_ADDR <= {1'b0, word, 1'b0};
                end
                if (t >= 28 && t < 32) begin
                    cmp_v    <= 1;
                    cmp_row  <= p_row;
                    cmp_addr <= {p_sub, 2'd0, word[24:2], t[1:0], 1'b0};
                    cmp_got  <= CR_DOUBLE[(3 - t[1:0]) * 16 +: 16];
                    cmp_exp  <= gen;
                    x        <= xs32(x);
                end
                if (t == 32) PCK1 <= 1;
                if (t == 35) begin
                    t   <= 0;
                    cnt <= cnt + 25'd4;
                    if ((cnt[24:2] | (~23'd0 << (p_bits - 5'd2))) == ~23'd0) st <= S_NEXT;
                end
            end

            // Retention: nothing touches bank 0 while refresh runs under traffic in bank 2. Word
            // address bits [24:23] are the bank, so bit 24 set is ba[1]
            K_WAIT: begin
                mt <= mt + 1'd1;
                if (mt[3:0] == 0) begin
                    DL_WR    <= 1;
                    DL_DATA  <= x[15:0];
                    DL_INDEX <= 8'd15;
                    DL_ADDR  <= {1'b0, 2'b01, 7'd0, mt[19:4], 1'b0};    // bank 2
                    x        <= xs32(x);
                end
                if (mt[5:0] == 8) begin
                    PCK1      <= 0;
                    CROM_ADDR <= {1'b0, 2'b01, 7'd0, mt[21:8], 3'b000};
                end
                if (mt[5:0] == 40) PCK1 <= 1;
                if (mt[RET_BITS] && PCK1) st <= S_NEXT;
            end

            K_MIX: begin
                mt     <= mt + 1'd1;
                dither <= {dither[1:0], dither[2] ^ dither[1] ^ mt[3]};

                // The step ends when its time is up and everything started has finished: nothing
                // starts from then on, so nothing is left half started for the steps after it.
                // The CPUs wait for the first line: the mux's Z80 window counts from PCK2 falling,
                // and PCK2 only runs in this step. On a console it never stops.

                // Video: PCK1 and PCK2 fall every 64 clocks, 32 apart, high for 4
                if (mt[5:0] == 0 && !mt[MIX_BITS]) begin
                    PCK1      <= 0;
                    CROM_ADDR <= {3'b000, spr_m, 1'b0};
                    spr_exp   <= {hash({spr_m[22:2], 2'd0}), hash({spr_m[22:2], 2'd1}),
                                  hash({spr_m[22:2], 2'd2}), hash({spr_m[22:2], 2'd3})};
                    spr_word  <= spr_m + 23'd4;
                    spr_on    <= 1;
                    spr_seen  <= 0;
                    spr_t     <= 1;
                    spr_snap  <= dbg_c0;
                end
                if (mt[5:0] == 60) PCK1 <= 1;
                if (mt[5:0] == 32 && !mt[MIX_BITS]) begin
                    PCK2     <= 0;
                    S_LATCH  <= {tile_m[15:4], ~tile_m[0], tile_m[3:1]};
                    fix_exp  <= hash(fix_w);
                    fix_cur  <= fix_w;
                    fix_snap <= dbg_c0;
                    fix_tile <= tile_m + 1'd1;
                    fix_on   <= 1;
                    fix_seen <= 0;
                    fix_t    <= 1;
                end
                if (mt[5:0] == 28) PCK2 <= 1;

                if (fix_on) begin
                    fix_t <= fix_t + 1'd1;
                    if (!fix_seen && SROM_DATA == fix_exp) begin
                        fix_seen <= 1;
                        if (fix_t - 1'd1 > lat_fix) lat_fix <= fix_t - 1'd1;
                    end
                    if (fix_t == 24) begin
                        fix_on <= 0;
                        if (!fix_seen && SROM_DATA != fix_exp) begin
                            cmp_v    <= 1;
                            cmp_row  <= p_row;
                            cmp_addr <= {4'd0, 4'd0, fix_cur, 1'b0};
                            cmp_snap <= fix_snap;
                            cmp_got  <= SROM_DATA;
                            cmp_exp  <= fix_exp;
                        end
                    end
                end
                if (spr_on) begin
                    spr_t <= spr_t + 1'd1;
                    if (!spr_seen && CR_DOUBLE == spr_exp) begin
                        spr_seen <= 1;
                        if (spr_t - 1'd1 > lat_spr) lat_spr <= spr_t - 1'd1;
                    end
                    if (spr_t == 28) begin
                        spr_on <= 0;
                        if (!spr_seen && CR_DOUBLE != spr_exp) begin
                            cmp_v    <= 1;
                            cmp_row  <= p_row;
                            cmp_addr <= {4'd1, 4'd0, CROM_ADDR[23:0]};
                            cmp_snap <= spr_snap;
                            cmp_got  <= CR_DOUBLE[63:48];
                            cmp_exp  <= spr_exp[63:48];
                        end
                    end
                end

                // 68K: one read per 32 clocks or more, phase dithered as the bench does
                m_t <= m_t + 1'd1;
                if (!m_on && m_t >= 8'd32 + dither && !mt[MIX_BITS] && mt >= 64) begin
                    M68K_ADDR <= 20'(m_word);
                    m_rom_n   <= 0;
                    m_nas     <= 0;
                    m_on      <= 1;
                    m_t       <= 0;
                    m_lat     <= 0;
                end
                if (m_on) begin
                    m_lat <= m_lat + 1'd1;
                    if (PROM_DATA_READY) begin
                        if (m_lat > lat_68k) lat_68k <= m_lat;
                        m_rom_n <= 1;
                        m_nas   <= 1;
                        m_on    <= 0;
                        m_idx   <= m_idx + 1'd1;
                        if (PROM_DATA != hash(m_word)) begin
                            cmp_v    <= 1;
                            cmp_row  <= p_row;
                            cmp_addr <= {4'd2, 4'd0, m_word, 1'b0};
                            cmp_got  <= PROM_DATA;
                            cmp_exp  <= hash(m_word);
                        end
                    end
                end

                // Z80: one byte read per 72 clocks
                z_t <= z_t + 1'd1;
                if (z_t == 72) begin
                    if (!z_on && !mt[MIX_BITS] && mt >= 64) begin
                        m1_addr <= {2'b00, z_word[15:0], z_idx[0]};
                        m1_req  <= ~m1_req;
                        z_on    <= 1;
                        z_lat   <= 0;
                    end
                    z_t <= 0;
                end
                if (z_on && m1_ack == m1_req && z_lat != 0) begin
                    if (z_lat > lat_z80) lat_z80 <= z_lat;
                    z_on  <= 0;
                    z_idx <= z_idx + 1'd1;
                    if (m1_dout != z_byte) begin
                        cmp_v    <= 1;
                        cmp_row  <= p_row;
                        cmp_addr <= {4'd3, 4'd0, z_word, m1_addr[0]};
                        cmp_got  <= {8'd0, m1_dout};
                        cmp_exp  <= {8'd0, z_byte};
                    end
                end else if (z_on) z_lat <= z_lat + 1'd1;

                if (mt[MIX_BITS] && !fix_on && !spr_on && !m_on && !z_on) begin
                    PCK1 <= 1;
                    PCK2 <= 1;
                    st   <= S_NEXT;
                end
            end

            // One die at a time, every access waits for the one before: write a known value, READ,
            // READ, READ elsewhere, WRITE 0002h, READ: that is the answer. Then the word must work
            // as memory again whatever the answer was.
            default: begin
                t <= t + 1'd1;
                case (sq_step)
                    0, 4, 6: if (t == 0) begin
                        DL_WR    <= 1;
                        DL_INDEX <= sq_die[1] ? 8'd16 : 8'd14;
                        DL_ADDR  <= {3'b000, sq_top, 1'b0};
                        DL_DATA  <= sq_step == 0 ? 16'hA55A : sq_step == 4 ? 16'h0002 : 16'h5AA5;
                    end else if (t == 20) begin
                        t <= 0;
                        sq_step <= sq_step + 1'd1;
                    end
                    1, 2, 3, 5, 7: begin
                        if (t == 0) begin
                            t <= 0;
                            if (rd_st == 0 && !rd_go) begin
                                t         <= 1;
                                rd_go     <= 1;
                                rd_chip   <= sq_die[1];
                                rd_single <= 1;
                                rd_high   <= 0;
                                rd_word   <= sq_step == 3 ? sq_top - 23'd1 : sq_top;
                            end
                        end else t <= 1;
                        if (rd_done) begin
                            t       <= 0;
                            sq_step <= sq_step + 1'd1;
                            if (sq_step == 5) begin
                                seq_mask[sq_die] <= rd_data != 16'h0002;
                                if (rd_data != 16'h0002 && res_err[3] == 0) begin
                                    res_addr[3] <= {2'b00, sq_die, 4'd0, sq_top, 1'b0};
                                    res_got[3]  <= rd_data;
                                    res_exp[3]  <= 16'h0002;
                                end
                            end
                            if (sq_step == 7) begin
                                cmp_v    <= 1;
                                cmp_row  <= p_row;
                                cmp_addr <= {2'b00, sq_die, 4'd0, sq_top, 1'b0};
                                cmp_got  <= rd_data;
                                cmp_exp  <= sq_check;
                            end
                        end
                    end
                    default: begin
                        t       <= 0;
                        sq_step <= 0;
                        sq_die  <= sq_die + 1'd1;
                        if (sq_die == 3) begin
                            st <= S_NEXT;
                            // The same part on all dies, in every loop: anything else is a real
                            // inconsistency, the one way this row goes red besides a bad read-back
                            if ((seq_mask != 4'h0 && seq_mask != 4'hF) || (seq_seen && seq_answer[0] != (seq_mask == 4'h0))) begin
                                seq_answer <= 3;
                                cmp_v    <= 1;
                                cmp_row  <= p_row;
                                cmp_addr <= {4'd4, 24'd0, seq_mask};
                                cmp_got  <= {12'd0, seq_mask};
                                cmp_exp  <= {12'd0, {4{!seq_answer[0]}}};
                            end else if (seq_answer != 3) seq_answer <= seq_mask == 4'h0 ? 2'd1 : 2'd2;
                            seq_seen <= 1;
                        end
                    end
                endcase
            end
        endcase

        default: begin  // S_NEXT
            if (p_pass) res_pass[p_row] <= res_pass[p_row] + 1'd1;
            if (step == STEP_SEQ) begin
                step  <= STEP_C0_WALK_WR;
                loops <= loops + 1'd1;
            end else step <= step + 1'd1;
            st <= S_STEP;
        end
    endcase

    if (rf_late) begin
        cmp_v    <= 1;
        cmp_row  <= 1;
        cmp_addr <= {4'd2, 12'd0, rf_gap};
        cmp_got  <= rf_gap;
        cmp_exp  <= 16'(RFSH_GAP_LIMIT);
    end

    if (mem_init) begin
        rfsh_count <= 0;
        rfsh_max   <= 0;
        rf_on      <= 0;
        seq_answer <= 0;
        seq_mask   <= 0;
        seq_seen   <= 0;
        diag_ptr   <= 0;
        last_addr  <= 0;
        last_got   <= 0;
        last_exp   <= 0;
        last_sec   <= 0;
        st      <= S_WAIT;
        nRESET  <= 0;
        running <= 5;
        loops   <= 0;
        seconds <= 0;
        res_err <= 0;
        res_pass <= 0;
        start_s <= 0;
        bw_half <= 0;
        PCK1    <= 1;
        PCK2    <= 1;
        m_rom_n <= 1;
        m_nas   <= 1;
        m_on    <= 0;
        z_on    <= 0;
        fix_on  <= 0;
        spr_on  <= 0;
        lat_fix <= 0;
        lat_spr <= 0;
        lat_68k <= 0;
        lat_z80 <= 0;
    end
end

endmodule

// ---- Bridge side, clk_74a ----
// The file slots go to memtest as a toggle and held data (the bridge's worst rate is a word per 88
// clocks, so the data is stable around the toggle). The save slot reads as the working core does
// (apf_io.sv:1012-1015): the word for an address is latched on the strobe and shipped by the next
// transaction. Results and pattern are in the slot, as 32-bit big-endian words in the file:
//   0 magic 'NGMT'  1 {RD_WAIT, overflow, loops}  2 seconds  3 lat
//   4+4r pass, errors, first address, {got, expected} of row r     128..1023 5A000000h + index
//   24 refresh commands  25 largest refresh gap in clocks  26 {answer of row 3 [17:16], dies [3:0]}
//   27 next record of row 2's failures   32+8n record n of 8 (ring, the errors count says how far):
//      +0 client and address, as res_addr   +1 {got, expected}   +2 seconds
//      +3 {68K word, Z80 word} at the failure
//      +4 [31] 68K busy [30] Z80 busy [29:24] clock of the 64 clock line [23] CRAM0 request
//         [22:21] CRAM0 owner (0 loader, 1 68K, 2 fix, 3 Z80) [20] 68K pending [19] fix pending
//      +5 the CRAM0 grant before the current one: [24:23] owner [22:0] word
//      +6 CRAM0 when the fix or sprite fetch was requested: [27] request [26:25] owner [24] 68K
//         pending [23] fix pending [22:0] word
//      +7 {loops, mixed step clock [27:12]}
// The results are read across clocks with no handshake, so a word changing during the read can
// tear. Errors only change on a failure and the save is written when leaving the core.
module memtest_bridge #(
    parameter RD_WAIT = 8
) (
    input              clk,
    input       [31:0] bridge_addr,
    input              bridge_rd,
    output reg  [31:0] bridge_rd_data = 0,
    input              bridge_wr,
    input       [31:0] bridge_wr_data,

    output reg         bw_tog = 0,
    output reg  [31:0] bw_addr = 0,
    output reg  [31:0] bw_data = 0,

    input   [4:0][31:0] res_err,
    input   [4:0][31:0] res_addr,
    input   [4:0][15:0] res_pass,
    input   [4:0][15:0] res_got,
    input   [4:0][15:0] res_exp,
    input       [31:0] lat,
    input       [15:0] loops,
    input       [31:0] seconds,
    input              dl_overflow,
    input       [31:0] rfsh_count,
    input       [15:0] rfsh_max,
    input        [1:0] seq_answer,
    input        [3:0] seq_mask,
    input              diag_clk,
    input              diag_we,
    input        [2:0] diag_ptr,
    input      [255:0] diag_data
);

wire [9:0] idx = bridge_addr[11:2];

// The failure records cross clocks in a block RAM. The address is on the bus well before the strobe.
reg [255:0] diag [0:7];
reg [255:0] diag_q = 0;
always @(posedge diag_clk) if (diag_we) diag[diag_ptr] <= diag_data;
always @(posedge clk) diag_q <= diag[idx[5:3] ^ 3'b100];
wire [2:0] row = (idx[4:2] - 3'd1);

always @(posedge clk) begin
    if (bridge_wr && (bridge_addr[31:28] == 4'h1 || bridge_addr[31:28] == 4'h2 || bridge_addr[31:28] == 4'h4)) begin
        bw_addr <= bridge_addr;
        bw_data <= bridge_wr_data;
        bw_tog  <= ~bw_tog;
    end
    if (bridge_rd) begin
        if (idx >= 128) bridge_rd_data <= 32'h5A00_0000 | idx;
        else if (idx >= 96) bridge_rd_data <= 0;
        else if (idx >= 32) bridge_rd_data <= diag_q[idx[2:0] * 32 +: 32];
        else if (idx < 4)
            case (idx[1:0])
                0: bridge_rd_data <= 32'h4E47_4D54;
                1: bridge_rd_data <= {8'(RD_WAIT), 7'd0, dl_overflow, loops};
                2: bridge_rd_data <= seconds;
                3: bridge_rd_data <= lat;
            endcase
        else if (idx < 24)
            case (idx[1:0])
                0: bridge_rd_data <= {16'd0, res_pass[row]};
                1: bridge_rd_data <= res_err[row];
                2: bridge_rd_data <= res_addr[row];
                3: bridge_rd_data <= {res_got[row], res_exp[row]};
            endcase
        else if (idx == 24) bridge_rd_data <= rfsh_count;
        else if (idx == 25) bridge_rd_data <= {16'd0, rfsh_max};
        else if (idx == 26) bridge_rd_data <= {14'd0, seq_answer, 12'd0, seq_mask};
        else if (idx == 27) bridge_rd_data <= {29'd0, diag_ptr};
        else bridge_rd_data <= 0;
    end
end

endmodule

// ---- The screen, clk_pix (CLK_96M / 16) ----
// 320 x 224 inside 384 x 264, the timing the Overdrive gives the scaler. One band per test: green
// passed, red failed, yellow running, grey not run yet; the 3FFFFFh band is blue once it has an
// answer, as both answers are valid, and its title says which. A '#' in the text takes the next hex digit
// of that line's field. The results come from another clock and are only shown.
module memtest_screen #(
    parameter RD_WAIT = 8
) (
    input              clk,
    input   [4:0][31:0] res_err,
    input   [4:0][31:0] res_addr,
    input   [4:0][15:0] res_pass,
    input   [4:0][15:0] res_got,
    input   [4:0][15:0] res_exp,
    input       [31:0] lat,
    input       [15:0] loops,
    input       [31:0] seconds,
    input        [2:0] running,
    input              dl_overflow,
    input       [31:0] rfsh_count,
    input       [15:0] rfsh_max,
    input        [1:0] seq_answer,
    input        [3:0] seq_mask,
    input       [31:0] last_addr,
    input       [15:0] last_got,
    input       [15:0] last_exp,
    input       [15:0] last_sec,

    output reg  [23:0] video_rgb = 0,
    output reg         video_de = 0,
    output reg         video_vs = 0,
    output reg         video_hs = 0
);

localparam H_TOTAL = 384, V_TOTAL = 264, H_BP = 30, V_BP = 16;

reg [9:0] x = 0, y = 0;
wire [9:0] vx = x - 10'(H_BP);
wire [9:0] vy = y - 10'(V_BP);
wire       active = x >= H_BP && x < H_BP + 320 && y >= V_BP && y < V_BP + 224;
wire [4:0] line = vy[7:3];
wire [5:0] col  = vx[8:3];

// 40 characters per line
function automatic [319:0] text(input [4:0] l, input [1:0] answer);
    case (l)
        0:  text = "    POCKET NEO GEO MEMORY TEST  RD WAIT#";
        1:  text = "  SECONDS ########   LOOPS ####  OVF #  ";
        3:  text = "1 CRAM0 CRAM1 WALK RANDOM FULL SIZE     ";
        7:  text = "2 SDRAM 64MB BURSTS RETENTION REFRESH   ";
        11: text = "3 MIXED TRAFFIC DATA AND DEADLINES      ";
        15: case (answer)
                0: text = "4 3FFFFF SEQUENCE NO ANSWER YET         ";
                1: text = "4 3FFFFF SEQUENCE ABORTS   DIES #       ";
                2: text = "4 3FFFFF SEQUENCE SURVIVES DIES #       ";
                3: text = "4 3FFFFF SEQUENCE INCONSISTENT DIES #   ";
            endcase
        19: text = "5 FILE FROM SD THROUGH BRIDGE AND LOADER";
        4, 8, 12, 16, 20:
            text = "  PASSES ####   ERRORS ########         ";
        5, 9, 13, 17, 21:
            text = "  FIRST ######## GOT #### EXP ####      ";
        23: text = "MIXED LAST FAILURE AT SECOND ####       ";
        24: text = "WORST FIX ## MAX 17   SPR ## MAX 1B     ";
        25: text = "      68K ##          Z80 ##            ";
        26: text = "REFRESH ######## MAX GAP #### LIMIT 2F2 ";
        27: text = "MIXED LAST ######## GOT #### EXP ####   ";
        default: text = "                                        ";
    endcase
endfunction

// Field of a line, consumed from the top by each '#'
reg [2:0] f_row;
reg [63:0] field;
always @* begin
    f_row = (line - 5'd3) >> 2;
    case (line)
        0:  field = {4'(RD_WAIT), 60'd0};
        1:  field = {seconds, loops, 3'd0, dl_overflow, 12'd0};
        24: field = {lat[31:24], lat[23:16], 48'd0};
        25: field = {lat[15:8], lat[7:0], 48'd0};
        26: field = {rfsh_count, rfsh_max, 16'd0};
        23: field = {last_sec, 48'd0};
        27: field = {last_addr, last_got, last_exp};
        15: field = {seq_mask, 60'd0};
        default:
            if (line[1:0] == 2'd0) field = {res_pass[f_row], res_err[f_row], 16'd0};
            else                   field = {res_addr[f_row], res_got[f_row], res_exp[f_row]};
    endcase
end

// 5 x 7 glyphs, MSB is the top row, left column first in each row
function automatic [34:0] glyph(input [7:0] c);
    case (c)
        "0": glyph = 35'b01110_10001_10011_10101_11001_10001_01110;
        "1": glyph = 35'b00100_01100_00100_00100_00100_00100_01110;
        "2": glyph = 35'b01110_10001_00001_00010_00100_01000_11111;
        "3": glyph = 35'b11110_00001_00001_01110_00001_00001_11110;
        "4": glyph = 35'b00010_00110_01010_10010_11111_00010_00010;
        "5": glyph = 35'b11111_10000_11110_00001_00001_10001_01110;
        "6": glyph = 35'b00110_01000_10000_11110_10001_10001_01110;
        "7": glyph = 35'b11111_00001_00010_00100_01000_01000_01000;
        "8": glyph = 35'b01110_10001_10001_01110_10001_10001_01110;
        "9": glyph = 35'b01110_10001_10001_01111_00001_00010_01100;
        "A": glyph = 35'b01110_10001_10001_11111_10001_10001_10001;
        "B": glyph = 35'b11110_10001_10001_11110_10001_10001_11110;
        "C": glyph = 35'b01110_10001_10000_10000_10000_10001_01110;
        "D": glyph = 35'b11110_10001_10001_10001_10001_10001_11110;
        "E": glyph = 35'b11111_10000_10000_11110_10000_10000_11111;
        "F": glyph = 35'b11111_10000_10000_11110_10000_10000_10000;
        "G": glyph = 35'b01110_10001_10000_10111_10001_10001_01111;
        "H": glyph = 35'b10001_10001_10001_11111_10001_10001_10001;
        "I": glyph = 35'b01110_00100_00100_00100_00100_00100_01110;
        "K": glyph = 35'b10001_10010_10100_11000_10100_10010_10001;
        "L": glyph = 35'b10000_10000_10000_10000_10000_10000_11111;
        "M": glyph = 35'b10001_11011_10101_10101_10001_10001_10001;
        "N": glyph = 35'b10001_11001_10101_10011_10001_10001_10001;
        "O": glyph = 35'b01110_10001_10001_10001_10001_10001_01110;
        "P": glyph = 35'b11110_10001_10001_11110_10000_10000_10000;
        "Q": glyph = 35'b01110_10001_10001_10001_10101_10010_01101;
        "R": glyph = 35'b11110_10001_10001_11110_10100_10010_10001;
        "S": glyph = 35'b01111_10000_10000_01110_00001_00001_11110;
        "T": glyph = 35'b11111_00100_00100_00100_00100_00100_00100;
        "U": glyph = 35'b10001_10001_10001_10001_10001_10001_01110;
        "V": glyph = 35'b10001_10001_10001_10001_10001_01010_00100;
        "W": glyph = 35'b10001_10001_10001_10101_10101_11011_10001;
        "X": glyph = 35'b10001_10001_01010_00100_01010_10001_10001;
        "Y": glyph = 35'b10001_10001_01010_00100_00100_00100_00100;
        "Z": glyph = 35'b11111_00001_00010_00100_01000_10000_11111;
        default: glyph = 35'd0;
    endcase
endfunction

wire [319:0] tl = text(line, seq_answer);
wire   [7:0] tc = tl[(39 - col) * 8 +: 8];
wire         is_field = tc == "#";

reg  [63:0] sr = 0;
wire  [3:0] digit = sr[63:60];
wire  [7:0] hex_c = digit < 10 ? 8'h30 + digit : 8'h37 + digit;
wire  [7:0] ch    = is_field ? hex_c : tc;
wire [34:0] g     = glyph(ch);
// Rows 0-6 of the cell, columns 0-4; the rest of the 8 x 8 cell is the gap
wire        ink   = vy[2:0] != 7 && vx[2:0] < 5 && g[34 - (5 * vy[2:0] + vx[2:0])];

wire [2:0] band = (line - 5'd3) >> 2;
wire       in_band = line >= 3 && line < 23 && line[1:0] != 2'd2;
wire [23:0] band_bg = res_err[band] != 0 ? 24'hC00000 :
                      running == band    ? 24'hC0C000 :
                      res_pass[band] == 0 ? 24'h606060 :
                      band == 3          ? 24'h0000C0 : 24'h00A000;
wire [23:0] bg = in_band ? band_bg : 24'h000000;
wire [23:0] fg = in_band && (band_bg == 24'hC0C000 || band_bg == 24'h00A000) ? 24'h000000 : 24'hFFFFFF;

always @(posedge clk) begin
    x <= x + 1'd1;
    if (x == H_TOTAL - 1) begin
        x <= 0;
        y <= y == V_TOTAL - 1 ? 10'd0 : y + 1'd1;
    end

    video_vs <= x == 0 && y == 0;
    video_hs <= x == 3;

    // The field restarts before each scanline, and each '#' cell uses up a digit
    if (x == 0) sr <= field;
    else if (active && vx[2:0] == 7 && is_field) sr <= {sr[59:0], 4'd0};

    video_de  <= active;
    // The scaler takes the mode slot in the rgb word outside DE: zero, the only mode in video.json
    video_rgb <= active ? (ink ? fg : bg) : 24'd0;
end

endmodule
